`timescale 1ns/1ps
// Standalone single-core post-Swin accelerator used for fast profiled validation.
module post_swin_fpn_head_shared32_profiled_top #(
  parameter int PE_K=32,
  parameter int PE_N=32
)(
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic abort,
  output logic busy,
  output logic done,

  output logic [4:0] stage_id,
  output logic stage_prepare_req,
  input  logic stage_prepare_done,
  output logic stage_done_pulse,

  output logic adapter_stream_valid,
  output logic [11:0] adapter_token,
  output logic [5:0] adapter_ci_tile,
  output logic [5:0] adapter_co_tile,
  output logic adapter_weight_row_load,
  output logic [4:0] adapter_weight_row_index,
  input  logic signed [8:0] adapter_input_vector [0:31],
  input  logic signed [8:0] adapter_weight_row_values [0:31],
  output logic [5:0] adapter_post_co_tile,
  input  logic signed [31:0] adapter_bias [0:31],
  input  logic signed [31:0] adapter_multiplier [0:31],
  input  logic signed [15:0] adapter_shift [0:31],
  output logic signed [7:0] adapter_poly_code [0:31],
  input  logic signed [7:0] adapter_poly_value [0:31],

  output logic out_valid,
  output logic [4:0] out_stage_id,
  output logic [11:0] out_token,
  output logic [5:0] out_co_tile,
  output logic [31:0] out_lane_mask,
  output logic signed [7:0] out_data [0:31],
  output logic [13:0] stage_vector_count
);
  logic client_req, client_grant;
  logic [11:0] client_cfg_tokens_m1;
  logic [5:0] client_cfg_k_tiles_m1, client_cfg_n_tiles_m1;
  logic signed [8:0] client_input_vector [0:31];
  logic signed [8:0] client_weight_row_values [0:31];

  logic svc_start, svc_busy, svc_done;
  logic [11:0] svc_cfg_tokens_m1;
  logic [5:0] svc_cfg_k_tiles_m1, svc_cfg_n_tiles_m1;
  logic signed [8:0] svc_input_vector [0:31];
  logic signed [8:0] svc_weight_row_values [0:31];
  logic svc_stream_valid;
  logic [11:0] svc_stream_token_id;
  logic [5:0] svc_active_ci_tile, svc_active_co_tile;
  logic svc_weight_row_load;
  logic [4:0] svc_weight_row_index;
  logic svc_raw_valid;
  logic [11:0] svc_raw_token_id;
  logic [5:0] svc_raw_co_tile;
  logic signed [63:0] svc_raw_acc [0:31];

  logic post_in_valid;
  logic [5:0] post_in_route;
  logic [1:0] post_in_op, post_in_layer;
  logic [11:0] post_in_token;
  logic [6:0] post_in_co;
  logic signed [63:0] post_in_value [0:31];
  logic signed [31:0] post_in_multiplier [0:31];
  logic signed [15:0] post_in_shift [0:31];
  logic post_out_valid;
  logic [5:0] post_out_route;
  logic [1:0] post_out_op, post_out_layer;
  logic [11:0] post_out_token;
  logic [6:0] post_out_co;
  logic signed [7:0] post_out_code [0:31];

  logic [0:0] arb_req, arb_grant;
  logic [11:0] arb_tokens [0:0];
  logic [5:0] arb_ktiles [0:0], arb_ntiles [0:0];
  logic signed [8:0] arb_ivec [0:0][0:31];
  logic signed [8:0] arb_wvec [0:0][0:31];
  assign arb_req[0]=client_req;
  assign client_grant=arb_grant[0];
  assign arb_tokens[0]=client_cfg_tokens_m1;
  assign arb_ktiles[0]=client_cfg_k_tiles_m1;
  assign arb_ntiles[0]=client_cfg_n_tiles_m1;
  always_comb begin
    for(int lane=0;lane<32;lane=lane+1) begin
      arb_ivec[0][lane]=client_input_vector[lane];
      arb_wvec[0][lane]=client_weight_row_values[lane];
    end
  end

  swin_shared32_arbiter8 #(.NUM_CLIENTS(1),.TILE_W(6)) u_arb (
    .clk,.rst_n,.client_req(arb_req),.client_grant(arb_grant),
    .client_cfg_tokens_m1(arb_tokens),.client_cfg_k_tiles_m1(arb_ktiles),
    .client_cfg_n_tiles_m1(arb_ntiles),.client_input_vector(arb_ivec),
    .client_weight_row_values(arb_wvec),.svc_start,.svc_busy,.svc_done,
    .svc_cfg_tokens_m1,.svc_cfg_k_tiles_m1,.svc_cfg_n_tiles_m1,
    .svc_input_vector,.svc_weight_row_values
  );

  swin_shared32_mac_service #(.PE_K(PE_K),.PE_N(PE_N),.TILE_W(6)) u_only_shared32_service (
    .clk,.rst_n,.start(svc_start),.busy(svc_busy),.done(svc_done),
    .cfg_tokens_m1(svc_cfg_tokens_m1),.cfg_k_tiles_m1(svc_cfg_k_tiles_m1),
    .cfg_n_tiles_m1(svc_cfg_n_tiles_m1),.stream_valid(svc_stream_valid),
    .stream_token_id(svc_stream_token_id),.active_ci_tile(svc_active_ci_tile),
    .active_co_tile(svc_active_co_tile),.weight_row_load(svc_weight_row_load),
    .weight_row_index(svc_weight_row_index),.input_vector_valid(1'b1),.weight_row_valid(1'b1),
        .input_vector(svc_input_vector),
    .weight_row_values(svc_weight_row_values),.raw_valid(svc_raw_valid),
    .raw_token_id(svc_raw_token_id),.raw_co_tile(svc_raw_co_tile),.raw_acc(svc_raw_acc)
  );

  shared_requant32_service #(.LANES(32),.ROUTE_W(6),.LATENCY(7)) u_only_requant (
    .clk,.rst_n,.in_valid(post_in_valid),.in_route(post_in_route),.in_op(post_in_op),
    .in_layer(post_in_layer),.in_token(post_in_token),.in_co(post_in_co),
    .in_value(post_in_value),.in_multiplier(post_in_multiplier),.in_shift(post_in_shift),
    .out_valid(post_out_valid),.out_route(post_out_route),.out_op(post_out_op),
    .out_layer(post_out_layer),.out_token(post_out_token),.out_co(post_out_co),
    .out_code(post_out_code)
  );

  post_swin_fpn_head_shared32_client u_client (
    .clk,.rst_n,.start,.abort,.busy,.done,.stage_id,.stage_prepare_req,
    .stage_prepare_done,.stage_done_pulse,.adapter_stream_valid,.adapter_token,
    .adapter_ci_tile,.adapter_co_tile,.adapter_weight_row_load,.adapter_weight_row_index,
    .adapter_input_vector,.adapter_weight_row_values,.adapter_post_co_tile,
    .adapter_bias,.adapter_multiplier,.adapter_shift,.adapter_poly_code,
    .adapter_poly_value,.client_req,.client_grant,.client_cfg_tokens_m1,
    .client_cfg_k_tiles_m1,.client_cfg_n_tiles_m1,.client_input_vector,
    .client_weight_row_values,.svc_stream_valid,.svc_stream_token_id,
    .svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,
    .svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid,.post_in_route,.post_in_op,.post_in_layer,.post_in_token,.post_in_co,
    .post_in_value,.post_in_multiplier,.post_in_shift,.post_out_valid,.post_out_route,
    .post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code,
    .out_valid,.out_stage_id,.out_token,.out_co_tile,.out_lane_mask,.out_data,
    .stage_vector_count
  );
endmodule
