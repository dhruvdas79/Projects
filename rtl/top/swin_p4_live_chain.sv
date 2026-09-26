`timescale 1ns/1ps
// Complete P4 Swin chain:
// projected 26x26 -> pad right/bottom to 30x30 -> p4_0 -> p4_1 -> p4_2 -> p4_3
// -> crop top-left 26x26. Every block performs real live arithmetic.
module swin_p4_live_chain(
  input logic clk,input logic rst_n,input logic start,
  output logic busy,output logic done,
  input logic in_wr_valid,input logic [9:0] in_wr_pixel,
  input logic [2:0] in_wr_co_tile,input logic signed [127:0] in_wr_data,
  input logic out_rd_en,input logic [9:0] out_rd_pixel,
  input logic [2:0] out_rd_co_tile,output logic out_rd_valid,
  output logic signed [127:0] out_rd_data
);
  // Input P4 projection memory and final cropped P4 output memory.
  logic pin_re,pin_rv; logic[9:0]pin_pix; logic[2:0]pin_co; logic signed[127:0]pin_data;
  logic pout_wv,pout_rv; logic[9:0]pout_wp,pout_rp; logic[2:0]pout_wc,pout_rc; logic signed[127:0]pout_wd,pout_rd;
  swin_tensor_mem16 #(.TOKENS(676),.CHANNELS(128)) P4IN(
    .clk,.wr_valid(in_wr_valid),.wr_token_id(in_wr_pixel),.wr_co_tile(in_wr_co_tile),.wr_data(in_wr_data),
    .rd_en(pin_re),.rd_token_id(pin_pix),.rd_co_tile(pin_co),.rd_valid(pin_rv),.rd_data(pin_data));
  swin_tensor_mem16 #(.TOKENS(676),.CHANNELS(128)) P4OUT(
    .clk,.wr_valid(pout_wv),.wr_token_id(pout_wp),.wr_co_tile(pout_wc),.wr_data(pout_wd),
    .rd_en(out_rd_en),.rd_token_id(out_rd_pixel),.rd_co_tile(out_rd_co_tile),.rd_valid(out_rd_valid),.rd_data(out_rd_data));

  logic pad_start,pad_done; logic p40x_wv;logic[9:0]p40x_pix;logic[2:0]p40x_co;logic signed[127:0]p40x_data;
  swin_pad_raster_mem16 #(.IN_H(26),.IN_W(26),.OUT_H(30),.OUT_W(30),.CHANNELS(128)) PAD(
    .clk,.rst_n,.start(pad_start),.busy(),.done(pad_done),
    .src_rd_en(pin_re),.src_rd_pixel_id(pin_pix),.src_rd_co_tile(pin_co),.src_rd_valid(pin_rv),.src_rd_data(pin_data),
    .dst_wr_valid(p40x_wv),.dst_wr_pixel_id(p40x_pix),.dst_wr_co_tile(p40x_co),.dst_wr_data(p40x_data));

  logic s0,s1,s2,s3,d0,d1,d2,d3;
  logic b01_start,b12_start,b23_start,b01_done,b12_done,b23_done;
  // block0 output -> bridge 01
  logic y0re,y1re,y2re,y3re; logic[9:0]y0pix,y1pix,y2pix,y3pix;logic[2:0]y0co,y1co,y2co,y3co; logic y0rv,y1rv,y2rv,y3rv;logic signed[127:0]y0data,y1data,y2data,y3data;
  logic x1wv,x2wv,x3wv;logic[9:0]x1pix,x2pix,x3pix;logic[2:0]x1co,x2co,x3co;logic signed[127:0]x1data,x2data,x3data;

  swin_p4_0_live_block b0(.clk,.rst_n,.start(s0),.busy(),.done(d0),.x_wr_valid(p40x_wv),.x_wr_pixel(p40x_pix),.x_wr_co_tile(p40x_co),.x_wr_data(p40x_data),.y_rd_en(y0re),.y_rd_pixel(y0pix),.y_rd_co_tile(y0co),.y_rd_valid(y0rv),.y_rd_data(y0data));
  swin_tensor_bridge16 #(.TOKENS(900),.CHANNELS(128)) B01(.clk,.rst_n,.start(b01_start),.busy(),.done(b01_done),.src_rd_en(y0re),.src_rd_token(y0pix),.src_rd_co(y0co),.src_rd_valid(y0rv),.src_rd_data(y0data),.dst_wr_valid(x1wv),.dst_wr_token(x1pix),.dst_wr_co(x1co),.dst_wr_data(x1data));
  swin_p4_1_live_block b1(.clk,.rst_n,.start(s1),.busy(),.done(d1),.x_wr_valid(x1wv),.x_wr_pixel(x1pix),.x_wr_co_tile(x1co),.x_wr_data(x1data),.y_rd_en(y1re),.y_rd_pixel(y1pix),.y_rd_co_tile(y1co),.y_rd_valid(y1rv),.y_rd_data(y1data));
  swin_tensor_bridge16 #(.TOKENS(900),.CHANNELS(128)) B12(.clk,.rst_n,.start(b12_start),.busy(),.done(b12_done),.src_rd_en(y1re),.src_rd_token(y1pix),.src_rd_co(y1co),.src_rd_valid(y1rv),.src_rd_data(y1data),.dst_wr_valid(x2wv),.dst_wr_token(x2pix),.dst_wr_co(x2co),.dst_wr_data(x2data));
  swin_p4_2_live_block b2(.clk,.rst_n,.start(s2),.busy(),.done(d2),.x_wr_valid(x2wv),.x_wr_pixel(x2pix),.x_wr_co_tile(x2co),.x_wr_data(x2data),.y_rd_en(y2re),.y_rd_pixel(y2pix),.y_rd_co_tile(y2co),.y_rd_valid(y2rv),.y_rd_data(y2data));
  swin_tensor_bridge16 #(.TOKENS(900),.CHANNELS(128)) B23(.clk,.rst_n,.start(b23_start),.busy(),.done(b23_done),.src_rd_en(y2re),.src_rd_token(y2pix),.src_rd_co(y2co),.src_rd_valid(y2rv),.src_rd_data(y2data),.dst_wr_valid(x3wv),.dst_wr_token(x3pix),.dst_wr_co(x3co),.dst_wr_data(x3data));
  swin_p4_3_live_block b3(.clk,.rst_n,.start(s3),.busy(),.done(d3),.x_wr_valid(x3wv),.x_wr_pixel(x3pix),.x_wr_co_tile(x3co),.x_wr_data(x3data),.y_rd_en(y3re),.y_rd_pixel(y3pix),.y_rd_co_tile(y3co),.y_rd_valid(y3rv),.y_rd_data(y3data));

  logic crop_start,crop_done;
  swin_crop_raster_mem16 #(.IN_H(30),.IN_W(30),.OUT_H(26),.OUT_W(26),.CHANNELS(128)) CROP(
    .clk,.rst_n,.start(crop_start),.busy(),.done(crop_done),
    .src_rd_en(y3re),.src_rd_pixel_id(y3pix),.src_rd_co_tile(y3co),.src_rd_valid(y3rv),.src_rd_data(y3data),
    .dst_wr_valid(pout_wv),.dst_wr_pixel_id(pout_wp),.dst_wr_co_tile(pout_wc),.dst_wr_data(pout_wd));

  typedef enum logic[4:0]{I,PL,PW,S0L,S0W,B01L,B01W,S1L,S1W,B12L,B12W,S2L,S2W,B23L,B23W,S3L,S3W,CL,CW,F} st_t;
  st_t st;
  always_comb begin
    pad_start=0;s0=0;b01_start=0;s1=0;b12_start=0;s2=0;b23_start=0;s3=0;crop_start=0;
    busy=(st!=I && st!=F);done=(st==F);
    case(st)
      PL:pad_start=1; S0L:s0=1; B01L:b01_start=1; S1L:s1=1; B12L:b12_start=1;
      S2L:s2=1; B23L:b23_start=1; S3L:s3=1; CL:crop_start=1;
      default:;
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) st<=I; else case(st)
      I:if(start)st<=PL; PL:st<=PW; PW:if(pad_done)st<=S0L; S0L:st<=S0W; S0W:if(d0)st<=B01L;
      B01L:st<=B01W;B01W:if(b01_done)st<=S1L; S1L:st<=S1W;S1W:if(d1)st<=B12L;
      B12L:st<=B12W;B12W:if(b12_done)st<=S2L; S2L:st<=S2W;S2W:if(d2)st<=B23L;
      B23L:st<=B23W;B23W:if(b23_done)st<=S3L; S3L:st<=S3W;S3W:if(d3)st<=CL;
      CL:st<=CW;CW:if(crop_done)st<=F;F:if(!start)st<=I;default:st<=I;
    endcase
  end
endmodule
