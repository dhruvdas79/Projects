`timescale 1ns/1ps
// V6.1 synthesis-optimized tensor RAM.
// One-cycle registered read protocol. A held request is accepted once and is
// re-armed when the address changes or rd_en is deasserted. This prevents a
// requester that waits for rd_valid from receiving duplicate responses.
module swin_tensor_mem16 #(
  parameter int TOKENS = 900,
  parameter int CHANNELS = 128,
  parameter int LANES = 16,
  parameter int DATA_W = 8,
  parameter int CO_TILES = CHANNELS/LANES,
  parameter int TOKEN_W = (TOKENS <= 1) ? 1 : $clog2(TOKENS),
  parameter int CO_W = (CO_TILES <= 1) ? 1 : $clog2(CO_TILES),
  parameter int DEPTH = TOKENS*CO_TILES,
  parameter int ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
  input  logic clk,
  input  logic wr_valid,
  input  logic [TOKEN_W-1:0] wr_token_id,
  input  logic [CO_W-1:0] wr_co_tile,
  input  logic signed [LANES*DATA_W-1:0] wr_data,
  input  logic rd_en,
  input  logic [TOKEN_W-1:0] rd_token_id,
  input  logic [CO_W-1:0] rd_co_tile,
  output logic rd_valid,
  output logic signed [LANES*DATA_W-1:0] rd_data
);
  (* ram_style = "block" *) logic signed [LANES*DATA_W-1:0] mem [0:DEPTH-1];
  logic [ADDR_W-1:0] last_rd_addr;
  logic rd_armed;

  wire [ADDR_W-1:0] wr_addr = ADDR_W'($unsigned(wr_token_id)*CO_TILES + $unsigned(wr_co_tile));
  wire [ADDR_W-1:0] rd_addr = ADDR_W'($unsigned(rd_token_id)*CO_TILES + $unsigned(rd_co_tile));
  wire accept_read = rd_en && (!rd_armed || (rd_addr != last_rd_addr));

  initial begin
    rd_valid = 1'b0;
    rd_data = '0;
    rd_armed = 1'b0;
    last_rd_addr = '0;
  end

  always_ff @(posedge clk) begin
    rd_valid <= accept_read;
    if (!rd_en)
      rd_armed <= 1'b0;
    else if (accept_read) begin
      rd_armed <= 1'b1;
      last_rd_addr <= rd_addr;
      rd_data <= mem[rd_addr];
    end

    if (wr_valid)
      mem[wr_addr] <= wr_data;
  end
endmodule
