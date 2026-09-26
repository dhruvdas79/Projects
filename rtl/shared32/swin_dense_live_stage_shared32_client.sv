`timescale 1ns/1ps
// ============================================================================
// Dense client for the one shared 32x32 MAC and one global requant service.
// No private MAC and no private requant pipeline are instantiated here.
// ============================================================================
module swin_dense_live_stage_shared32_client #(
 parameter int TOKENS=900,
 parameter int CIN=128,
 parameter int COUT=128,
 parameter int PE_K=32,
 parameter int PE_N=32,
 parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
 parameter int CO_W=((COUT/PE_N)<=1)?1:$clog2(COUT/PE_N),
 parameter int POST_DRAIN=12,
 parameter int POST_ROUTE_ID=1,
 parameter [8*256-1:0] WEIGHT_MEM="dense_weight_i8.mem",
 parameter [8*256-1:0] BIAS_MEM="dense_folded_bias_i32.mem",
 parameter [8*256-1:0] M_MEM="dense_requant_M_i32.mem",
 parameter [8*256-1:0] SHIFT_MEM="dense_requant_shift_i16.mem"
)(
 input logic clk,
 input logic rst_n,
 input logic start,
 output logic busy,
 output logic done,

 output logic src_rd_en,
 output logic [TOKEN_W-1:0] src_rd_token,
 output logic [$clog2(CIN/PE_K)-1:0] src_rd_co_tile,
 input logic src_rd_valid,
 input logic signed [PE_K*8-1:0] src_rd_data,

 output logic out_valid,
 output logic [TOKEN_W-1:0] out_token,
 output logic [CO_W-1:0] out_co_tile,
 output logic signed [PE_N*8-1:0] out_data,

 output logic client_req,
 input  logic client_grant,
 output logic [11:0] client_cfg_tokens_m1,
 output logic [3:0] client_cfg_k_tiles_m1,
 output logic [3:0] client_cfg_n_tiles_m1,
 output logic client_input_valid,output logic client_weight_valid,
 output logic signed [8:0] client_input_vector [0:PE_K-1],
 output logic signed [8:0] client_weight_row_values [0:PE_N-1],

 input logic svc_stream_valid,
 input logic [11:0] svc_stream_token_id,
 input logic [3:0] svc_active_ci_tile,
 input logic [3:0] svc_active_co_tile,
 input logic svc_weight_row_load,
 input logic [4:0] svc_weight_row_index,
 input logic svc_done,
 input logic svc_raw_valid,
 input logic [11:0] svc_raw_token_id,
 input logic [3:0] svc_raw_co_tile,
 input logic signed [63:0] svc_raw_acc [0:PE_N-1],

 output logic post_in_valid,
 output logic [5:0] post_in_route,
 output logic [1:0] post_in_op,
 output logic [1:0] post_in_layer,
 output logic [11:0] post_in_token,
 output logic [6:0] post_in_co,
 output logic signed [63:0] post_in_value [0:PE_N-1],
 output logic signed [31:0] post_in_multiplier [0:PE_N-1],
 output logic signed [15:0] post_in_shift [0:PE_N-1],
 input logic post_out_valid,
 input logic [5:0] post_out_route,
 input logic [1:0] post_out_op,
 input logic [1:0] post_out_layer,
 input logic [11:0] post_out_token,
 input logic [6:0] post_out_co,
 input logic signed [7:0] post_out_code [0:PE_N-1]
);
 localparam int K_TILES=CIN/PE_K;
 localparam int N_TILES=COUT/PE_N;
 localparam logic [11:0] TOKENS_M1_C=TOKENS-1;
 localparam logic [3:0] K_TILES_M1_C=K_TILES-1;
 localparam logic [3:0] N_TILES_M1_C=N_TILES-1;
 typedef enum logic[2:0] {S_IDLE,S_REQ,S_RUN,S_DRAIN,S_DONE} st_t;
 st_t st_q;
 logic [$clog2(POST_DRAIN+1)-1:0] drain_q;

 logic signed [7:0] adapter_input_vector [0:PE_K-1];
 logic signed [7:0] adapter_weight_row [0:PE_N-1];
 logic signed [31:0] bias_rom [0:COUT-1];
 logic signed [31:0] mult_rom [0:COUT-1];
 logic signed [15:0] shift_rom [0:COUT-1];



 initial begin
   $readmemh(BIAS_MEM,bias_rom);
   $readmemh(M_MEM,mult_rom);
   $readmemh(SHIFT_MEM,shift_rom);
 end

 assign client_cfg_tokens_m1=TOKENS_M1_C;
 assign client_cfg_k_tiles_m1=K_TILES_M1_C;
 assign client_cfg_n_tiles_m1=N_TILES_M1_C;

 dense_live_mem_adapter32 #(
   .TOKENS(TOKENS),.CIN(CIN),.COUT(COUT),.PE_K(PE_K),.PE_N(PE_N),.TOKEN_W(TOKEN_W),
   .WEIGHT_MEM_FILE(WEIGHT_MEM)
 ) u_adapter (
   .clk,.rst_n,.stream_valid(svc_stream_valid && client_grant),
   .stream_token(svc_stream_token_id[TOKEN_W-1:0]),
   .active_ci_tile(svc_active_ci_tile[$clog2(CIN/PE_K)-1:0]),
   .active_co_tile(svc_active_co_tile[CO_W-1:0]),
   .weight_row_load(svc_weight_row_load && client_grant),
   .weight_row_index(svc_weight_row_index[$clog2(PE_K)-1:0]),
   .src_rd_en,.src_rd_token,.src_rd_co_tile,.src_rd_valid,.src_rd_data,
   .input_vector_valid(client_input_valid),.weight_row_valid(client_weight_valid),
   .input_vector(adapter_input_vector),.weight_row_values(adapter_weight_row)
 );

 always_comb begin
   for (int k_vec =0;k_vec<PE_K;k_vec=k_vec+1)
     client_input_vector[k_vec]={adapter_input_vector[k_vec][7],adapter_input_vector[k_vec]};
   for (int k_vec =0;k_vec<PE_N;k_vec=k_vec+1)
     client_weight_row_values[k_vec]={adapter_weight_row[k_vec][7],adapter_weight_row[k_vec]};
 end

 always_comb begin
   post_in_valid = svc_raw_valid && client_grant;
   post_in_route = POST_ROUTE_ID[5:0];
   post_in_op = 2'd0;
   post_in_layer = 2'd0;
   post_in_token = svc_raw_token_id;
   post_in_co = {{3{1'b0}},svc_raw_co_tile};
   for (int k_post =0;k_post<PE_N;k_post=k_post+1) begin
     if(($unsigned(svc_raw_co_tile)*PE_N+k_post)<COUT) begin
       post_in_value[k_post] = $signed(svc_raw_acc[k_post]) +
         $signed({{32{bias_rom[$unsigned(svc_raw_co_tile)*PE_N+k_post][31]}},
                    bias_rom[$unsigned(svc_raw_co_tile)*PE_N+k_post]});
       post_in_multiplier[k_post] = mult_rom[$unsigned(svc_raw_co_tile)*PE_N+k_post];
       post_in_shift[k_post] = shift_rom[$unsigned(svc_raw_co_tile)*PE_N+k_post];
     end else begin
       post_in_value[k_post]='0;
       post_in_multiplier[k_post]='0;
       post_in_shift[k_post]='0;
     end
   end
 end

 always_comb begin
   out_valid = post_out_valid && (post_out_route==POST_ROUTE_ID[5:0]);
   out_token = post_out_token[TOKEN_W-1:0];
   out_co_tile = post_out_co[CO_W-1:0];
   out_data='0;
   for (int k_out =0;k_out<PE_N;k_out=k_out+1)
     out_data[k_out*8 +: 8]=post_out_code[k_out];
 end

 always_ff @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     st_q<=S_IDLE;busy<=1'b0;done<=1'b0;client_req<=1'b0;drain_q<='0;
   end else begin
     done<=1'b0;
     case(st_q)
       S_IDLE: begin busy<=1'b0;client_req<=1'b0;if(start)begin busy<=1'b1;client_req<=1'b1;st_q<=S_REQ;end end
       S_REQ: begin client_req<=1'b1;if(client_grant)begin client_req<=1'b0;st_q<=S_RUN;end end
       S_RUN: if(svc_done && client_grant)begin drain_q<='0;st_q<=S_DRAIN;end
       S_DRAIN: if(drain_q==POST_DRAIN-1)st_q<=S_DONE;else drain_q<=drain_q+1'b1;
       S_DONE: begin busy<=1'b0;done<=1'b1;st_q<=S_IDLE;end
       default: st_q<=S_IDLE;
     endcase
   end
 end

`ifndef SYNTHESIS
 always_ff @(posedge clk) begin
   if(rst_n && post_out_valid && post_out_route==POST_ROUTE_ID[5:0] && ^post_out_code[0]===1'bx)
     $fatal(1,"dense shared requant output contains X");
 end
`endif
endmodule
