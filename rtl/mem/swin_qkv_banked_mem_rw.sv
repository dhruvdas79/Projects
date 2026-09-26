`timescale 1ns/1ps
// Q/K/V final INT8 store. Physical layout remains flat and banked:
//   mem[op][lane][co_tile*TOKENS + global_window_token].
// `global_window_token = window_id*TOKENS_PER_WINDOW + local_token`.
module swin_qkv_banked_mem_rw #(
  parameter int TOKENS=900, parameter int COUT=128, parameter int LANES=16,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CO_W=((COUT/LANES)<=1)?1:$clog2(COUT/LANES)
)(
  input logic clk,
  input logic wr_valid,input logic [1:0] wr_op,input logic [TOKEN_W-1:0] wr_token,
  input logic [CO_W-1:0] wr_co_tile,input logic signed [LANES*8-1:0] wr_data,
  input logic rd_en,input logic [1:0] rd_op,input logic [TOKEN_W-1:0] rd_token,
  input logic [CO_W-1:0] rd_co_tile,output wire rd_valid,
  output logic signed [LANES*8-1:0] rd_data
);
  localparam int TILES=COUT/LANES;
  localparam int DEPTH=TOKENS*TILES;
  localparam int ADDR_W=(DEPTH<=1)?1:$clog2(DEPTH);
  (* ram_style="block" *) logic signed [LANES*8-1:0] mem[0:2][0:DEPTH-1];
  logic [ADDR_W-1:0] wa,ra;
  assign rd_valid = rd_en;

  always_comb begin
    wa = wr_co_tile*TOKENS + wr_token;
    ra = rd_co_tile*TOKENS + rd_token;
rd_data = (rd_en && rd_op<3) ? mem[rd_op][ra] : '0;
  end
  always_ff @(posedge clk) begin
    if (wr_valid && wr_op<3) mem[wr_op][wa] <= wr_data;
  end
endmodule
