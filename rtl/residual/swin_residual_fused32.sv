`timescale 1ns/1ps
// ============================================================================
// swin_residual_fused32.sv -- fused FC2 output + residual-2
//
// FC2 results are aligned and added to RES1 as they leave the shared requant
// service.  RES1 is read through a 32-lane synchronous bridge; the result is
// written directly to the final Y bridge.  This removes the full FC2 frame
// buffer and the separate residual-2 raster traversal.
// ============================================================================
(* use_dsp = "no" *)
module swin_residual_fused32 #(
  parameter int PIXELS=900,
  parameter int CHANNELS=128,
  parameter int LANES32=32,
  parameter int TOKEN_W=(PIXELS<=1)?1:$clog2(PIXELS),
  parameter int CO32_W=((CHANNELS/LANES32)<=1)?1:$clog2(CHANNELS/LANES32),
  parameter [8*256-1:0] A_M_FILE = "a_M_i32.mem",
  parameter [8*256-1:0] A_SHIFT_FILE = "a_shift_i16.mem",
  parameter [8*256-1:0] B_M_FILE = "b_M_i32.mem",
  parameter [8*256-1:0] B_SHIFT_FILE = "b_shift_i16.mem"
)(
  input logic clk,
  input logic rst_n,

  input logic in_valid,
  input logic [TOKEN_W-1:0] in_token,
  input logic [CO32_W-1:0] in_co_tile,
  input logic signed [LANES32*8-1:0] in_data,

  output logic res_rd_en,
  output logic [TOKEN_W-1:0] res_rd_token,
  output logic [CO32_W-1:0] res_rd_co_tile,
  input logic res_rd_valid,
  input logic signed [LANES32*8-1:0] res_rd_data,

  output logic out_valid,
  output logic [TOKEN_W-1:0] out_token,
  output logic [CO32_W-1:0] out_co_tile,
  output logic signed [LANES32*8-1:0] out_data
);
  logic [31:0] am[0:0], bm[0:0];
  logic signed [15:0] as[0:0], bs[0:0];

  logic pipe_valid_q;
  logic [TOKEN_W-1:0] pipe_token_q;
  logic [CO32_W-1:0] pipe_co_q;
  logic signed [LANES32*8-1:0] pipe_data_q;

  logic signed [7:0] res_lo [0:15];
  logic signed [7:0] res_hi [0:15];
  logic signed [7:0] fc2_lo [0:15];
  logic signed [7:0] fc2_hi [0:15];
  logic signed [7:0] y_lo [0:15];
  logic signed [7:0] y_hi [0:15];
  logic signed [63:0] aa_lo[0:15], bb_lo[0:15];
  logic signed [63:0] aa_hi[0:15], bb_hi[0:15];

  initial begin
    $readmemh(A_M_FILE, am);
    $readmemh(A_SHIFT_FILE, as);
    $readmemh(B_M_FILE, bm);
    $readmemh(B_SHIFT_FILE, bs);
  end

  assign res_rd_en = in_valid;
  assign res_rd_token = in_token;
  assign res_rd_co_tile = in_co_tile;
  assign out_valid = pipe_valid_q && res_rd_valid;
  assign out_token = pipe_token_q;
  assign out_co_tile = pipe_co_q;

  always_comb begin
    for (int lane=0; lane<16; lane=lane+1) begin
      res_lo[lane] = res_rd_data[lane*8 +: 8];
      res_hi[lane] = res_rd_data[(lane+16)*8 +: 8];
      fc2_lo[lane] = pipe_data_q[lane*8 +: 8];
      fc2_hi[lane] = pipe_data_q[(lane+16)*8 +: 8];
      out_data[lane*8 +: 8] = y_lo[lane];
      out_data[(lane+16)*8 +: 8] = y_hi[lane];
    end
  end

  requant_add_16lane #(.LANES(16)) u_res_lo(
    .a_code(res_lo),.b_code(fc2_lo),
    .a_mult(am[0]),.a_shift(as[0]),.b_mult(bm[0]),.b_shift(bs[0]),
    .a_aligned(aa_lo),.b_aligned(bb_lo),.y_code(y_lo)
  );

  requant_add_16lane #(.LANES(16)) u_res_hi(
    .a_code(res_hi),.b_code(fc2_hi),
    .a_mult(am[0]),.a_shift(as[0]),.b_mult(bm[0]),.b_shift(bs[0]),
    .a_aligned(aa_hi),.b_aligned(bb_hi),.y_code(y_hi)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pipe_valid_q <= 1'b0;
      pipe_token_q <= '0;
      pipe_co_q <= '0;
      pipe_data_q <= '0;
    end else begin
      pipe_valid_q <= in_valid;
      if (in_valid) begin
        pipe_token_q <= in_token;
        pipe_co_q <= in_co_tile;
        pipe_data_q <= in_data;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && (res_rd_valid !== pipe_valid_q))
      $fatal(1,"fused residual-2 RES1 bridge violated one-cycle read contract");
  end
`endif
endmodule
