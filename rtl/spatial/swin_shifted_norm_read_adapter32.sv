`timescale 1ns/1ps
// ============================================================================
// On-demand Norm1 + cyclic-shift/window address adapter for QKV.
//
// QKV requests a flat window-major token. The adapter converts it to the source
// raster pixel, reads X through a synchronous 32-lane RAM port, and applies the
// exact Norm1 LUT. This eliminates both N1 and WIN1 full-frame memories.
// ============================================================================
(* use_dsp="no" *)
module swin_shifted_norm_read_adapter32 #(
  parameter int H=30,parameter int W=30,parameter int CHANNELS=128,
  parameter int WS=5,parameter int SHIFT=0,
  parameter int PIXELS=H*W,
  parameter int TOKEN_W=(PIXELS<=1)?1:$clog2(PIXELS),
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
  input logic req_en,input logic [TOKEN_W-1:0] req_flat_token,input logic [CO32_W-1:0] req_co_tile,
  output logic x_rd_en,output logic [TOKEN_W-1:0] x_rd_pixel,output logic [CO32_W-1:0] x_rd_co_tile,
  input logic x_rd_valid,input logic signed [255:0] x_rd_data,
  output logic out_valid,output logic [TOKEN_W-1:0] out_token,output logic [CO32_W-1:0] out_co_tile,
  output logic signed [255:0] out_data
);
  logic req_meta_valid_q;
  logic [TOKEN_W-1:0] req_token_q;
  logic [CO32_W-1:0] req_co_q;
  integer flat_i,win_i,tok_i,win_row_i,win_col_i,tok_row_i,tok_col_i;
  integer sy_i,sx_i,pixel_i;

  always_comb begin
    flat_i=$unsigned(req_flat_token);
    if(WS==5) begin
      win_i=(((flat_i<<5)+(flat_i<<3)+flat_i))>>10;
      tok_i=flat_i-((win_i<<4)+(win_i<<3)+win_i);
      win_row_i=(((win_i<<5)+(win_i<<3)+(win_i<<1)+win_i))>>8;
      win_col_i=win_i-((win_row_i<<2)+(win_row_i<<1));
      tok_row_i=(((tok_i<<3)+(tok_i<<2)+tok_i))>>6;
      tok_col_i=tok_i-((tok_row_i<<2)+tok_row_i);
    end else begin
      win_i=flat_i>>4;
      tok_i=flat_i&15;
      win_row_i=(((win_i<<11)+(win_i<<8)+(win_i<<7)+(win_i<<6)+(win_i<<4)+(win_i<<3)+win_i))>>15;
      win_col_i=win_i-((win_row_i<<3)+(win_row_i<<2)+win_row_i);
      tok_row_i=tok_i>>2;
      tok_col_i=tok_i&3;
    end
    sy_i=((WS==5)?((win_row_i<<2)+win_row_i):(win_row_i<<2))+tok_row_i+SHIFT;
    if(sy_i>=H) sy_i=sy_i-H;
    sx_i=((WS==5)?((win_col_i<<2)+win_col_i):(win_col_i<<2))+tok_col_i+SHIFT;
    if(sx_i>=W) sx_i=sx_i-W;
    if(W==52) pixel_i=((sy_i<<5)+(sy_i<<4)+(sy_i<<2))+sx_i;
    else      pixel_i=((sy_i<<4)+(sy_i<<3)+(sy_i<<2)+(sy_i<<1))+sx_i;
    x_rd_en=req_en;x_rd_pixel=TOKEN_W'(pixel_i);x_rd_co_tile=req_co_tile;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin req_meta_valid_q<=1'b0;req_token_q<='0;req_co_q<='0;end
    else begin
      req_meta_valid_q<=req_en;
      if(req_en) begin req_token_q<=req_flat_token;req_co_q<=req_co_tile;end
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
  ) u_norm1_ondemand(
    .clk,.rst_n,.in_valid(req_meta_valid_q&&x_rd_valid),.in_token(req_token_q),
    .in_co_tile(req_co_q),.in_data(x_rd_data),.out_valid,.out_token,.out_co_tile,.out_data
  );

`ifndef SYNTHESIS
  initial if(!((H==30&&W==30&&WS==5)||(H==52&&W==52&&WS==4)))
    $fatal(1,"shifted Norm adapter supports active P4/P3 geometries only");
  always_ff @(posedge clk) if(rst_n && (x_rd_valid!==req_meta_valid_q))
    $fatal(1,"shifted Norm1 adapter X RAM violated one-cycle read contract");
`endif
endmodule
