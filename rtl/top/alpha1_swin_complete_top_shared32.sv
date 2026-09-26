`timescale 1ns/1ps
// ============================================================================
// alpha1_swin_complete_top_shared32.sv
//
// Self-contained Swin-only shared32 top.  It accepts the same 16-lane
// projection-ready handoff as the old alpha1_swin_complete_top, but internally
// P4 and P3 Swin chains share exactly one 32x32 MAC service.
//
// Use this top for Swin-only synthesis/resource checks.
// Use projection_swin_shared32_top for projection+Swin on the same service.
// ============================================================================
module alpha1_swin_complete_top_shared32 (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic abort,

    input  logic p4_projection_ready,
    input  logic p4_proj_wr_valid,
    input  logic [9:0] p4_proj_wr_pixel,
    input  logic [2:0] p4_proj_wr_co_tile,
    input  logic signed [127:0] p4_proj_wr_data,

    input  logic p3_projection_ready,
    input  logic p3_proj_wr_valid,
    input  logic [11:0] p3_proj_wr_pixel,
    input  logic [2:0] p3_proj_wr_co_tile,
    input  logic signed [127:0] p3_proj_wr_data,

    input  logic p4_out_rd_en,
    input  logic [9:0] p4_out_rd_pixel,
    input  logic [2:0] p4_out_rd_co_tile,
    output logic p4_out_rd_valid,
    output logic signed [127:0] p4_out_rd_data,

    input  logic p3_out_rd_en,
    input  logic [11:0] p3_out_rd_pixel,
    input  logic [2:0] p3_out_rd_co_tile,
    output logic p3_out_rd_valid,
    output logic signed [127:0] p3_out_rd_data,

    output logic busy,
    output logic done,
    output logic aborted,
    output logic [3:0] state_code,
    output logic p4_swin_busy,
    output logic p4_swin_done,
    output logic p3_swin_busy,
    output logic p3_swin_done
);
    logic p4_start, p3_start;
    logic child_rst_n;
    assign child_rst_n = rst_n & ~abort;

    alpha1_swin_p4_then_p3_controller u_ctrl (
        .clk,.rst_n,.start,.abort,
        .p4_projection_ready,.p3_projection_ready,
        .p4_swin_done,.p3_swin_done,
        .p4_swin_start(p4_start),.p3_swin_start(p3_start),
        .busy,.done,.aborted,.state_code
    );

    localparam int NUM_CLIENTS = 2;
    logic [NUM_CLIENTS-1:0] client_req, client_grant;
    logic [11:0] client_cfg_tokens_m1 [0:NUM_CLIENTS-1];
    logic [3:0]  client_cfg_k_tiles_m1 [0:NUM_CLIENTS-1];
    logic [3:0]  client_cfg_n_tiles_m1 [0:NUM_CLIENTS-1];
    logic signed [8:0] client_input_vector [0:NUM_CLIENTS-1][0:31];
    logic signed [8:0] client_weight_row_values [0:NUM_CLIENTS-1][0:31];

    logic svc_start, svc_busy, svc_done;
    logic [11:0] svc_cfg_tokens_m1;
    logic [3:0]  svc_cfg_k_tiles_m1, svc_cfg_n_tiles_m1;
    logic signed [8:0] svc_input_vector [0:31];
    logic signed [8:0] svc_weight_row_values [0:31];

    logic svc_stream_valid; logic [11:0] svc_stream_token_id;
    logic [3:0] svc_active_ci_tile, svc_active_co_tile;
    logic svc_weight_row_load; logic [4:0] svc_weight_row_index;
    logic svc_raw_valid; logic [11:0] svc_raw_token_id; logic [3:0] svc_raw_co_tile;
    logic signed [63:0] svc_raw_acc [0:31];

    swin_shared32_arbiter8 #(.NUM_CLIENTS(NUM_CLIENTS)) u_global_arb (
        .clk,.rst_n(child_rst_n),
        .client_req(client_req),.client_grant(client_grant),
        .client_cfg_tokens_m1(client_cfg_tokens_m1),
        .client_cfg_k_tiles_m1(client_cfg_k_tiles_m1),
        .client_cfg_n_tiles_m1(client_cfg_n_tiles_m1),
        .client_input_vector(client_input_vector),
        .client_weight_row_values(client_weight_row_values),
        .svc_start(svc_start),.svc_busy(svc_busy),.svc_done(svc_done),
        .svc_cfg_tokens_m1(svc_cfg_tokens_m1),.svc_cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.svc_cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .svc_input_vector(svc_input_vector),.svc_weight_row_values(svc_weight_row_values)
    );

    swin_shared32_mac_service u_only_shared32_service (
        .clk,.rst_n(child_rst_n),.start(svc_start),.busy(svc_busy),.done(svc_done),
        .cfg_tokens_m1(svc_cfg_tokens_m1),.cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .stream_valid(svc_stream_valid),.stream_token_id(svc_stream_token_id),.active_ci_tile(svc_active_ci_tile),.active_co_tile(svc_active_co_tile),
        .weight_row_load(svc_weight_row_load),.weight_row_index(svc_weight_row_index),
        .input_vector(svc_input_vector),.weight_row_values(svc_weight_row_values),
        .raw_valid(svc_raw_valid),.raw_token_id(svc_raw_token_id),.raw_co_tile(svc_raw_co_tile),.raw_acc(svc_raw_acc)
    );

    swin_p4_live_chain_shared32 u_p4 (
        .clk,.rst_n(child_rst_n),.start(p4_start),.busy(p4_swin_busy),.done(p4_swin_done),
        .in_wr_valid(p4_proj_wr_valid),.in_wr_pixel(p4_proj_wr_pixel),.in_wr_co_tile(p4_proj_wr_co_tile),.in_wr_data(p4_proj_wr_data),
        .in_wr32_valid(1'b0),.in_wr32_pixel('0),.in_wr32_co_tile('0),.in_wr32_data('0),
        .out_rd_en(p4_out_rd_en),.out_rd_pixel(p4_out_rd_pixel),.out_rd_co_tile(p4_out_rd_co_tile),.out_rd_valid(p4_out_rd_valid),.out_rd_data(p4_out_rd_data),
        .client_req(client_req[0]),.client_grant(client_grant[0]),.client_cfg_tokens_m1(client_cfg_tokens_m1[0]),.client_cfg_k_tiles_m1(client_cfg_k_tiles_m1[0]),.client_cfg_n_tiles_m1(client_cfg_n_tiles_m1[0]),.client_input_vector(client_input_vector[0]),.client_weight_row_values(client_weight_row_values[0]),
        .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc
    );

    swin_p3_live_chain_shared32 u_p3 (
        .clk,.rst_n(child_rst_n),.start(p3_start),.busy(p3_swin_busy),.done(p3_swin_done),
        .in_wr_valid(p3_proj_wr_valid),.in_wr_pixel(p3_proj_wr_pixel),.in_wr_co_tile(p3_proj_wr_co_tile),.in_wr_data(p3_proj_wr_data),
        .in_wr32_valid(1'b0),.in_wr32_pixel('0),.in_wr32_co_tile('0),.in_wr32_data('0),
        .out_rd_en(p3_out_rd_en),.out_rd_pixel(p3_out_rd_pixel),.out_rd_co_tile(p3_out_rd_co_tile),.out_rd_valid(p3_out_rd_valid),.out_rd_data(p3_out_rd_data),
        .client_req(client_req[1]),.client_grant(client_grant[1]),.client_cfg_tokens_m1(client_cfg_tokens_m1[1]),.client_cfg_k_tiles_m1(client_cfg_k_tiles_m1[1]),.client_cfg_n_tiles_m1(client_cfg_n_tiles_m1[1]),.client_input_vector(client_input_vector[1]),.client_weight_row_values(client_weight_row_values[1]),
        .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc
    );
endmodule
