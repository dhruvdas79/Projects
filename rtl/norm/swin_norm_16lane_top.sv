`timescale 1ns/1ps
// ============================================================================
// swin_norm_16lane_top.sv -- FAST stored-memory normalization wrapper
// ============================================================================
module swin_norm_16lane_top #(
    parameter int H=30,parameter int W=30,parameter int CHANNELS=128,
    parameter int LANES=16,parameter int DATA_W=8,parameter int PIXELS=H*W,
    parameter int CO_TILES=CHANNELS/LANES,
    parameter int PIXEL_ID_W=(PIXELS<=1)?1:$clog2(PIXELS),
    parameter int CO_TILE_W=(CO_TILES<=1)?1:$clog2(CO_TILES),
    parameter [8*256-1:0] BN_M_MEM="bn_M_i32.mem",
    parameter [8*256-1:0] BN_SHIFT_MEM="bn_shift_i16.mem",
    parameter [8*256-1:0] BN_BIAS_MEM="bn_bias_i32.mem",
    parameter [8*256-1:0] NORM_LUT00_MEM = "norm_lut_lane00_i8.mem",
    parameter [8*256-1:0] NORM_LUT01_MEM = "norm_lut_lane01_i8.mem",
    parameter [8*256-1:0] NORM_LUT02_MEM = "norm_lut_lane02_i8.mem",
    parameter [8*256-1:0] NORM_LUT03_MEM = "norm_lut_lane03_i8.mem",
    parameter [8*256-1:0] NORM_LUT04_MEM = "norm_lut_lane04_i8.mem",
    parameter [8*256-1:0] NORM_LUT05_MEM = "norm_lut_lane05_i8.mem",
    parameter [8*256-1:0] NORM_LUT06_MEM = "norm_lut_lane06_i8.mem",
    parameter [8*256-1:0] NORM_LUT07_MEM = "norm_lut_lane07_i8.mem",
    parameter [8*256-1:0] NORM_LUT08_MEM = "norm_lut_lane08_i8.mem",
    parameter [8*256-1:0] NORM_LUT09_MEM = "norm_lut_lane09_i8.mem",
    parameter [8*256-1:0] NORM_LUT10_MEM = "norm_lut_lane10_i8.mem",
    parameter [8*256-1:0] NORM_LUT11_MEM = "norm_lut_lane11_i8.mem",
    parameter [8*256-1:0] NORM_LUT12_MEM = "norm_lut_lane12_i8.mem",
    parameter [8*256-1:0] NORM_LUT13_MEM = "norm_lut_lane13_i8.mem",
    parameter [8*256-1:0] NORM_LUT14_MEM = "norm_lut_lane14_i8.mem",
    parameter [8*256-1:0] NORM_LUT15_MEM = "norm_lut_lane15_i8.mem"
)(
    input logic clk,input logic rst_n,input logic start,output logic done,
    output logic src_rd_en,output logic [PIXEL_ID_W-1:0] src_rd_pixel_id,
    output logic [CO_TILE_W-1:0] src_rd_co_tile,input logic src_rd_valid,
    input logic signed [LANES*DATA_W-1:0] src_rd_data,
    output logic dst_wr_valid,output logic [PIXEL_ID_W-1:0] dst_wr_pixel_id,
    output logic [CO_TILE_W-1:0] dst_wr_co_tile,
    output logic signed [LANES*DATA_W-1:0] dst_wr_data
);
    logic norm_in_valid; logic [PIXEL_ID_W-1:0] norm_in_pixel_id;
    logic [CO_TILE_W-1:0] norm_in_co_tile; logic signed [LANES*DATA_W-1:0] norm_in_data;
    logic norm_out_valid; logic [PIXEL_ID_W-1:0] norm_out_pixel_id;
    logic [CO_TILE_W-1:0] norm_out_co_tile; logic signed [LANES*DATA_W-1:0] norm_out_data;

    norm_affine_stream_controller_16lane #(
        .PIXELS(PIXELS),.CHANNELS(CHANNELS),.LANES(LANES),.DATA_W(DATA_W)
    ) u_controller (
        .clk,.rst_n,.start,.done,
        .src_rd_en,.src_rd_pixel_id,.src_rd_co_tile,.src_rd_valid,.src_rd_data,
        .norm_in_valid,.norm_in_pixel_id,.norm_in_co_tile,.norm_in_data,
        .norm_out_valid,.norm_out_pixel_id,.norm_out_co_tile,.norm_out_data,
        .dst_wr_valid,.dst_wr_pixel_id,.dst_wr_co_tile,.dst_wr_data
    );

    norm_affine_16lane #(
        .CHANNELS(CHANNELS),.LANES(LANES),.DATA_W(DATA_W),
        .PIXEL_ID_W(PIXEL_ID_W),.CO_TILE_W(CO_TILE_W),
        .BN_M_MEM(BN_M_MEM),.BN_SHIFT_MEM(BN_SHIFT_MEM),.BN_BIAS_MEM(BN_BIAS_MEM),
        .NORM_LUT00_MEM(NORM_LUT00_MEM),
        .NORM_LUT01_MEM(NORM_LUT01_MEM),
        .NORM_LUT02_MEM(NORM_LUT02_MEM),
        .NORM_LUT03_MEM(NORM_LUT03_MEM),
        .NORM_LUT04_MEM(NORM_LUT04_MEM),
        .NORM_LUT05_MEM(NORM_LUT05_MEM),
        .NORM_LUT06_MEM(NORM_LUT06_MEM),
        .NORM_LUT07_MEM(NORM_LUT07_MEM),
        .NORM_LUT08_MEM(NORM_LUT08_MEM),
        .NORM_LUT09_MEM(NORM_LUT09_MEM),
        .NORM_LUT10_MEM(NORM_LUT10_MEM),
        .NORM_LUT11_MEM(NORM_LUT11_MEM),
        .NORM_LUT12_MEM(NORM_LUT12_MEM),
        .NORM_LUT13_MEM(NORM_LUT13_MEM),
        .NORM_LUT14_MEM(NORM_LUT14_MEM),
        .NORM_LUT15_MEM(NORM_LUT15_MEM)
    ) u_norm (
        .clk,.rst_n,.in_valid(norm_in_valid),.in_pixel_id(norm_in_pixel_id),
        .in_co_tile(norm_in_co_tile),.in_data(norm_in_data),
        .out_valid(norm_out_valid),.out_pixel_id(norm_out_pixel_id),
        .out_co_tile(norm_out_co_tile),.out_data(norm_out_data)
    );
endmodule
