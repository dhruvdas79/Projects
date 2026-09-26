`timescale 1ns/1ps
// V6.1 synthesis-optimized 16/32-lane tensor bridge.
// Two 128-bit synchronous RAM banks represent the low/high halves of one
// 32-lane tile. This avoids a 256-bit partial-word write template.
module swin_tensor_mem16x32_bridge #(
  parameter int TOKENS     = 900,
  parameter int CHANNELS   = 128,
  parameter int DATA_W     = 8,
  parameter int LANES16    = 16,
  parameter int LANES32    = 32,
  parameter int CTILES16   = CHANNELS/LANES16,
  parameter int CTILES32   = CHANNELS/LANES32,
  parameter int TOKEN_W    = (TOKENS <= 1) ? 1 : $clog2(TOKENS),
  parameter int CO16_W     = (CTILES16 <= 1) ? 1 : $clog2(CTILES16),
  parameter int CO32_W     = (CTILES32 <= 1) ? 1 : $clog2(CTILES32),
  parameter int DEPTH      = TOKENS*CTILES32,
  parameter int ADDR_W     = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
  input logic clk,
  input logic wr16_valid,
  input logic [TOKEN_W-1:0] wr16_token_id,
  input logic [CO16_W-1:0] wr16_co_tile,
  input logic signed [LANES16*DATA_W-1:0] wr16_data,
  input logic rd16_en,
  input logic [TOKEN_W-1:0] rd16_token_id,
  input logic [CO16_W-1:0] rd16_co_tile,
  output logic rd16_valid,
  output logic signed [LANES16*DATA_W-1:0] rd16_data,
  input logic wr32_valid,
  input logic [TOKEN_W-1:0] wr32_token_id,
  input logic [CO32_W-1:0] wr32_co_tile,
  input logic signed [LANES32*DATA_W-1:0] wr32_data,
  input logic rd32_en,
  input logic [TOKEN_W-1:0] rd32_token_id,
  input logic [CO32_W-1:0] rd32_co_tile,
  output logic rd32_valid,
  output logic signed [LANES32*DATA_W-1:0] rd32_data
);
  localparam int W16 = LANES16*DATA_W;

  (* ram_style = "block" *) logic signed [W16-1:0] mem_lo [0:DEPTH-1];
  (* ram_style = "block" *) logic signed [W16-1:0] mem_hi [0:DEPTH-1];

  wire [CO32_W-1:0] wr16_pair = CO32_W'($unsigned(wr16_co_tile) >> 1);
  wire [CO32_W-1:0] rd16_pair = CO32_W'($unsigned(rd16_co_tile) >> 1);
  wire [ADDR_W-1:0] wa16 = ADDR_W'($unsigned(wr16_token_id)*CTILES32 + $unsigned(wr16_pair));
  wire [ADDR_W-1:0] ra16 = ADDR_W'($unsigned(rd16_token_id)*CTILES32 + $unsigned(rd16_pair));
  wire [ADDR_W-1:0] wa32 = ADDR_W'($unsigned(wr32_token_id)*CTILES32 + $unsigned(wr32_co_tile));
  wire [ADDR_W-1:0] ra32 = ADDR_W'($unsigned(rd32_token_id)*CTILES32 + $unsigned(rd32_co_tile));

  logic rd_armed;
  logic [ADDR_W-1:0] last_rd_addr;
  logic last_rd_is32;
  wire req_is32 = rd32_en;
  wire req_en = rd32_en || rd16_en;
  wire [ADDR_W-1:0] req_addr = req_is32 ? ra32 : ra16;
  wire req_new = req_en && (!rd_armed || (req_addr != last_rd_addr) ||
                           (req_is32 != last_rd_is32));

  initial begin
    rd16_valid = 1'b0;
    rd32_valid = 1'b0;
    rd16_data = '0;
    rd32_data = '0;
    rd_armed = 1'b0;
    last_rd_addr = '0;
    last_rd_is32 = 1'b0;
  end

  always_ff @(posedge clk) begin
    rd16_valid <= req_new && !req_is32;
    rd32_valid <= req_new && req_is32;

    if (!req_en) begin
      rd_armed <= 1'b0;
    end else if (req_new) begin
      rd_armed <= 1'b1;
      last_rd_addr <= req_addr;
      last_rd_is32 <= req_is32;
      if (req_is32)
        rd32_data <= {mem_hi[req_addr], mem_lo[req_addr]};
      else if (rd16_co_tile[0])
        rd16_data <= mem_hi[req_addr];
      else
        rd16_data <= mem_lo[req_addr];
    end

    if (wr32_valid) begin
      mem_lo[wa32] <= wr32_data[0 +: W16];
      mem_hi[wa32] <= wr32_data[W16 +: W16];
    end else if (wr16_valid) begin
      if (wr16_co_tile[0]) mem_hi[wa16] <= wr16_data;
      else                 mem_lo[wa16] <= wr16_data;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (wr16_valid && wr32_valid) $fatal(1,"tensor bridge: simultaneous 16/32 writes");
    if (rd16_en && rd32_en) $fatal(1,"tensor bridge: simultaneous 16/32 reads");
  end
`endif
endmodule
