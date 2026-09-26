`timescale 1ns/1ps
// Alpha1 Swin front-end integration top.
// P4 accepts 26x26 projected P4 and pads/crops internally.
// P3 accepts 52x52 projected P3 (no physical pad needed).
// Start each stage after fully writing its input feature map.
module alpha1_swin_dual_live_top(
  input logic clk,input logic rst_n,
  input logic p4_start,output logic p4_busy,output logic p4_done,
  input logic p4_in_wr_valid,input logic [9:0] p4_in_wr_pixel,input logic [2:0] p4_in_wr_co_tile,input logic signed [127:0] p4_in_wr_data,
  input logic p4_out_rd_en,input logic [9:0] p4_out_rd_pixel,input logic [2:0] p4_out_rd_co_tile,output logic p4_out_rd_valid,output logic signed [127:0] p4_out_rd_data,
  input logic p3_start,output logic p3_busy,output logic p3_done,
  input logic p3_in_wr_valid,input logic [11:0] p3_in_wr_pixel,input logic [2:0] p3_in_wr_co_tile,input logic signed [127:0] p3_in_wr_data,
  input logic p3_out_rd_en,input logic [11:0] p3_out_rd_pixel,input logic [2:0] p3_out_rd_co_tile,output logic p3_out_rd_valid,output logic signed [127:0] p3_out_rd_data
);
  swin_p4_live_chain p4(.clk,.rst_n,.start(p4_start),.busy(p4_busy),.done(p4_done),
    .in_wr_valid(p4_in_wr_valid),.in_wr_pixel(p4_in_wr_pixel),.in_wr_co_tile(p4_in_wr_co_tile),.in_wr_data(p4_in_wr_data),
    .out_rd_en(p4_out_rd_en),.out_rd_pixel(p4_out_rd_pixel),.out_rd_co_tile(p4_out_rd_co_tile),.out_rd_valid(p4_out_rd_valid),.out_rd_data(p4_out_rd_data));
  swin_p3_live_chain p3(.clk,.rst_n,.start(p3_start),.busy(p3_busy),.done(p3_done),
    .in_wr_valid(p3_in_wr_valid),.in_wr_pixel(p3_in_wr_pixel),.in_wr_co_tile(p3_in_wr_co_tile),.in_wr_data(p3_in_wr_data),
    .out_rd_en(p3_out_rd_en),.out_rd_pixel(p3_out_rd_pixel),.out_rd_co_tile(p3_out_rd_co_tile),.out_rd_valid(p3_out_rd_valid),.out_rd_data(p3_out_rd_data));
endmodule
