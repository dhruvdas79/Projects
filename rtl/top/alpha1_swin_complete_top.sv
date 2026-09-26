`timescale 1ns/1ps
// ============================================================================
// alpha1_swin_complete_top.sv
//
// Full post-projection Alpha1 Swin top:
//   P4 projection buffer -> pad -> p4_0,p4_1,p4_2,p4_3 -> crop
//   P3 projection buffer -> p3_0,p3_1
//
// Projection engines write the two input ports while their own computation is
// active. Assert p4_projection_ready/p3_projection_ready only after the final
// 16-lane projection beat has been written. A global start then executes P4
// fully before P3. Child datapaths are reset on abort.
// ============================================================================
module alpha1_swin_complete_top (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic abort,

    // P4 projection-to-Swin handoff, raster pixel [0..675], co tile [0..7].
    input  logic p4_projection_ready,
    input  logic p4_proj_wr_valid,
    input  logic [9:0] p4_proj_wr_pixel,
    input  logic [2:0] p4_proj_wr_co_tile,
    input  logic signed [127:0] p4_proj_wr_data,

    // P3 projection-to-Swin handoff, raster pixel [0..2703], co tile [0..7].
    input  logic p3_projection_ready,
    input  logic p3_proj_wr_valid,
    input  logic [11:0] p3_proj_wr_pixel,
    input  logic [2:0] p3_proj_wr_co_tile,
    input  logic signed [127:0] p3_proj_wr_data,

    // Cropped P4 Swin output for the FPN: 26x26x128.
    input  logic p4_out_rd_en,
    input  logic [9:0] p4_out_rd_pixel,
    input  logic [2:0] p4_out_rd_co_tile,
    output logic p4_out_rd_valid,
    output logic signed [127:0] p4_out_rd_data,

    // P3 Swin output for the FPN: 52x52x128.
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

    // Abort is a hard cancellation of in-flight computation. Projection input
    // memories may be rewritten once the master returns to IDLE.
    assign child_rst_n = rst_n & ~abort;

    alpha1_swin_p4_then_p3_controller u_ctrl (
        .clk,
        .rst_n,
        .start,
        .abort,
        .p4_projection_ready,
        .p3_projection_ready,
        .p4_swin_done,
        .p3_swin_done,
        .p4_swin_start(p4_start),
        .p3_swin_start(p3_start),
        .busy,
        .done,
        .aborted,
        .state_code
    );

    swin_p4_live_chain u_p4 (
        .clk,
        .rst_n(child_rst_n),
        .start(p4_start),
        .busy(p4_swin_busy),
        .done(p4_swin_done),
        .in_wr_valid(p4_proj_wr_valid),
        .in_wr_pixel(p4_proj_wr_pixel),
        .in_wr_co_tile(p4_proj_wr_co_tile),
        .in_wr_data(p4_proj_wr_data),
        .out_rd_en(p4_out_rd_en),
        .out_rd_pixel(p4_out_rd_pixel),
        .out_rd_co_tile(p4_out_rd_co_tile),
        .out_rd_valid(p4_out_rd_valid),
        .out_rd_data(p4_out_rd_data)
    );

    swin_p3_live_chain u_p3 (
        .clk,
        .rst_n(child_rst_n),
        .start(p3_start),
        .busy(p3_swin_busy),
        .done(p3_swin_done),
        .in_wr_valid(p3_proj_wr_valid),
        .in_wr_pixel(p3_proj_wr_pixel),
        .in_wr_co_tile(p3_proj_wr_co_tile),
        .in_wr_data(p3_proj_wr_data),
        .out_rd_en(p3_out_rd_en),
        .out_rd_pixel(p3_out_rd_pixel),
        .out_rd_co_tile(p3_out_rd_co_tile),
        .out_rd_valid(p3_out_rd_valid),
        .out_rd_data(p3_out_rd_data)
    );
endmodule
