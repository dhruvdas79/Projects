`timescale 1ns/1ps
module qkv_live_mem_adapter #(
  parameter int TOKENS=900, parameter int CIN=128, parameter int COUT=128,
  parameter int PE_K=16, parameter int PE_N=16,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter [8*256-1:0] Q_WEIGHT_MEM = "q_weight_i8.mem",parameter [8*256-1:0] K_WEIGHT_MEM = "k_weight_i8.mem",parameter [8*256-1:0] V_WEIGHT_MEM = "v_weight_i8.mem"
)(
  input logic [1:0] op_sel,input logic stream_valid,input logic [TOKEN_W-1:0] stream_token,
  input logic [$clog2(CIN/PE_K)-1:0] active_ci_tile,input logic [$clog2(COUT/PE_N)-1:0] active_co_tile,
  input logic weight_row_load,input logic [$clog2(PE_K)-1:0] weight_row_index,
  output logic src_rd_en,output logic [TOKEN_W-1:0] src_rd_token,
  output logic [$clog2(CIN/PE_K)-1:0] src_rd_co_tile,input logic src_rd_valid,
  input logic signed [PE_K*8-1:0] src_rd_data,
  output logic signed [7:0] input_vector[0:PE_K-1],output logic signed [7:0] weight_row_values[0:PE_N-1]
);
  localparam int WCOUNT=CIN*COUT;
  logic signed [7:0] qw[0:WCOUNT-1],kw[0:WCOUNT-1],vw[0:WCOUNT-1];
  integer lane;
  function automatic int wa(input int ci,input int co);wa=ci*COUT+co;endfunction
  initial begin $readmemh(Q_WEIGHT_MEM,qw);$readmemh(K_WEIGHT_MEM,kw);$readmemh(V_WEIGHT_MEM,vw);end
  always_comb begin
    src_rd_en=stream_valid; src_rd_token=stream_token; src_rd_co_tile=active_ci_tile;
    for(lane=0;lane<PE_K;lane=lane+1) input_vector[lane]=(stream_valid&&src_rd_valid)?src_rd_data[lane*8 +:8]:'0;
    for(lane=0;lane<PE_N;lane=lane+1) begin
      weight_row_values[lane]='0;
      if(weight_row_load) case(op_sel)
        2'd0: weight_row_values[lane]=qw[wa(active_ci_tile*PE_K+weight_row_index,active_co_tile*PE_N+lane)];
        2'd1: weight_row_values[lane]=kw[wa(active_ci_tile*PE_K+weight_row_index,active_co_tile*PE_N+lane)];
        2'd2: weight_row_values[lane]=vw[wa(active_ci_tile*PE_K+weight_row_index,active_co_tile*PE_N+lane)];
      endcase
    end
  end
endmodule
