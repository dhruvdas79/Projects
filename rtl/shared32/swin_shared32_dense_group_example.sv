`timescale 1ns/1ps
// ============================================================================
// swin_shared32_dense_group_example.sv
//
// Example wiring pattern: QKV, PROJ, FC1, FC2 clients all share exactly one
// swin_shared32_mac_service. This is not a full Swin block replacement by
// itself because source/output memories are project-specific, but it shows the
// exact connection pattern needed inside swin_block_live_core_shared32.
//
// Count the physical core in this example:
//   grep -R "ws32x32_weight_stationary_core" rtl/shared32
// Only swin_shared32_mac_service instantiates it.
// ============================================================================
module swin_shared32_dense_group_example #(
  parameter int TOKENS=900,
  parameter int CHANNELS=128,
  parameter int FC1_C=512,
  parameter int PE_K=32,
  parameter int PE_N=32,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CO32_W=((CHANNELS/PE_N)<=1)?1:$clog2(CHANNELS/PE_N),
  parameter int FC1_CO32_W=((FC1_C/PE_N)<=1)?1:$clog2(FC1_C/PE_N),
  parameter [8*256-1:0] ASSET_DIR = "generated/swin_p4_0"
)(
  input logic clk,
  input logic rst_n,

  input logic qkv_start,
  output logic qkv_done,
  input logic proj_start,
  output logic proj_done,
  input logic fc1_start,
  output logic fc1_done,
  input logic fc2_start,
  output logic fc2_done,

  // This example keeps memory ports external so it can be dropped into the
  // existing block core without changing the tensor memories here.
  output logic qkv_src_rd_en,
  output logic [TOKEN_W-1:0] qkv_src_rd_token,
  output logic [CO32_W-1:0] qkv_src_rd_co_tile,
  input  logic qkv_src_rd_valid,
  input  logic signed [255:0] qkv_src_rd_data,
  output logic qkv_wr_valid,
  output logic [1:0] qkv_wr_op,
  output logic [TOKEN_W-1:0] qkv_wr_token,
  output logic [CO32_W-1:0] qkv_wr_co_tile,
  output logic signed [255:0] qkv_wr_data,

  output logic proj_src_rd_en,
  output logic [TOKEN_W-1:0] proj_src_rd_token,
  output logic [CO32_W-1:0] proj_src_rd_co_tile,
  input  logic proj_src_rd_valid,
  input  logic signed [255:0] proj_src_rd_data,
  output logic proj_out_valid,
  output logic [TOKEN_W-1:0] proj_out_token,
  output logic [CO32_W-1:0] proj_out_co_tile,
  output logic signed [255:0] proj_out_data,

  output logic fc1_src_rd_en,
  output logic [TOKEN_W-1:0] fc1_src_rd_token,
  output logic [CO32_W-1:0] fc1_src_rd_co_tile,
  input  logic fc1_src_rd_valid,
  input  logic signed [255:0] fc1_src_rd_data,
  output logic fc1_out_valid,
  output logic [TOKEN_W-1:0] fc1_out_token,
  output logic [FC1_CO32_W-1:0] fc1_out_co_tile,
  output logic signed [255:0] fc1_out_data,

  output logic fc2_src_rd_en,
  output logic [TOKEN_W-1:0] fc2_src_rd_token,
  output logic [FC1_CO32_W-1:0] fc2_src_rd_co_tile,
  input  logic fc2_src_rd_valid,
  input  logic signed [255:0] fc2_src_rd_data,
  output logic fc2_out_valid,
  output logic [TOKEN_W-1:0] fc2_out_token,
  output logic [CO32_W-1:0] fc2_out_co_tile,
  output logic signed [255:0] fc2_out_data
);
  localparam int NUM_CLIENTS=8;

  logic [NUM_CLIENTS-1:0] req, grant;
  logic [11:0] cfg_tokens [0:NUM_CLIENTS-1];
  logic [3:0] cfg_k [0:NUM_CLIENTS-1];
  logic [3:0] cfg_n [0:NUM_CLIENTS-1];
  logic signed [8:0] c_in_vec [0:NUM_CLIENTS-1][0:PE_K-1];
  logic signed [8:0] c_w_row [0:NUM_CLIENTS-1][0:PE_N-1];

  logic svc_start, svc_busy, svc_done;
  logic [11:0] svc_cfg_tokens;
  logic [3:0] svc_cfg_k, svc_cfg_n;
  logic signed [8:0] svc_in_vec [0:PE_K-1];
  logic signed [8:0] svc_w_row [0:PE_N-1];
  logic svc_stream_valid, svc_wload, svc_raw_valid;
  logic [11:0] svc_stream_token, svc_raw_token;
  logic [3:0] svc_ci, svc_co, svc_raw_co;
  logic [4:0] svc_widx;
  logic signed [63:0] svc_raw_acc [0:PE_N-1];

  swin_shared32_arbiter8 #(.NUM_CLIENTS(NUM_CLIENTS)) ARB(
    .clk,.rst_n,.client_req(req),.client_grant(grant),
    .client_cfg_tokens_m1(cfg_tokens),.client_cfg_k_tiles_m1(cfg_k),.client_cfg_n_tiles_m1(cfg_n),
    .client_input_vector(c_in_vec),.client_weight_row_values(c_w_row),
    .svc_start(svc_start),.svc_busy(svc_busy),.svc_done(svc_done),
    .svc_cfg_tokens_m1(svc_cfg_tokens),.svc_cfg_k_tiles_m1(svc_cfg_k),.svc_cfg_n_tiles_m1(svc_cfg_n),
    .svc_input_vector(svc_in_vec),.svc_weight_row_values(svc_w_row)
  );

  swin_shared32_mac_service SERVICE(
    .clk,.rst_n,.start(svc_start),.busy(svc_busy),.done(svc_done),
    .cfg_tokens_m1(svc_cfg_tokens),.cfg_k_tiles_m1(svc_cfg_k),.cfg_n_tiles_m1(svc_cfg_n),
    .stream_valid(svc_stream_valid),.stream_token_id(svc_stream_token),
    .active_ci_tile(svc_ci),.active_co_tile(svc_co),
    .weight_row_load(svc_wload),.weight_row_index(svc_widx),
    .input_vector(svc_in_vec),.weight_row_values(svc_w_row),
    .raw_valid(svc_raw_valid),.raw_token_id(svc_raw_token),.raw_co_tile(svc_raw_co),.raw_acc(svc_raw_acc)
  );

  // Client 0: QKV
  swin_qkv_live_stage_shared32_client #(
    .TOKENS(TOKENS),.CIN(CHANNELS),.COUT(CHANNELS),
    .Q_WEIGHT({ASSET_DIR,"/dense/q_weight_i8.mem"}),.K_WEIGHT({ASSET_DIR,"/dense/k_weight_i8.mem"}),.V_WEIGHT({ASSET_DIR,"/dense/v_weight_i8.mem"}),
    .Q_BIAS({ASSET_DIR,"/dense/q_folded_bias_i32.mem"}),.Q_M({ASSET_DIR,"/dense/q_requant_M_i32.mem"}),.Q_SHIFT({ASSET_DIR,"/dense/q_requant_shift_i16.mem"}),
    .K_BIAS({ASSET_DIR,"/dense/k_folded_bias_i32.mem"}),.K_M({ASSET_DIR,"/dense/k_requant_M_i32.mem"}),.K_SHIFT({ASSET_DIR,"/dense/k_requant_shift_i16.mem"}),
    .V_BIAS({ASSET_DIR,"/dense/v_folded_bias_i32.mem"}),.V_M({ASSET_DIR,"/dense/v_requant_M_i32.mem"}),.V_SHIFT({ASSET_DIR,"/dense/v_requant_shift_i16.mem"})
  ) QKV(
    .clk,.rst_n,.start(qkv_start),.busy(),.done(qkv_done),
    .src_rd_en(qkv_src_rd_en),.src_rd_token(qkv_src_rd_token),.src_rd_co_tile(qkv_src_rd_co_tile),.src_rd_valid(qkv_src_rd_valid),.src_rd_data(qkv_src_rd_data),
    .wr_valid(qkv_wr_valid),.wr_op(qkv_wr_op),.wr_token(qkv_wr_token),.wr_co_tile(qkv_wr_co_tile),.wr_data(qkv_wr_data),
    .client_req(req[0]),.client_grant(grant[0]),.client_cfg_tokens_m1(cfg_tokens[0]),.client_cfg_k_tiles_m1(cfg_k[0]),.client_cfg_n_tiles_m1(cfg_n[0]),
    .client_input_vector(c_in_vec[0]),.client_weight_row_values(c_w_row[0]),
    .svc_stream_valid(svc_stream_valid),.svc_stream_token_id(svc_stream_token),.svc_active_ci_tile(svc_ci),.svc_active_co_tile(svc_co),.svc_weight_row_load(svc_wload),.svc_weight_row_index(svc_widx),.svc_done(svc_done),.svc_raw_valid(svc_raw_valid),.svc_raw_token_id(svc_raw_token),.svc_raw_co_tile(svc_raw_co),.svc_raw_acc(svc_raw_acc)
  );

  // Client 1: attention projection
  swin_dense_live_stage_shared32_client #(.TOKENS(TOKENS),.CIN(CHANNELS),.COUT(CHANNELS),.WEIGHT_MEM({ASSET_DIR,"/dense/proj_weight_i8.mem"}),.BIAS_MEM({ASSET_DIR,"/dense/proj_folded_bias_i32.mem"}),.M_MEM({ASSET_DIR,"/dense/proj_requant_M_i32.mem"}),.SHIFT_MEM({ASSET_DIR,"/dense/proj_requant_shift_i16.mem"})) PROJ(
    .clk,.rst_n,.start(proj_start),.busy(),.done(proj_done),.src_rd_en(proj_src_rd_en),.src_rd_token(proj_src_rd_token),.src_rd_co_tile(proj_src_rd_co_tile),.src_rd_valid(proj_src_rd_valid),.src_rd_data(proj_src_rd_data),.out_valid(proj_out_valid),.out_token(proj_out_token),.out_co_tile(proj_out_co_tile),.out_data(proj_out_data),
    .client_req(req[1]),.client_grant(grant[1]),.client_cfg_tokens_m1(cfg_tokens[1]),.client_cfg_k_tiles_m1(cfg_k[1]),.client_cfg_n_tiles_m1(cfg_n[1]),.client_input_vector(c_in_vec[1]),.client_weight_row_values(c_w_row[1]),
    .svc_stream_valid(svc_stream_valid),.svc_stream_token_id(svc_stream_token),.svc_active_ci_tile(svc_ci),.svc_active_co_tile(svc_co),.svc_weight_row_load(svc_wload),.svc_weight_row_index(svc_widx),.svc_done(svc_done),.svc_raw_valid(svc_raw_valid),.svc_raw_token_id(svc_raw_token),.svc_raw_co_tile(svc_raw_co),.svc_raw_acc(svc_raw_acc)
  );

  // Client 2: FC1
  swin_dense_live_stage_shared32_client #(.TOKENS(TOKENS),.CIN(CHANNELS),.COUT(FC1_C),.WEIGHT_MEM({ASSET_DIR,"/dense/fc1_weight_i8.mem"}),.BIAS_MEM({ASSET_DIR,"/dense/fc1_folded_bias_i32.mem"}),.M_MEM({ASSET_DIR,"/dense/fc1_requant_M_i32.mem"}),.SHIFT_MEM({ASSET_DIR,"/dense/fc1_requant_shift_i16.mem"})) FC1(
    .clk,.rst_n,.start(fc1_start),.busy(),.done(fc1_done),.src_rd_en(fc1_src_rd_en),.src_rd_token(fc1_src_rd_token),.src_rd_co_tile(fc1_src_rd_co_tile),.src_rd_valid(fc1_src_rd_valid),.src_rd_data(fc1_src_rd_data),.out_valid(fc1_out_valid),.out_token(fc1_out_token),.out_co_tile(fc1_out_co_tile),.out_data(fc1_out_data),
    .client_req(req[2]),.client_grant(grant[2]),.client_cfg_tokens_m1(cfg_tokens[2]),.client_cfg_k_tiles_m1(cfg_k[2]),.client_cfg_n_tiles_m1(cfg_n[2]),.client_input_vector(c_in_vec[2]),.client_weight_row_values(c_w_row[2]),
    .svc_stream_valid(svc_stream_valid),.svc_stream_token_id(svc_stream_token),.svc_active_ci_tile(svc_ci),.svc_active_co_tile(svc_co),.svc_weight_row_load(svc_wload),.svc_weight_row_index(svc_widx),.svc_done(svc_done),.svc_raw_valid(svc_raw_valid),.svc_raw_token_id(svc_raw_token),.svc_raw_co_tile(svc_raw_co),.svc_raw_acc(svc_raw_acc)
  );

  // Client 3: FC2
  swin_dense_live_stage_shared32_client #(.TOKENS(TOKENS),.CIN(FC1_C),.COUT(CHANNELS),.WEIGHT_MEM({ASSET_DIR,"/dense/fc2_weight_i8.mem"}),.BIAS_MEM({ASSET_DIR,"/dense/fc2_folded_bias_i32.mem"}),.M_MEM({ASSET_DIR,"/dense/fc2_requant_M_i32.mem"}),.SHIFT_MEM({ASSET_DIR,"/dense/fc2_requant_shift_i16.mem"})) FC2(
    .clk,.rst_n,.start(fc2_start),.busy(),.done(fc2_done),.src_rd_en(fc2_src_rd_en),.src_rd_token(fc2_src_rd_token),.src_rd_co_tile(fc2_src_rd_co_tile),.src_rd_valid(fc2_src_rd_valid),.src_rd_data(fc2_src_rd_data),.out_valid(fc2_out_valid),.out_token(fc2_out_token),.out_co_tile(fc2_out_co_tile),.out_data(fc2_out_data),
    .client_req(req[3]),.client_grant(grant[3]),.client_cfg_tokens_m1(cfg_tokens[3]),.client_cfg_k_tiles_m1(cfg_k[3]),.client_cfg_n_tiles_m1(cfg_n[3]),.client_input_vector(c_in_vec[3]),.client_weight_row_values(c_w_row[3]),
    .svc_stream_valid(svc_stream_valid),.svc_stream_token_id(svc_stream_token),.svc_active_ci_tile(svc_ci),.svc_active_co_tile(svc_co),.svc_weight_row_load(svc_wload),.svc_weight_row_index(svc_widx),.svc_done(svc_done),.svc_raw_valid(svc_raw_valid),.svc_raw_token_id(svc_raw_token),.svc_raw_co_tile(svc_raw_co),.svc_raw_acc(svc_raw_acc)
  );

  // Unused clients.
  genvar u;
  generate
    for (u=4; u<NUM_CLIENTS; u=u+1) begin : G_UNUSED
      assign req[u] = 1'b0;
      assign cfg_tokens[u] = '0;
      assign cfg_k[u] = '0;
      assign cfg_n[u] = '0;
      for (genvar l=0; l<PE_K; l=l+1) begin : G_IV
        assign c_in_vec[u][l] = '0;
      end
      for (genvar l=0; l<PE_N; l=l+1) begin : G_WV
        assign c_w_row[u][l] = '0;
      end
    end
  endgenerate
endmodule
