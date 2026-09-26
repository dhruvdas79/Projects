`timescale 1ns/1ps
// ============================================================================
// Generic Alpha1 live-memory Swin block.
//
// This top contains no copy/expand/shrink stage. Every named stage invokes
// real dense, attention, affine, residual, or PolySiLU RTL.
//
// Activation input/output are 16 signed INT8 lanes per transaction.
// Supply ASSET_DIR after running tools/generate_alpha1_live_assets.py.
// ============================================================================
module swin_block_live_core #(
  parameter int H=30,
  parameter int W=30,
  parameter int CHANNELS=128,
  parameter int WS=5,
  parameter int SHIFT=0,
  parameter int HEADS=4,
  parameter int HEAD_DIM=32,
  // Attention constants are generated from Alpha1 assets. QK parameters must
  // be strict-audited for each block before signoff.
  parameter logic signed [31:0] QK_M=32'sd1,
  parameter int QK_SHIFT=31,
  parameter logic signed [31:0] CTX_M=32'sd1,
  parameter int CTX_SHIFT=31,
  // PolySiLU parameters are model/block-specific. Multipliers are unsigned
  // positive scale factors; using unsigned avoids sign-wrap above 2^31.
  parameter logic [31:0] POLY_PRE_SCALE_Q=32'd1,
  parameter int POLY_PRE_SCALE_SHIFT=0,
  parameter logic [31:0] POLY_CLAMP_Q=32'h0008_0000,
  parameter int POLY_CLAMP_SHIFT=16,
  parameter logic [31:0] POLY_H_TO_OUT_M=32'd1,
  parameter int POLY_H_TO_OUT_SHIFT=0,
  parameter logic [31:0] POLY_U_TO_Q20_M=32'd1,
  parameter int POLY_U_TO_Q20_SHIFT=0,
  parameter logic [31:0] POLY_X_TO_OUT_M=32'd1,
  parameter int POLY_X_TO_OUT_SHIFT=0,
  parameter [8*256-1:0] POLY_COEFF_MEM = "silu_coeff_q20_i32.mem",
  parameter [8*256-1:0] ASSET_DIR = "generated/swin_p4_0"
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  output logic busy,
  output logic done,

  // External write interface for padded X input.
  input  logic x_wr_valid,
  input  logic [$clog2(H*W)-1:0] x_wr_pixel,
  input  logic [$clog2(CHANNELS/16)-1:0] x_wr_co_tile,
  input  logic signed [127:0] x_wr_data,

  // Final Y output read interface.
  input  logic y_rd_en,
  input  logic [$clog2(H*W)-1:0] y_rd_pixel,
  input  logic [$clog2(CHANNELS/16)-1:0] y_rd_co_tile,
  output logic y_rd_valid,
  output logic signed [127:0] y_rd_data
);
  localparam int LANES=16;
  localparam int PIXELS=H*W;
  localparam int CTILES=CHANNELS/LANES;
  localparam int NUM_WINDOWS=(H/WS)*(W/WS);
  localparam int WTOKENS=WS*WS;
  localparam int TOKEN_W=(PIXELS<=1)?1:$clog2(PIXELS);
  localparam int PIX_W=TOKEN_W;
  localparam int CO_W=(CTILES<=1)?1:$clog2(CTILES);
  localparam int WIN_W=(NUM_WINDOWS<=1)?1:$clog2(NUM_WINDOWS);
  localparam int TOK_W=(WTOKENS<=1)?1:$clog2(WTOKENS);
  localparam int FC1_C=CHANNELS*4;
  localparam int FC1_CO_W=$clog2(FC1_C/LANES);
  // 32-lane MAC datapath tiles. Legacy non-MAC stages remain 16-lane.
  localparam int LANES32=32;
  localparam int CO32_W=((CHANNELS/LANES32)<=1)?1:$clog2(CHANNELS/LANES32);
  localparam int FC1_CO32_W=((FC1_C/LANES32)<=1)?1:$clog2(FC1_C/LANES32);

  // ---- Stage starts/completions ------------------------------------------------
  logic n1_start,n1_done,part_start,part_done,qkv_start,qkv_done;
  logic attn_start,attn_done,proj_start,proj_done,rev_start,rev_done;
  logic r1_start,r1_done,n2_start,n2_done,f1_start,f1_done;
  logic poly_start,poly_done,f2_start,f2_done,r2_start,r2_done;

  swin_block_pulse_sequencer seq(
    .clk,.rst_n,.start,.busy,.done,
    .norm1_start(n1_start),.norm1_done(n1_done),
    .part_start(part_start),.part_done(part_done),
    .qkv_start(qkv_start),.qkv_done(qkv_done),
    .attn_start(attn_start),.attn_done(attn_done),
    .proj_start(proj_start),.proj_done(proj_done),
    .rev_start(rev_start),.rev_done(rev_done),
    .res1_start(r1_start),.res1_done(r1_done),
    .norm2_start(n2_start),.norm2_done(n2_done),
    .fc1_start(f1_start),.fc1_done(f1_done),
    .poly_start(poly_start),.poly_done(poly_done),
    .fc2_start(f2_start),.fc2_done(f2_done),
    .res2_start(r2_start),.res2_done(r2_done)
  );

  // ---- X, N1, H, RES1, N2, FC1_PRE, FC1_ACT, FC2, Y tensor memories ---------
  logic x_rd_en,n1x_rd_en,r1x_rd_en; logic [PIX_W-1:0] x_rd_pix,n1x_pix,r1x_pix; logic [CO_W-1:0] x_rd_co,n1x_co,r1x_co; logic x_rd_valid; logic signed[127:0] x_rd_data;
  logic n1_rd_en,part_n1_rd_en; logic [PIX_W-1:0] n1_rd_pix,part_n1_pix; logic [CO_W-1:0] n1_rd_co,part_n1_co; logic n1_rd_valid; logic signed[127:0] n1_rd_data;
  logic h_rd_en;logic[PIX_W-1:0]h_rd_pix;logic[CO_W-1:0]h_rd_co;logic h_rd_valid;logic signed[127:0]h_rd_data;
  logic res1_rd_en,n2res_rd_en,r2res_rd_en;logic[PIX_W-1:0]res1_rd_pix,n2res_pix,r2res_pix;logic[CO_W-1:0]res1_rd_co,n2res_co,r2res_co;logic res1_rd_valid;logic signed[127:0]res1_rd_data;
  logic n2_rd_en,f1n2_rd_en;logic[PIX_W-1:0]n2_rd_pix,f1n2_pix;logic[CO_W-1:0]n2_rd_co,f1n2_co;logic n2_rd_valid;logic signed[127:0]n2_rd_data;
  logic f1p_rd_en,poly_rd_en;logic[PIX_W-1:0]f1p_rd_pix,poly_pix;logic[FC1_CO_W-1:0]f1p_rd_co,poly_co;logic f1p_rd_valid;logic signed[127:0]f1p_rd_data;
  logic f1a_rd_en,f2_rd_en;logic[PIX_W-1:0]f1a_rd_pix,f2_pix;logic[FC1_CO_W-1:0]f1a_rd_co,f2_co;logic f1a_rd_valid;logic signed[127:0]f1a_rd_data;
  logic fc2_rd_en,r2fc_rd_en;logic[PIX_W-1:0]fc2_rd_pix,r2fc_pix;logic[CO_W-1:0]fc2_rd_co,r2fc_co;logic fc2_rd_valid;logic signed[127:0]fc2_rd_data;

  // X read mux: Norm1 or Residual-1 source A.
  always_comb begin
    x_rd_en = n1x_rd_en | r1x_rd_en;
    x_rd_pix = n1x_rd_en ? n1x_pix : r1x_pix;
    x_rd_co = n1x_rd_en ? n1x_co : r1x_co;
  end
  // RES1 read mux: Norm2 or Residual-2 source A.
  always_comb begin
    res1_rd_en = n2res_rd_en | r2res_rd_en;
    res1_rd_pix = n2res_rd_en ? n2res_pix : r2res_pix;
    res1_rd_co = n2res_rd_en ? n2res_co : r2res_co;
  end
  // N2/fc1 and FC1_PRE/poly and FC1_ACT/fc2 use sole consumers in their phases.
  assign n2_rd_en=1'b0; assign n2_rd_pix='0; assign n2_rd_co='0;
  assign f1p_rd_en=poly_rd_en; assign f1p_rd_pix=poly_pix; assign f1p_rd_co=poly_co;
  assign f1a_rd_en=1'b0; assign f1a_rd_pix='0; assign f1a_rd_co='0;
  assign fc2_rd_en=r2fc_rd_en; assign fc2_rd_pix=r2fc_pix; assign fc2_rd_co=r2fc_co;

  // Write signals from stages.
  logic n1_wr_v;logic[PIX_W-1:0]n1_wr_pix;logic[CO_W-1:0]n1_wr_co;logic signed[127:0]n1_wr_data;
  logic h_wr_v;logic[PIX_W-1:0]h_wr_pix;logic[CO_W-1:0]h_wr_co;logic signed[127:0]h_wr_data;
  logic res1_wr_v;logic[PIX_W-1:0]res1_wr_pix;logic[CO_W-1:0]res1_wr_co;logic signed[127:0]res1_wr_data;
  logic n2_wr_v;logic[PIX_W-1:0]n2_wr_pix;logic[CO_W-1:0]n2_wr_co;logic signed[127:0]n2_wr_data;
  logic f1_wr_v;logic[PIX_W-1:0]f1_wr_pix;logic[FC1_CO_W-1:0]f1_wr_co;logic signed[127:0]f1_wr_data;
  logic pa_wr_v;logic[PIX_W-1:0]pa_wr_pix;logic[FC1_CO_W-1:0]pa_wr_co;logic signed[127:0]pa_wr_data;
  logic f2_wr_v;logic[PIX_W-1:0]f2_wr_pix;logic[CO_W-1:0]f2_wr_co;logic signed[127:0]f2_wr_data;
  logic y_wr_v;logic[PIX_W-1:0]y_wr_pix;logic[CO_W-1:0]y_wr_co;logic signed[127:0]y_wr_data;

  swin_tensor_mem16 #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) XMEM(.clk,.wr_valid(x_wr_valid),.wr_token_id(x_wr_pixel),.wr_co_tile(x_wr_co_tile),.wr_data(x_wr_data),.rd_en(x_rd_en),.rd_token_id(x_rd_pix),.rd_co_tile(x_rd_co),.rd_valid(x_rd_valid),.rd_data(x_rd_data));
  swin_tensor_mem16 #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) N1MEM(.clk,.wr_valid(n1_wr_v),.wr_token_id(n1_wr_pix),.wr_co_tile(n1_wr_co),.wr_data(n1_wr_data),.rd_en(part_n1_rd_en),.rd_token_id(part_n1_pix),.rd_co_tile(part_n1_co),.rd_valid(n1_rd_valid),.rd_data(n1_rd_data));
  swin_tensor_mem16 #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) HMEM(.clk,.wr_valid(h_wr_v),.wr_token_id(h_wr_pix),.wr_co_tile(h_wr_co),.wr_data(h_wr_data),.rd_en(h_rd_en),.rd_token_id(h_rd_pix),.rd_co_tile(h_rd_co),.rd_valid(h_rd_valid),.rd_data(h_rd_data));
  swin_tensor_mem16 #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) RES1MEM(.clk,.wr_valid(res1_wr_v),.wr_token_id(res1_wr_pix),.wr_co_tile(res1_wr_co),.wr_data(res1_wr_data),.rd_en(res1_rd_en),.rd_token_id(res1_rd_pix),.rd_co_tile(res1_rd_co),.rd_valid(res1_rd_valid),.rd_data(res1_rd_data));
  // 16/32 bridge memories allow legacy 16-lane stages and WS32 MAC stages to share tensors.
  logic f1n2_rd32_en; logic [PIX_W-1:0] f1n2_pix32; logic [CO32_W-1:0] f1n2_co32; logic n2_rd32_valid; logic signed[255:0] n2_rd32_data;
  logic f1_wr32_v; logic [PIX_W-1:0] f1_wr32_pix; logic [FC1_CO32_W-1:0] f1_wr32_co; logic signed[255:0] f1_wr32_data;
  logic f2_rd32_en; logic [PIX_W-1:0] f2_pix32; logic [FC1_CO32_W-1:0] f2_co32; logic f1a_rd32_valid; logic signed[255:0] f1a_rd32_data;
  logic f2_wr32_v; logic [PIX_W-1:0] f2_wr32_pix; logic [CO32_W-1:0] f2_wr32_co; logic signed[255:0] f2_wr32_data;

  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) N2MEM(.clk,
    .wr16_valid(n2_wr_v),.wr16_token_id(n2_wr_pix),.wr16_co_tile(n2_wr_co),.wr16_data(n2_wr_data),
    .rd16_en(1'b0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(1'b0),.wr32_token_id('0),.wr32_co_tile('0),.wr32_data('0),
    .rd32_en(f1n2_rd32_en),.rd32_token_id(f1n2_pix32),.rd32_co_tile(f1n2_co32),.rd32_valid(n2_rd32_valid),.rd32_data(n2_rd32_data));
  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(FC1_C)) F1PMEM(.clk,
    .wr16_valid(1'b0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(f1p_rd_en),.rd16_token_id(f1p_rd_pix),.rd16_co_tile(f1p_rd_co),.rd16_valid(f1p_rd_valid),.rd16_data(f1p_rd_data),
    .wr32_valid(f1_wr32_v),.wr32_token_id(f1_wr32_pix),.wr32_co_tile(f1_wr32_co),.wr32_data(f1_wr32_data),
    .rd32_en(1'b0),.rd32_token_id('0),.rd32_co_tile('0),.rd32_valid(),.rd32_data());
  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(FC1_C)) F1AMEM(.clk,
    .wr16_valid(pa_wr_v),.wr16_token_id(pa_wr_pix),.wr16_co_tile(pa_wr_co),.wr16_data(pa_wr_data),
    .rd16_en(1'b0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(1'b0),.wr32_token_id('0),.wr32_co_tile('0),.wr32_data('0),
    .rd32_en(f2_rd32_en),.rd32_token_id(f2_pix32),.rd32_co_tile(f2_co32),.rd32_valid(f1a_rd32_valid),.rd32_data(f1a_rd32_data));
  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) FC2MEM(.clk,
    .wr16_valid(1'b0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(fc2_rd_en),.rd16_token_id(fc2_rd_pix),.rd16_co_tile(fc2_rd_co),.rd16_valid(fc2_rd_valid),.rd16_data(fc2_rd_data),
    .wr32_valid(f2_wr32_v),.wr32_token_id(f2_wr32_pix),.wr32_co_tile(f2_wr32_co),.wr32_data(f2_wr32_data),
    .rd32_en(1'b0),.rd32_token_id('0),.rd32_co_tile('0),.rd32_valid(),.rd32_data());
  swin_tensor_mem16 #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) YMEM(.clk,.wr_valid(y_wr_v),.wr_token_id(y_wr_pix),.wr_co_tile(y_wr_co),.wr_data(y_wr_data),.rd_en(y_rd_en),.rd_token_id(y_rd_pixel),.rd_co_tile(y_rd_co_tile),.rd_valid(y_rd_valid),.rd_data(y_rd_data));

  // ---- Norm1 ---------------------------------------------------------------
  swin_norm_16lane_top #(.H(H),.W(W),.CHANNELS(CHANNELS),.BN_M_MEM({ASSET_DIR,"/norm/norm1_M_i32.mem"}),.BN_SHIFT_MEM({ASSET_DIR,"/norm/norm1_shift_i16.mem"}),.BN_BIAS_MEM({ASSET_DIR,"/norm/norm1_bias_i32.mem"})) N1(
 .clk,.rst_n,.start(n1_start),.done(n1_done),.src_rd_en(n1x_rd_en),.src_rd_pixel_id(n1x_pix),.src_rd_co_tile(n1x_co),.src_rd_valid(x_rd_valid),.src_rd_data(x_rd_data),.dst_wr_valid(n1_wr_v),.dst_wr_pixel_id(n1_wr_pix),.dst_wr_co_tile(n1_wr_co),.dst_wr_data(n1_wr_data));

  // ---- Shift/partition and window memory ----------------------------------
  logic part_ov;logic[WIN_W-1:0]part_win;logic[TOK_W-1:0]part_tok;logic[CO_W-1:0]part_co;logic signed[127:0]part_data;
  swin_window_partition_mem16 #(.H(H),.W(W),.CHANNELS(CHANNELS),.WS(WS),.SHIFT_Y(SHIFT),.SHIFT_X(SHIFT)) PART(
 .clk,.rst_n,.start(part_start),.busy(),.done(part_done),.src_rd_en(part_n1_rd_en),.src_rd_pixel_id(part_n1_pix),.src_rd_co_tile(part_n1_co),.src_rd_valid(n1_rd_valid),.src_rd_data(n1_rd_data),.out_valid(part_ov),.out_ready(1'b1),.out_window_id(part_win),.out_token_id(part_tok),.out_co_tile(part_co),.out_data(part_data));
  logic win1_rd32_en;logic[WIN_W-1:0]win1_rd32_win;logic[TOK_W-1:0]win1_rd32_tok;logic[CO32_W-1:0]win1_rd32_co;logic win1_rd32_valid;logic signed[255:0]win1_rd32_data;
  swin_window_mem16x32_bridge #(.NUM_WINDOWS(NUM_WINDOWS),.TOKENS_PER_WINDOW(WTOKENS),.CHANNELS(CHANNELS)) WIN1(.clk,
    .wr16_valid(part_ov),.wr16_window_id(part_win),.wr16_token_id(part_tok),.wr16_co_tile(part_co),.wr16_data(part_data),
    .rd16_en(1'b0),.rd16_window_id('0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(1'b0),.wr32_window_id('0),.wr32_token_id('0),.wr32_co_tile('0),.wr32_data('0),
    .rd32_en(win1_rd32_en),.rd32_window_id(win1_rd32_win),.rd32_token_id(win1_rd32_tok),.rd32_co_tile(win1_rd32_co),.rd32_valid(win1_rd32_valid),.rd32_data(win1_rd32_data));

  // ---- Q/K/V dense and flat banked output: WS32 datapath -------------------
  logic qsrc_en;logic[TOKEN_W-1:0]qsrc_tok;logic[CO32_W-1:0]qsrc_co;logic qwr_v;logic[1:0]qwr_op;logic[TOKEN_W-1:0]qwr_tok;logic[CO32_W-1:0]qwr_co;logic signed[255:0]qwr_data;
  always_comb begin win1_rd32_en=qsrc_en;win1_rd32_win=qsrc_tok/WTOKENS;win1_rd32_tok=qsrc_tok%WTOKENS;win1_rd32_co=qsrc_co;end
  swin_qkv_live_stage_32 #(.TOKENS(PIXELS),.CIN(CHANNELS),.COUT(CHANNELS),.Q_WEIGHT({ASSET_DIR,"/dense/q_weight_i8.mem"}),.K_WEIGHT({ASSET_DIR,"/dense/k_weight_i8.mem"}),.V_WEIGHT({ASSET_DIR,"/dense/v_weight_i8.mem"}),.Q_BIAS({ASSET_DIR,"/dense/q_folded_bias_i32.mem"}),.Q_M({ASSET_DIR,"/dense/q_requant_M_i32.mem"}),.Q_SHIFT({ASSET_DIR,"/dense/q_requant_shift_i16.mem"}),.K_BIAS({ASSET_DIR,"/dense/k_folded_bias_i32.mem"}),.K_M({ASSET_DIR,"/dense/k_requant_M_i32.mem"}),.K_SHIFT({ASSET_DIR,"/dense/k_requant_shift_i16.mem"}),.V_BIAS({ASSET_DIR,"/dense/v_folded_bias_i32.mem"}),.V_M({ASSET_DIR,"/dense/v_requant_M_i32.mem"}),.V_SHIFT({ASSET_DIR,"/dense/v_requant_shift_i16.mem"})) QKV(
 .clk,.rst_n,.start(qkv_start),.busy(),.done(qkv_done),.src_rd_en(qsrc_en),.src_rd_token(qsrc_tok),.src_rd_co_tile(qsrc_co),.src_rd_valid(win1_rd32_valid),.src_rd_data(win1_rd32_data),.wr_valid(qwr_v),.wr_op(qwr_op),.wr_token(qwr_tok),.wr_co_tile(qwr_co),.wr_data(qwr_data));
  logic qkv_rd_en;logic[1:0]qkv_rd_op;logic[TOKEN_W-1:0]qkv_rd_tok;logic[CO32_W-1:0]qkv_rd_co;logic qkv_rd_valid;logic signed[255:0]qkv_rd_data;
  swin_qkv_banked_mem16x32_rw #(.TOKENS(PIXELS),.COUT(CHANNELS)) QKVMEM(.clk,
    .wr16_valid(1'b0),.wr16_op('0),.wr16_token('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(1'b0),.rd16_op('0),.rd16_token('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(qwr_v),.wr32_op(qwr_op),.wr32_token(qwr_tok),.wr32_co_tile(qwr_co),.wr32_data(qwr_data),
    .rd32_en(qkv_rd_en),.rd32_op(qkv_rd_op),.rd32_token(qkv_rd_tok),.rd32_co_tile(qkv_rd_co),.rd32_valid(qkv_rd_valid),.rd32_data(qkv_rd_data));

  // ---- Attention, carries window ID to context memory: WS32 ---------------
  logic ctx_wr_v;logic[WIN_W-1:0]ctx_wr_win;logic[TOK_W-1:0]ctx_wr_tok;logic[CO32_W-1:0]ctx_wr_co;logic signed[255:0]ctx_wr_data;
  swin_attention_scheduler_32 #(.NUM_WINDOWS(NUM_WINDOWS),.TOKENS(WTOKENS),.HEADS(HEADS),.HEAD_DIM(HEAD_DIM),.QK_M(QK_M),.QK_SHIFT(QK_SHIFT),.CTX_M(CTX_M),.CTX_SHIFT(CTX_SHIFT),.RELPOS_EXPANDED_MEM({ASSET_DIR,"/attention/relpos_expanded_logits_i16.mem"}),.EXP_LUT_MEM({ASSET_DIR,"/attention/softmax_exp_lut_u16.mem"})) ATTN(
 .clk,.rst_n,.start(attn_start),.busy(),.done(attn_done),.qkv_rd_en(qkv_rd_en),.qkv_rd_op(qkv_rd_op),.qkv_rd_token(qkv_rd_tok),.qkv_rd_co_tile(qkv_rd_co),.qkv_rd_valid(qkv_rd_valid),.qkv_rd_data(qkv_rd_data),.ctx_wr_valid(ctx_wr_v),.ctx_wr_window(ctx_wr_win),.ctx_wr_token(ctx_wr_tok),.ctx_wr_co_tile(ctx_wr_co),.ctx_wr_data(ctx_wr_data));
  logic ctx_rd32_en;logic[WIN_W-1:0]ctx_rd32_win;logic[TOK_W-1:0]ctx_rd32_tok;logic[CO32_W-1:0]ctx_rd32_co;logic ctx_rd32_valid;logic signed[255:0]ctx_rd32_data;
  swin_window_mem16x32_bridge #(.NUM_WINDOWS(NUM_WINDOWS),.TOKENS_PER_WINDOW(WTOKENS),.CHANNELS(CHANNELS)) CTX(.clk,
    .wr16_valid(1'b0),.wr16_window_id('0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(1'b0),.rd16_window_id('0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(ctx_wr_v),.wr32_window_id(ctx_wr_win),.wr32_token_id(ctx_wr_tok),.wr32_co_tile(ctx_wr_co),.wr32_data(ctx_wr_data),
    .rd32_en(ctx_rd32_en),.rd32_window_id(ctx_rd32_win),.rd32_token_id(ctx_rd32_tok),.rd32_co_tile(ctx_rd32_co),.rd32_valid(ctx_rd32_valid),.rd32_data(ctx_rd32_data));

  // ---- Attention projection: WS32 -----------------------------------------
  logic psrc_en;logic[TOKEN_W-1:0]psrc_tok;logic[CO32_W-1:0]psrc_co;logic pov;logic[TOKEN_W-1:0]ptok;logic[CO32_W-1:0]pco;logic signed[255:0]pdata;
  always_comb begin ctx_rd32_en=psrc_en;ctx_rd32_win=psrc_tok/WTOKENS;ctx_rd32_tok=psrc_tok%WTOKENS;ctx_rd32_co=psrc_co;end
  swin_dense_live_stage_32 #(.TOKENS(PIXELS),.CIN(CHANNELS),.COUT(CHANNELS),.WEIGHT_MEM({ASSET_DIR,"/dense/proj_weight_i8.mem"}),.BIAS_MEM({ASSET_DIR,"/dense/proj_folded_bias_i32.mem"}),.M_MEM({ASSET_DIR,"/dense/proj_requant_M_i32.mem"}),.SHIFT_MEM({ASSET_DIR,"/dense/proj_requant_shift_i16.mem"})) PROJ(
 .clk,.rst_n,.start(proj_start),.busy(),.done(proj_done),.src_rd_en(psrc_en),.src_rd_token(psrc_tok),.src_rd_co_tile(psrc_co),.src_rd_valid(ctx_rd32_valid),.src_rd_data(ctx_rd32_data),.out_valid(pov),.out_token(ptok),.out_co_tile(pco),.out_data(pdata));
  logic ap_rd_en;logic[WIN_W-1:0]ap_rd_win;logic[TOK_W-1:0]ap_rd_tok;logic[CO_W-1:0]ap_rd_co;logic ap_rd_valid;logic signed[127:0]ap_rd_data;
  swin_window_mem16x32_bridge #(.NUM_WINDOWS(NUM_WINDOWS),.TOKENS_PER_WINDOW(WTOKENS),.CHANNELS(CHANNELS)) APWIN(.clk,
    .wr16_valid(1'b0),.wr16_window_id('0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(ap_rd_en),.rd16_window_id(ap_rd_win),.rd16_token_id(ap_rd_tok),.rd16_co_tile(ap_rd_co),.rd16_valid(ap_rd_valid),.rd16_data(ap_rd_data),
    .wr32_valid(pov),.wr32_window_id(ptok/WTOKENS),.wr32_token_id(ptok%WTOKENS),.wr32_co_tile(pco),.wr32_data(pdata),
    .rd32_en(1'b0),.rd32_window_id('0),.rd32_token_id('0),.rd32_co_tile('0),.rd32_valid(),.rd32_data());

  // ---- Reverse windows/inverse shift ----------------------------------------
  logic rdr_done,rdr_busy,rdr_ov,rdr_or;logic[WIN_W-1:0]rdr_win;logic[TOK_W-1:0]rdr_tok;logic[CO_W-1:0]rdr_co;logic signed[127:0]rdr_data;logic rev_done_i,rev_busy;logic rev_seen,reader_seen;
  swin_window_reader_mem16 #(.NUM_WINDOWS(NUM_WINDOWS),.TOKENS(WTOKENS),.CHANNELS(CHANNELS)) READER(.clk,.rst_n,.start(rev_start),.busy(rdr_busy),.done(rdr_done),.mem_rd_en(ap_rd_en),.mem_rd_window_id(ap_rd_win),.mem_rd_token_id(ap_rd_tok),.mem_rd_co_tile(ap_rd_co),.mem_rd_valid(ap_rd_valid),.mem_rd_data(ap_rd_data),.out_valid(rdr_ov),.out_ready(rdr_or),.out_window_id(rdr_win),.out_token_id(rdr_tok),.out_co_tile(rdr_co),.out_data(rdr_data));
  swin_reverse_window_inverse_shift_mem16 #(.H(H),.W(W),.CHANNELS(CHANNELS),.WS(WS),.SHIFT_Y(SHIFT),.SHIFT_X(SHIFT)) REV(.clk,.rst_n,.start(rev_start),.busy(rev_busy),.done(rev_done_i),.in_valid(rdr_ov),.in_ready(rdr_or),.in_window_id(rdr_win),.in_token_id(rdr_tok),.in_co_tile(rdr_co),.in_data(rdr_data),.dst_wr_valid(h_wr_v),.dst_wr_pixel_id(h_wr_pix),.dst_wr_co_tile(h_wr_co),.dst_wr_data(h_wr_data));
  always_ff @(posedge clk or negedge rst_n) begin if(!rst_n)begin reader_seen<=0;rev_seen<=0;end else begin if(rev_start)begin reader_seen<=0;rev_seen<=0;end if(rdr_done)reader_seen<=1; if(rev_done_i)rev_seen<=1;end end
  assign rev_done=(rdr_done||reader_seen)&&(rev_done_i||rev_seen);

  // ---- Residual1 -> Norm2 ---------------------------------------------------
  swin_residual_live_stage #(.PIXELS(PIXELS),.CHANNELS(CHANNELS),.A_M_FILE({ASSET_DIR,"/residual/res1_a_M_i32.mem"}),.A_SHIFT_FILE({ASSET_DIR,"/residual/res1_a_shift_i16.mem"}),.B_M_FILE({ASSET_DIR,"/residual/res1_b_M_i32.mem"}),.B_SHIFT_FILE({ASSET_DIR,"/residual/res1_b_shift_i16.mem"})) R1(
 .clk,.rst_n,.start(r1_start),.done(r1_done),.a_rd_en(r1x_rd_en),.a_rd_pixel(r1x_pix),.a_rd_co(r1x_co),.a_rd_valid(x_rd_valid),.a_rd_data(x_rd_data),.b_rd_en(h_rd_en),.b_rd_pixel(h_rd_pix),.b_rd_co(h_rd_co),.b_rd_valid(h_rd_valid),.b_rd_data(h_rd_data),.y_wr_valid(res1_wr_v),.y_wr_pixel(res1_wr_pix),.y_wr_co(res1_wr_co),.y_wr_data(res1_wr_data));
  swin_norm_16lane_top #(.H(H),.W(W),.CHANNELS(CHANNELS),.BN_M_MEM({ASSET_DIR,"/norm/norm2_M_i32.mem"}),.BN_SHIFT_MEM({ASSET_DIR,"/norm/norm2_shift_i16.mem"}),.BN_BIAS_MEM({ASSET_DIR,"/norm/norm2_bias_i32.mem"})) N2(
 .clk,.rst_n,.start(n2_start),.done(n2_done),.src_rd_en(n2res_rd_en),.src_rd_pixel_id(n2res_pix),.src_rd_co_tile(n2res_co),.src_rd_valid(res1_rd_valid),.src_rd_data(res1_rd_data),.dst_wr_valid(n2_wr_v),.dst_wr_pixel_id(n2_wr_pix),.dst_wr_co_tile(n2_wr_co),.dst_wr_data(n2_wr_data));

  // ---- FC1 -> PolySiLU -> FC2 -> Residual2 ---------------------------------
  swin_dense_live_stage_32 #(.TOKENS(PIXELS),.CIN(CHANNELS),.COUT(FC1_C),.WEIGHT_MEM({ASSET_DIR,"/dense/fc1_weight_i8.mem"}),.BIAS_MEM({ASSET_DIR,"/dense/fc1_folded_bias_i32.mem"}),.M_MEM({ASSET_DIR,"/dense/fc1_requant_M_i32.mem"}),.SHIFT_MEM({ASSET_DIR,"/dense/fc1_requant_shift_i16.mem"})) FC1(
 .clk,.rst_n,.start(f1_start),.busy(),.done(f1_done),.src_rd_en(f1n2_rd32_en),.src_rd_token(f1n2_pix32),.src_rd_co_tile(f1n2_co32),.src_rd_valid(n2_rd32_valid),.src_rd_data(n2_rd32_data),.out_valid(f1_wr32_v),.out_token(f1_wr32_pix),.out_co_tile(f1_wr32_co),.out_data(f1_wr32_data));
  // Poly constants are selected in the family/block wrapper. Generic defaults are intentionally not used for a signoff build.
  swin_poly_silu_live_stage #(
    .PIXELS(PIXELS),.COUT(FC1_C),.LANES(LANES),
    .PRE_SCALE_Q(POLY_PRE_SCALE_Q),.PRE_SCALE_SHIFT(POLY_PRE_SCALE_SHIFT),
    .CLAMP_Q(POLY_CLAMP_Q),.CLAMP_SHIFT(POLY_CLAMP_SHIFT),
    .H_TO_OUT_M(POLY_H_TO_OUT_M),.H_TO_OUT_SHIFT(POLY_H_TO_OUT_SHIFT),
    .U_TO_Q20_M(POLY_U_TO_Q20_M),.U_TO_Q20_SHIFT(POLY_U_TO_Q20_SHIFT),
    .X_TO_OUT_M(POLY_X_TO_OUT_M),.X_TO_OUT_SHIFT(POLY_X_TO_OUT_SHIFT),
    .COEFF_MEM(POLY_COEFF_MEM)
  ) POLY(.clk,.rst_n,.start(poly_start),.done(poly_done),.src_rd_en(poly_rd_en),.src_rd_pixel(poly_pix),.src_rd_co(poly_co),.src_rd_valid(f1p_rd_valid),.src_rd_data(f1p_rd_data),.dst_wr_valid(pa_wr_v),.dst_wr_pixel(pa_wr_pix),.dst_wr_co(pa_wr_co),.dst_wr_data(pa_wr_data));
  swin_dense_live_stage_32 #(.TOKENS(PIXELS),.CIN(FC1_C),.COUT(CHANNELS),.WEIGHT_MEM({ASSET_DIR,"/dense/fc2_weight_i8.mem"}),.BIAS_MEM({ASSET_DIR,"/dense/fc2_folded_bias_i32.mem"}),.M_MEM({ASSET_DIR,"/dense/fc2_requant_M_i32.mem"}),.SHIFT_MEM({ASSET_DIR,"/dense/fc2_requant_shift_i16.mem"})) FC2(
 .clk,.rst_n,.start(f2_start),.busy(),.done(f2_done),.src_rd_en(f2_rd32_en),.src_rd_token(f2_pix32),.src_rd_co_tile(f2_co32),.src_rd_valid(f1a_rd32_valid),.src_rd_data(f1a_rd32_data),.out_valid(f2_wr32_v),.out_token(f2_wr32_pix),.out_co_tile(f2_wr32_co),.out_data(f2_wr32_data));
  swin_residual_live_stage #(.PIXELS(PIXELS),.CHANNELS(CHANNELS),.A_M_FILE({ASSET_DIR,"/residual/res2_a_M_i32.mem"}),.A_SHIFT_FILE({ASSET_DIR,"/residual/res2_a_shift_i16.mem"}),.B_M_FILE({ASSET_DIR,"/residual/res2_b_M_i32.mem"}),.B_SHIFT_FILE({ASSET_DIR,"/residual/res2_b_shift_i16.mem"})) R2(
 .clk,.rst_n,.start(r2_start),.done(r2_done),.a_rd_en(r2res_rd_en),.a_rd_pixel(r2res_pix),.a_rd_co(r2res_co),.a_rd_valid(res1_rd_valid),.a_rd_data(res1_rd_data),.b_rd_en(r2fc_rd_en),.b_rd_pixel(r2fc_pix),.b_rd_co(r2fc_co),.b_rd_valid(fc2_rd_valid),.b_rd_data(fc2_rd_data),.y_wr_valid(y_wr_v),.y_wr_pixel(y_wr_pix),.y_wr_co(y_wr_co),.y_wr_data(y_wr_data));

endmodule
