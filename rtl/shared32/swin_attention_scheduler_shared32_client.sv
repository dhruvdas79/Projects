`timescale 1ns/1ps
// ============================================================================
// V6.2 window-attention scheduler with II=1 synchronous Q/K/V loading.
// One window scratch is reused for every window; requests and response metadata
// are pipelined so the QKV RAM supplies one 32-lane vector per clock.
// ============================================================================
module swin_attention_scheduler_shared32_client #(
  parameter int NUM_WINDOWS=36,parameter int TOKENS=25,parameter int HEADS=4,
  parameter int HEAD_DIM=32,parameter int LANES=32,parameter int CHUNKS=HEAD_DIM/LANES,
  parameter int COUT=HEADS*HEAD_DIM,
  parameter int WIN_W=(NUM_WINDOWS<=1)?1:$clog2(NUM_WINDOWS),
  parameter int TOK_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int TOKEN_W=$clog2(NUM_WINDOWS*TOKENS),
  parameter int CO_W=((COUT/LANES)<=1)?1:$clog2(COUT/LANES),
  parameter logic signed [31:0] QK_M=32'sd1,parameter int QK_SHIFT=31,
  parameter logic signed [31:0] CTX_M=32'sd1,parameter int CTX_SHIFT=31,
  parameter [8*256-1:0] RELPOS_EXPANDED_MEM="relpos_expanded_i16.mem",
  parameter [8*256-1:0] EXP_LUT_MEM="softmax_exp_lut_u16.mem"
)(
  input logic clk,input logic rst_n,input logic start,output logic busy,output logic done,
  output logic qkv_rd_en,output logic [1:0] qkv_rd_op,
  output logic [TOKEN_W-1:0] qkv_rd_token,output logic [CO_W-1:0] qkv_rd_co_tile,
  input logic qkv_rd_valid,input logic signed [LANES*8-1:0] qkv_rd_data,
  output logic ctx_wr_valid,output logic [WIN_W-1:0] ctx_wr_window,
  output logic [TOK_W-1:0] ctx_wr_token,output logic [CO_W-1:0] ctx_wr_co_tile,
  output logic signed [LANES*8-1:0] ctx_wr_data,
  output logic client_req,input logic client_grant,
  output logic [11:0] client_cfg_tokens_m1,output logic [3:0] client_cfg_k_tiles_m1,
  output logic [3:0] client_cfg_n_tiles_m1,output logic client_input_valid,
  output logic client_weight_valid,output logic signed [8:0] client_input_vector[0:31],
  output logic signed [8:0] client_weight_row_values[0:31],
  input logic svc_stream_valid,input logic [11:0] svc_stream_token_id,
  input logic [3:0] svc_active_ci_tile,input logic [3:0] svc_active_co_tile,
  input logic svc_weight_row_load,input logic [4:0] svc_weight_row_index,
  input logic svc_done,input logic svc_raw_valid,input logic [11:0] svc_raw_token_id,
  input logic [3:0] svc_raw_co_tile,input logic signed [63:0] svc_raw_acc[0:31]
);
  localparam logic [1:0] OP_Q=2'd0,OP_K=2'd1,OP_V=2'd2;
  localparam int CTILES=COUT/LANES;

  logic signed [LANES*8-1:0] q_local[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];
  logic signed [LANES*8-1:0] k_local[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];
  logic signed [LANES*8-1:0] v_local[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];

  typedef enum logic [3:0] {
    ST_IDLE,ST_LOAD_Q,ST_DRAIN_Q,ST_LOAD_K,ST_DRAIN_K,ST_LOAD_V,ST_DRAIN_V,
    ST_ENGINE_LAUNCH,ST_ENGINE_RUN,ST_FINISH
  } state_t;
  state_t st_q;
  logic [WIN_W-1:0] active_window;
  logic [TOK_W-1:0] issue_token;
  logic [CO_W-1:0] issue_co;
  logic req_valid_q;logic [1:0] req_op_q;
  logic [TOK_W-1:0] req_token_q;logic [CO_W-1:0] req_co_q;
  logic issue_last,response_last;

  logic engine_start,engine_busy,engine_done,engine_out_valid;
  logic [TOK_W-1:0] engine_out_token;logic [CO_W-1:0] engine_out_co;
  logic signed [LANES*8-1:0] engine_out_data;

  function automatic logic is_load(input state_t s);
    is_load=(s==ST_LOAD_Q)||(s==ST_LOAD_K)||(s==ST_LOAD_V);
  endfunction
  function automatic logic [1:0] state_op(input state_t s);
    if(s==ST_LOAD_Q)state_op=OP_Q;else if(s==ST_LOAD_K)state_op=OP_K;else state_op=OP_V;
  endfunction
  function automatic logic [TOKEN_W-1:0] window_base_token(input logic [WIN_W-1:0] w);
    logic [TOKEN_W+5:0] base;
    begin
      if(TOKENS==25) base=($unsigned(w)<<4)+($unsigned(w)<<3)+$unsigned(w);
      else if(TOKENS==16) base=$unsigned(w)<<4;
      else base=$unsigned(w)*TOKENS; // unreachable for the active P3/P4 configurations
      window_base_token=TOKEN_W'(base);
    end
  endfunction

  swin_attention_ws32_window_engine_shared32_client #(
    .HEADS(HEADS),.TOKENS(TOKENS),.HEAD_DIM(HEAD_DIM),.LANES(LANES),.CHUNKS(CHUNKS),
    .TOK_W(TOK_W),.CO_W(CO_W),.QK_M(QK_M),.QK_SHIFT(QK_SHIFT),.CTX_M(CTX_M),.CTX_SHIFT(CTX_SHIFT),
    .RELPOS_EXPANDED_MEM(RELPOS_EXPANDED_MEM),.EXP_LUT_MEM(EXP_LUT_MEM)
  ) u_engine(
    .clk,.rst_n,.start(engine_start),.busy(engine_busy),.done(engine_done),
    .q_mem(q_local),.k_mem(k_local),.v_mem(v_local),
    .out_valid(engine_out_valid),.out_ready(1'b1),.out_token(engine_out_token),
    .out_co_tile(engine_out_co),.out_data(engine_out_data),
    .client_req,.client_grant,.client_cfg_tokens_m1,.client_cfg_k_tiles_m1,.client_cfg_n_tiles_m1,
    .client_input_valid,.client_weight_valid,.client_input_vector,.client_weight_row_values,
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,
    .svc_raw_co_tile,.svc_raw_acc
  );

  always_comb begin
    qkv_rd_en=is_load(st_q);
    qkv_rd_op=state_op(st_q);
    qkv_rd_token=window_base_token(active_window)+TOKEN_W'($unsigned(issue_token));
    qkv_rd_co_tile=issue_co;
    issue_last=(issue_token==TOKENS-1)&&(issue_co==CTILES-1);
    response_last=qkv_rd_valid&&req_valid_q&&(req_token_q==TOKENS-1)&&(req_co_q==CTILES-1);
    engine_start=(st_q==ST_ENGINE_LAUNCH);
    ctx_wr_valid=(st_q==ST_ENGINE_RUN)&&engine_out_valid;
    ctx_wr_window=active_window;ctx_wr_token=engine_out_token;ctx_wr_co_tile=engine_out_co;
    ctx_wr_data=engine_out_data;
    busy=(st_q!=ST_IDLE)&&(st_q!=ST_FINISH);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      st_q<=ST_IDLE;done<=1'b0;active_window<='0;issue_token<='0;issue_co<='0;
      req_valid_q<=1'b0;req_op_q<='0;req_token_q<='0;req_co_q<='0;
    end else begin
      done<=1'b0;
      req_valid_q<=qkv_rd_en;
      if(qkv_rd_en)begin req_op_q<=qkv_rd_op;req_token_q<=issue_token;req_co_q<=issue_co;end

      if(qkv_rd_valid&&req_valid_q)begin
        case(req_op_q)
          OP_Q:q_local[req_co_q/CHUNKS][req_token_q][req_co_q%CHUNKS]<=qkv_rd_data;
          OP_K:k_local[req_co_q/CHUNKS][req_token_q][req_co_q%CHUNKS]<=qkv_rd_data;
          default:v_local[req_co_q/CHUNKS][req_token_q][req_co_q%CHUNKS]<=qkv_rd_data;
        endcase
      end

      case(st_q)
        ST_IDLE:if(start)begin active_window<='0;issue_token<='0;issue_co<='0;st_q<=ST_LOAD_Q;end
        ST_LOAD_Q:begin
          if(issue_last)st_q<=ST_DRAIN_Q;
          else if(issue_co==CTILES-1)begin issue_co<='0;issue_token<=issue_token+1'b1;end
          else issue_co<=issue_co+1'b1;
        end
        ST_DRAIN_Q:if(response_last&&req_op_q==OP_Q)begin issue_token<='0;issue_co<='0;st_q<=ST_LOAD_K;end
        ST_LOAD_K:begin
          if(issue_last)st_q<=ST_DRAIN_K;
          else if(issue_co==CTILES-1)begin issue_co<='0;issue_token<=issue_token+1'b1;end
          else issue_co<=issue_co+1'b1;
        end
        ST_DRAIN_K:if(response_last&&req_op_q==OP_K)begin issue_token<='0;issue_co<='0;st_q<=ST_LOAD_V;end
        ST_LOAD_V:begin
          if(issue_last)st_q<=ST_DRAIN_V;
          else if(issue_co==CTILES-1)begin issue_co<='0;issue_token<=issue_token+1'b1;end
          else issue_co<=issue_co+1'b1;
        end
        ST_DRAIN_V:if(response_last&&req_op_q==OP_V)begin issue_token<='0;issue_co<='0;st_q<=ST_ENGINE_LAUNCH;end
        ST_ENGINE_LAUNCH:st_q<=ST_ENGINE_RUN;
        ST_ENGINE_RUN:if(engine_done)begin
          if(active_window==NUM_WINDOWS-1)st_q<=ST_FINISH;
          else begin active_window<=active_window+1'b1;issue_token<='0;issue_co<='0;st_q<=ST_LOAD_Q;end
        end
        ST_FINISH:begin done<=1'b1;st_q<=ST_IDLE;end
        default:st_q<=ST_IDLE;
      endcase
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(rst_n&&(qkv_rd_valid!==req_valid_q))
    $fatal(1,"attention scheduler QKV RAM violated one-cycle read contract");
`endif
endmodule
