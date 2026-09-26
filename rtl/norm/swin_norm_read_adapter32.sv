`timescale 1ns/1ps
// Reads one 32-lane tensor vector from synchronous RAM and applies the exact
// Norm LUT in the following clock. Requests may be issued every cycle (II=1).
(* use_dsp="no" *)
module swin_norm_read_adapter32 #(
  parameter int TOKENS=900,
  parameter int CHANNELS=128,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CO32_W=((CHANNELS/32)<=1)?1:$clog2(CHANNELS/32),
  parameter [8*256-1:0] NORM_LUT00_MEM="norm_lut_lane00_i8.mem",
  parameter [8*256-1:0] NORM_LUT01_MEM="norm_lut_lane01_i8.mem",
  parameter [8*256-1:0] NORM_LUT02_MEM="norm_lut_lane02_i8.mem",
  parameter [8*256-1:0] NORM_LUT03_MEM="norm_lut_lane03_i8.mem",
  parameter [8*256-1:0] NORM_LUT04_MEM="norm_lut_lane04_i8.mem",
  parameter [8*256-1:0] NORM_LUT05_MEM="norm_lut_lane05_i8.mem",
  parameter [8*256-1:0] NORM_LUT06_MEM="norm_lut_lane06_i8.mem",
  parameter [8*256-1:0] NORM_LUT07_MEM="norm_lut_lane07_i8.mem",
  parameter [8*256-1:0] NORM_LUT08_MEM="norm_lut_lane08_i8.mem",
  parameter [8*256-1:0] NORM_LUT09_MEM="norm_lut_lane09_i8.mem",
  parameter [8*256-1:0] NORM_LUT10_MEM="norm_lut_lane10_i8.mem",
  parameter [8*256-1:0] NORM_LUT11_MEM="norm_lut_lane11_i8.mem",
  parameter [8*256-1:0] NORM_LUT12_MEM="norm_lut_lane12_i8.mem",
  parameter [8*256-1:0] NORM_LUT13_MEM="norm_lut_lane13_i8.mem",
  parameter [8*256-1:0] NORM_LUT14_MEM="norm_lut_lane14_i8.mem",
  parameter [8*256-1:0] NORM_LUT15_MEM="norm_lut_lane15_i8.mem"
)(
  input logic clk,input logic rst_n,
  input logic req_en,input logic [TOKEN_W-1:0] req_token,input logic [CO32_W-1:0] req_co_tile,
  output logic mem_rd_en,output logic [TOKEN_W-1:0] mem_rd_token,output logic [CO32_W-1:0] mem_rd_co_tile,
  input logic mem_rd_valid,input logic signed [255:0] mem_rd_data,
  output logic out_valid,output logic [TOKEN_W-1:0] out_token,output logic [CO32_W-1:0] out_co_tile,
  output logic signed [255:0] out_data
);
  logic req_meta_valid_q;
  logic [TOKEN_W-1:0] req_token_q;
  logic [CO32_W-1:0] req_co_q;

  assign mem_rd_en=req_en;
  assign mem_rd_token=req_token;
  assign mem_rd_co_tile=req_co_tile;

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin req_meta_valid_q<=1'b0;req_token_q<='0;req_co_q<='0;end
    else begin
      req_meta_valid_q<=req_en;
      if(req_en) begin req_token_q<=req_token;req_co_q<=req_co_tile;end
    end
  end

  norm_affine_32lane_dualport #(
    .CHANNELS(CHANNELS),.TOKEN_W(TOKEN_W),.CO32_W(CO32_W),
    .NORM_LUT00_MEM(NORM_LUT00_MEM),.NORM_LUT01_MEM(NORM_LUT01_MEM),
    .NORM_LUT02_MEM(NORM_LUT02_MEM),.NORM_LUT03_MEM(NORM_LUT03_MEM),
    .NORM_LUT04_MEM(NORM_LUT04_MEM),.NORM_LUT05_MEM(NORM_LUT05_MEM),
    .NORM_LUT06_MEM(NORM_LUT06_MEM),.NORM_LUT07_MEM(NORM_LUT07_MEM),
    .NORM_LUT08_MEM(NORM_LUT08_MEM),.NORM_LUT09_MEM(NORM_LUT09_MEM),
    .NORM_LUT10_MEM(NORM_LUT10_MEM),.NORM_LUT11_MEM(NORM_LUT11_MEM),
    .NORM_LUT12_MEM(NORM_LUT12_MEM),.NORM_LUT13_MEM(NORM_LUT13_MEM),
    .NORM_LUT14_MEM(NORM_LUT14_MEM),.NORM_LUT15_MEM(NORM_LUT15_MEM)
  ) u_norm32(
    .clk,.rst_n,.in_valid(req_meta_valid_q&&mem_rd_valid),.in_token(req_token_q),
    .in_co_tile(req_co_q),.in_data(mem_rd_data),.out_valid,.out_token,.out_co_tile,.out_data
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) if(rst_n && (mem_rd_valid!==req_meta_valid_q))
    $fatal(1,"norm-read adapter RAM violated one-cycle read contract");
`endif
endmodule
