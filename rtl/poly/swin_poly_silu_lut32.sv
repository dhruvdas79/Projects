`timescale 1ns/1ps
// ============================================================================
// swin_poly_silu_lut32.sv -- fused FC1-output PolySiLU stage
//
// Applies the exact exported 256-entry INT8 PolySiLU table directly to each
// 32-lane FC1 result before it is written to the FC1 activation buffer.  This
// removes the complete 512-channel FC1_PRE frame memory and its read traversal.
// ============================================================================
(* use_dsp = "no" *)
module swin_poly_silu_lut32 #(
  parameter int LANES = 32,
  parameter int TOKEN_W = 10,
  parameter int CO_W = 4,
  parameter string SILU_LUT_MEM = "silu_lut_i8.mem"
)(
  input  logic clk,
  input  logic rst_n,
  input  logic in_valid,
  input  logic [TOKEN_W-1:0] in_token,
  input  logic [CO_W-1:0] in_co_tile,
  input  logic signed [LANES*8-1:0] in_data,
  output logic out_valid,
  output logic [TOKEN_W-1:0] out_token,
  output logic [CO_W-1:0] out_co_tile,
  output logic signed [LANES*8-1:0] out_data
);
  (* rom_style = "distributed" *) logic signed [7:0] silu_lut [0:255];

  initial $readmemh(SILU_LUT_MEM, silu_lut);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_token <= '0;
      out_co_tile <= '0;
      out_data <= '0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        out_token <= in_token;
        out_co_tile <= in_co_tile;
        for (int lane = 0; lane < LANES; lane = lane + 1)
          out_data[lane*8 +: 8] <= silu_lut[$unsigned(in_data[lane*8 +: 8])];
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (LANES != 32) $fatal(1,"fused PolySiLU LUT expects LANES=32");
  end
`endif
endmodule
