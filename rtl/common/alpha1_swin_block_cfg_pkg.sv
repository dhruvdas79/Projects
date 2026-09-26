// ============================================================================
// alpha1_swin_block_cfg_pkg.sv
// Vivado synthesis-safe block geometry constants.
// ============================================================================
`timescale 1ns/1ps

package alpha1_swin_block_cfg_pkg;

  localparam int SWIN_P4_H        = 30;
  localparam int SWIN_P4_W        = 30;
  localparam int SWIN_P4_WS       = 5;
  localparam int SWIN_P4_HEADS    = 4;
  localparam int SWIN_P4_HEAD_DIM = 32;
  localparam int SWIN_P4_WINDOWS  = 36;
  localparam int SWIN_P4_TOKENS   = 25;

  localparam int SWIN_P4_0_SHIFT  = 0;
  localparam int SWIN_P4_1_SHIFT  = 2;
  localparam int SWIN_P4_2_SHIFT  = 0;
  localparam int SWIN_P4_3_SHIFT  = 2;

  localparam int SWIN_P3_H        = 52;
  localparam int SWIN_P3_W        = 52;
  localparam int SWIN_P3_WS       = 4;
  localparam int SWIN_P3_HEADS    = 2;
  localparam int SWIN_P3_HEAD_DIM = 64;
  localparam int SWIN_P3_WINDOWS  = 169;
  localparam int SWIN_P3_TOKENS   = 16;

  localparam int SWIN_P3_0_SHIFT  = 0;
  localparam int SWIN_P3_1_SHIFT  = 2;

endpackage
