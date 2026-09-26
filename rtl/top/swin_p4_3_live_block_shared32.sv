`timescale 1ns/1ps
// Auto-configured live arithmetic wrapper for swin_p4_3.
// It uses generated/swin_p4_3 assets created by tools/generate_alpha1_live_assets.py.
module swin_p4_3_live_block_shared32(
  input logic clk,input logic rst_n,input logic start,output logic busy,output logic done,
  input logic x_wr_valid,input logic [9:0] x_wr_pixel,
  input logic [2:0] x_wr_co_tile,input logic signed [127:0] x_wr_data,
  input logic y_rd_en,input logic [9:0] y_rd_pixel,
  input logic [2:0] y_rd_co_tile,output logic y_rd_valid,
  output logic signed [127:0] y_rd_data,
  output logic client_req,
  input  logic client_grant,
  output logic [11:0] client_cfg_tokens_m1,
  output logic [3:0]  client_cfg_k_tiles_m1,
  output logic [3:0]  client_cfg_n_tiles_m1,
  output logic client_input_valid,
  output logic client_weight_valid,
  output logic signed [8:0] client_input_vector [0:31],
  output logic signed [8:0] client_weight_row_values [0:31],
  input  logic svc_stream_valid,
  input  logic [11:0] svc_stream_token_id,
  input  logic [3:0]  svc_active_ci_tile,
  input  logic [3:0]  svc_active_co_tile,
  input  logic svc_weight_row_load,
  input  logic [4:0] svc_weight_row_index,
  input  logic svc_done,
  input  logic svc_raw_valid,
  input  logic [11:0] svc_raw_token_id,
  input  logic [3:0]  svc_raw_co_tile,
  input  logic signed [63:0] svc_raw_acc [0:31],

  // Aggregate client port to the one global shared requant service.
  output logic post_in_valid,
  output logic [5:0] post_in_route,
  output logic [1:0] post_in_op,
  output logic [1:0] post_in_layer,
  output logic [11:0] post_in_token,
  output logic [6:0] post_in_co,
  output logic signed [63:0] post_in_value [0:31],
  output logic signed [31:0] post_in_multiplier [0:31],
  output logic signed [15:0] post_in_shift [0:31],
  input logic post_out_valid,
  input logic [5:0] post_out_route,
  input logic [1:0] post_out_op,
  input logic [1:0] post_out_layer,
  input logic [11:0] post_out_token,
  input logic [6:0] post_out_co,
  input logic signed [7:0] post_out_code [0:31]
);
  import alpha1_swin_generated_cfg_pkg::*;
  swin_block_live_core_shared32 #(
    .H(30),.W(30),.CHANNELS(128),.WS(5),.SHIFT(2),.HEADS(4),.HEAD_DIM(32),
    .POST_ROUTE_BASE(13),
    .ASSET_DIR("generated/swin_p4_3"),
    .QK_M(SWIN_P4_3_QK_M),.QK_SHIFT(SWIN_P4_3_QK_SHIFT),
    .CTX_M(SWIN_P4_3_CTX_M),.CTX_SHIFT(SWIN_P4_3_CTX_SHIFT),
    .POLY_PRE_SCALE_Q(SWIN_P4_3_POLY_PRE_SCALE_Q),.POLY_PRE_SCALE_SHIFT(SWIN_P4_3_POLY_PRE_SCALE_SHIFT),
    .POLY_H_TO_OUT_M(SWIN_P4_3_POLY_H_TO_OUT_M),.POLY_H_TO_OUT_SHIFT(SWIN_P4_3_POLY_H_TO_OUT_SHIFT),
    .POLY_U_TO_Q20_M(SWIN_P4_3_POLY_U_TO_Q20_M),.POLY_U_TO_Q20_SHIFT(SWIN_P4_3_POLY_U_TO_Q20_SHIFT),
    .POLY_X_TO_OUT_M(SWIN_P4_3_POLY_X_TO_OUT_M),.POLY_X_TO_OUT_SHIFT(SWIN_P4_3_POLY_X_TO_OUT_SHIFT),
    .POLY_COEFF_MEM("generated/swin_p4_3/poly/silu_coeff_q20_i32.mem"),
    .POLY_LUT_MEM("generated/swin_p4_3/poly/silu_lut_i8.mem")
  ) u_core (
    .clk,.rst_n,.start,.busy,.done,
    .x_wr_valid,.x_wr_pixel,.x_wr_co_tile,.x_wr_data,
    .y_rd_en,.y_rd_pixel,.y_rd_co_tile,.y_rd_valid,.y_rd_data,
    .client_req,.client_grant,.client_cfg_tokens_m1,.client_cfg_k_tiles_m1,.client_cfg_n_tiles_m1,
    .client_input_valid,.client_weight_valid,.client_input_vector,.client_weight_row_values,
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid,.post_in_route,.post_in_op,.post_in_layer,.post_in_token,.post_in_co,
    .post_in_value,.post_in_multiplier,.post_in_shift,
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );
endmodule
