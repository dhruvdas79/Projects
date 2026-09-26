`timescale 1ns/1ps
module swin_qkv_live_stage_32 #(
 parameter int TOKENS=900,parameter int CIN=128,parameter int COUT=128,parameter int PE_K=32,parameter int PE_N=32,parameter int ACC_W=48,
 parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),parameter int CO_W=((COUT/PE_N)<=1)?1:$clog2(COUT/PE_N),parameter int POST_DRAIN=8,
 parameter [8*256-1:0] Q_WEIGHT = "q_weight_i8.mem",parameter [8*256-1:0] K_WEIGHT = "k_weight_i8.mem",parameter [8*256-1:0] V_WEIGHT = "v_weight_i8.mem",
 parameter [8*256-1:0] Q_BIAS = "q_bias_i32.mem",parameter [8*256-1:0] Q_M = "q_M_i32.mem",parameter [8*256-1:0] Q_SHIFT = "q_shift_i16.mem",
 parameter [8*256-1:0] K_BIAS = "k_bias_i32.mem",parameter [8*256-1:0] K_M = "k_M_i32.mem",parameter [8*256-1:0] K_SHIFT = "k_shift_i16.mem",
 parameter [8*256-1:0] V_BIAS = "v_bias_i32.mem",parameter [8*256-1:0] V_M = "v_M_i32.mem",parameter [8*256-1:0] V_SHIFT = "v_shift_i16.mem"
)(input logic clk,rst_n,start,output logic busy,done,
 output logic src_rd_en,output logic [TOKEN_W-1:0] src_rd_token,output logic [$clog2(CIN/PE_K)-1:0] src_rd_co_tile,
 input logic src_rd_valid,input logic signed[PE_K*8-1:0] src_rd_data,
 output logic wr_valid,output logic[1:0] wr_op,output logic[TOKEN_W-1:0] wr_token,output logic[CO_W-1:0] wr_co_tile,output logic signed[PE_N*8-1:0] wr_data);
 localparam logic[1:0] Q=0,K=1,V=2;
 typedef enum logic[2:0]{IDLE,LAUNCH,RUN,DRAIN,DONE} st_t; st_t st;
 logic[1:0] op; logic eb,ed,sv,wl,rv,av,postv;
 logic[TOKEN_W-1:0] stok,rtok,atok,posttok;
 logic[$clog2(CIN/PE_K)-1:0] citi; logic[CO_W-1:0] coti,rco,aco,postco;
 logic[$clog2(PE_K)-1:0] wridx;
 logic signed[7:0] inv[0:PE_K-1],wv[0:PE_N-1],postd[0:PE_N-1];
 logic signed[63:0] racc[0:PE_N-1],ab[0:PE_N-1]; logic[1:0] postop; logic[3:0] drain; integer i;
 qkv_live_mem_adapter32 #(.TOKENS(TOKENS),.CIN(CIN),.COUT(COUT),.PE_K(PE_K),.PE_N(PE_N),.TOKEN_W(TOKEN_W),.Q_WEIGHT_MEM(Q_WEIGHT),.K_WEIGHT_MEM(K_WEIGHT),.V_WEIGHT_MEM(V_WEIGHT)) a(.op_sel(op),.stream_valid(sv),.stream_token(stok),.active_ci_tile(citi),.active_co_tile(coti),.weight_row_load(wl),.weight_row_index(wridx),.src_rd_en,.src_rd_token,.src_rd_co_tile,.src_rd_valid,.src_rd_data,.input_vector(inv),.weight_row_values(wv));
 dense_ws32x32_controller #(.TOKENS(TOKENS),.CIN(CIN),.COUT(COUT),.PE_K(PE_K),.PE_N(PE_N),.ACC_W(ACC_W),.TOKEN_ID_W(TOKEN_W)) d(.clk,.rst_n,.start(st==LAUNCH),.busy(eb),.done(ed),.input_vector(inv),.weight_row_values(wv),.stream_valid(sv),.stream_token_id(stok),.active_ci_tile(citi),.active_co_tile(coti),.weight_row_load(wl),.weight_row_index(wridx),.raw_valid(rv),.raw_token_id(rtok),.raw_co_tile(rco),.raw_acc(racc));
 qkv_dense_postproc_32lane #(.LANES(PE_N),.COUT(COUT),.TOKEN_ID_W(TOKEN_W),.Q_BIAS_MEM(Q_BIAS),.Q_M_MEM(Q_M),.Q_SHIFT_MEM(Q_SHIFT),.K_BIAS_MEM(K_BIAS),.K_M_MEM(K_M),.K_SHIFT_MEM(K_SHIFT),.V_BIAS_MEM(V_BIAS),.V_M_MEM(V_M),.V_SHIFT_MEM(V_SHIFT)) p(.clk,.rst_n,.in_valid(rv),.in_op(op),.in_token_id(rtok),.in_co_tile(rco),.mac_sum(racc),.acc_valid_dbg(av),.acc_op_dbg(),.acc_token_id_dbg(atok),.acc_co_tile_dbg(aco),.acc_with_bias_dbg(ab),.out_valid(postv),.out_op(postop),.out_token_id(posttok),.out_co_tile(postco),.out_data(postd));
 always_comb begin
   wr_valid=postv; wr_op=postop; wr_token=posttok; wr_co_tile=postco;
   for(i=0;i<PE_N;i=i+1) wr_data[i*8+:8]=postd[i];
 end
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin st<=IDLE;op<=Q;busy<=0;done<=0;drain<=0; end
  else begin
   done<=0;
   case(st)
    IDLE:begin busy<=0;if(start)begin busy<=1;op<=Q;st<=LAUNCH;end end
    LAUNCH:st<=RUN;
    RUN:if(ed)begin drain<=0;st<=DRAIN;end
    DRAIN:if(drain==POST_DRAIN-1)begin if(op==Q)begin op<=K;st<=LAUNCH;end else if(op==K)begin op<=V;st<=LAUNCH;end else st<=DONE;end else drain<=drain+1'b1;
    DONE:begin busy<=0;done<=1;st<=IDLE;end
    default:st<=IDLE;
   endcase
  end
 end
endmodule
