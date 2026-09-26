`timescale 1ns/1ps
// Exact MAC/bias/M/shift dense stage with a live source tensor/window memory.
module swin_dense_live_stage_32 #(
 parameter int TOKENS=900,parameter int CIN=128,parameter int COUT=128,
 parameter int PE_K=32,parameter int PE_N=32,parameter int ACC_W=48,
 parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
 parameter int CI_W=((CIN/PE_K)<=1)?1:$clog2(CIN/PE_K),
 parameter int CO_W=((COUT/PE_N)<=1)?1:$clog2(COUT/PE_N),
 parameter int POST_DRAIN=8,
 parameter [8*256-1:0] WEIGHT_MEM = "dense_weight_i8.mem",parameter [8*256-1:0] BIAS_MEM = "dense_bias_i32.mem",
 parameter [8*256-1:0] M_MEM = "dense_M_i32.mem",parameter [8*256-1:0] SHIFT_MEM = "dense_shift_i16.mem"
)(
 input logic clk,rst_n,start,output logic busy,done,
 output logic src_rd_en,output logic [TOKEN_W-1:0] src_rd_token,output logic [CI_W-1:0] src_rd_co_tile,
 input logic src_rd_valid,input logic signed [PE_K*8-1:0] src_rd_data,
 output logic out_valid,output logic [TOKEN_W-1:0] out_token,output logic [CO_W-1:0] out_co_tile,
 output logic signed [PE_N*8-1:0] out_data
);
 logic stream_valid,weight_row_load,eng_busy,eng_done,raw_valid,accv,postv;
 logic [TOKEN_W-1:0] stream_token,raw_token,acc_token,post_token;
 logic [CI_W-1:0] active_ci;
 logic [CO_W-1:0] active_co,raw_co,acc_co,post_co;
 logic [$clog2(PE_K)-1:0] wrow;
 logic signed[7:0] inv[0:PE_K-1],wv[0:PE_N-1],raw[0:PE_N-1],acc[0:PE_N-1],post[0:PE_N-1];
 logic signed[63:0] rawacc[0:PE_N-1],accbias[0:PE_N-1];
 logic [$clog2(POST_DRAIN+1)-1:0] drain;
 typedef enum logic[2:0]{I,L,R,D,F} st_t;st_t st;
 dense_live_mem_adapter32 #(.TOKENS(TOKENS),.CIN(CIN),.COUT(COUT),.PE_K(PE_K),.PE_N(PE_N),.TOKEN_W(TOKEN_W),.CI_W(CI_W),.CO_W(CO_W),.WEIGHT_MEM_FILE(WEIGHT_MEM)) a(
 .stream_valid,.stream_token,.active_ci_tile(active_ci),.active_co_tile(active_co),.weight_row_load,.weight_row_index(wrow),.src_rd_en,.src_rd_token,.src_rd_co_tile,.src_rd_valid,.src_rd_data,.input_vector(inv),.weight_row_values(wv));
 dense_ws32x32_controller #(.TOKENS(TOKENS),.CIN(CIN),.COUT(COUT),.PE_K(PE_K),.PE_N(PE_N),.ACC_W(ACC_W),.TOKEN_ID_W(TOKEN_W)) d(
 .clk,.rst_n,.start(st==L),.busy(eng_busy),.done(eng_done),.input_vector(inv),.weight_row_values(wv),.stream_valid,.stream_token_id(stream_token),.active_ci_tile(active_ci),.active_co_tile(active_co),.weight_row_load,.weight_row_index(wrow),.raw_valid,.raw_token_id(raw_token),.raw_co_tile(raw_co),.raw_acc(rawacc));
 dense_singleop_postproc_32lane #(.LANES(PE_N),.COUT(COUT),.TOKEN_ID_W(TOKEN_W),.CO_TILE_W(CO_W),.BIAS_MEM_FILE(BIAS_MEM),.M_MEM_FILE(M_MEM),.SHIFT_MEM_FILE(SHIFT_MEM)) p(
 .clk,.rst_n,.in_valid(raw_valid),.in_token_id(raw_token),.in_co_tile(raw_co),.mac_sum(rawacc),.acc_valid_dbg(accv),.acc_token_id_dbg(acc_token),.acc_co_tile_dbg(acc_co),.acc_with_bias_dbg(accbias),.out_valid(postv),.out_token_id(post_token),.out_co_tile(post_co),.out_data(post));
 integer k;
 // postproc already registers valid, token, co-tile and lane data together.
 // Do not register only the metadata again here: that would pair beat A tags
 // with beat B data under continuous output traffic.
 always_comb begin
   out_valid   = postv;
   out_token   = post_token;
   out_co_tile = post_co;
   for(k=0;k<PE_N;k=k+1) out_data[k*8 +:8]=post[k];
 end
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin st<=I;busy<=0;done<=0;drain<='0;end
  else begin done<=0;
   case(st)
    I:begin busy<=0;if(start)begin busy<=1;st<=L;end end
    L:st<=R;
    R:if(eng_done)begin drain<='0;st<=D;end
    D:if(drain==POST_DRAIN-1)st<=F;else drain<=drain+1'b1;
    F:begin busy<=0;done<=1;st<=I;end
   endcase
  end
 end
endmodule
