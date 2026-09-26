`timescale 1ns/1ps
// Auto-configured live arithmetic wrapper for swin_p3_0.
// It uses generated/swin_p3_0 assets created by tools/generate_alpha1_live_assets.py.
module swin_p3_0_live_block(
  input logic clk,input logic rst_n,input logic start,output logic busy,output logic done,
  input logic x_wr_valid,input logic [11:0] x_wr_pixel,
  input logic [2:0] x_wr_co_tile,input logic signed [127:0] x_wr_data,
  input logic y_rd_en,input logic [11:0] y_rd_pixel,
  input logic [2:0] y_rd_co_tile,output logic y_rd_valid,
  output logic signed [127:0] y_rd_data
);
  import alpha1_swin_generated_cfg_pkg::*;
  swin_block_live_core #(
    .H(52),.W(52),.CHANNELS(128),.WS(4),.SHIFT(0),.HEADS(2),.HEAD_DIM(64),
    .ASSET_DIR("generated/swin_p3_0"),
    .QK_M(SWIN_P3_0_QK_M),.QK_SHIFT(SWIN_P3_0_QK_SHIFT),
    .CTX_M(SWIN_P3_0_CTX_M),.CTX_SHIFT(SWIN_P3_0_CTX_SHIFT),
    .POLY_PRE_SCALE_Q(SWIN_P3_0_POLY_PRE_SCALE_Q),.POLY_PRE_SCALE_SHIFT(SWIN_P3_0_POLY_PRE_SCALE_SHIFT),
    .POLY_H_TO_OUT_M(SWIN_P3_0_POLY_H_TO_OUT_M),.POLY_H_TO_OUT_SHIFT(SWIN_P3_0_POLY_H_TO_OUT_SHIFT),
    .POLY_U_TO_Q20_M(SWIN_P3_0_POLY_U_TO_Q20_M),.POLY_U_TO_Q20_SHIFT(SWIN_P3_0_POLY_U_TO_Q20_SHIFT),
    .POLY_X_TO_OUT_M(SWIN_P3_0_POLY_X_TO_OUT_M),.POLY_X_TO_OUT_SHIFT(SWIN_P3_0_POLY_X_TO_OUT_SHIFT),
    .POLY_COEFF_MEM("generated/swin_p3_0/poly/silu_coeff_q20_i32.mem")
  ) u_core (
    .clk,.rst_n,.start,.busy,.done,
    .x_wr_valid,.x_wr_pixel,.x_wr_co_tile,.x_wr_data,
    .y_rd_en,.y_rd_pixel,.y_rd_co_tile,.y_rd_valid,.y_rd_data
  );
endmodule
