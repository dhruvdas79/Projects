`timescale 1ns/1ps
// Live activation adapter for the verified WS16x16 dense controller.
// It never loads an activation .mem file. Only model weights are ROMs.
module dense_live_mem_adapter #(
  parameter int TOKENS=900, parameter int CIN=128, parameter int COUT=128,
  parameter int PE_K=16, parameter int PE_N=16,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CI_W=((CIN/PE_K)<=1)?1:$clog2(CIN/PE_K),
  parameter int CO_W=((COUT/PE_N)<=1)?1:$clog2(COUT/PE_N),
  parameter [8*256-1:0] WEIGHT_MEM_FILE = "dense_weight_i8.mem"
)(
  input logic stream_valid,input logic [TOKEN_W-1:0] stream_token,
  input logic [CI_W-1:0] active_ci_tile,input logic [CO_W-1:0] active_co_tile,
  input logic weight_row_load,input logic [$clog2(PE_K)-1:0] weight_row_index,
  output logic src_rd_en,output logic [TOKEN_W-1:0] src_rd_token,
  output logic [CI_W-1:0] src_rd_co_tile,input logic src_rd_valid,
  input logic signed [PE_K*8-1:0] src_rd_data,
  output logic signed [7:0] input_vector[0:PE_K-1],
  output logic signed [7:0] weight_row_values[0:PE_N-1]
);
  localparam int WCOUNT=CIN*COUT;
  logic signed [7:0] weight_rom[0:WCOUNT-1];
  integer lane;
  function automatic int waddr(input int ci,input int co); waddr=ci*COUT+co; endfunction
  initial $readmemh(WEIGHT_MEM_FILE,weight_rom);
  always_comb begin
    src_rd_en=stream_valid;
    src_rd_token=stream_token;
    src_rd_co_tile=active_ci_tile;
    for(lane=0;lane<PE_K;lane=lane+1)
      input_vector[lane]=(stream_valid && src_rd_valid) ? src_rd_data[lane*8 +: 8] : '0;
    for(lane=0;lane<PE_N;lane=lane+1)
      weight_row_values[lane]=weight_row_load ? weight_rom[waddr(active_ci_tile*PE_K+weight_row_index,active_co_tile*PE_N+lane)] : '0;
  end
endmodule
