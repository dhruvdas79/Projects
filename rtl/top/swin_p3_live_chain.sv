`timescale 1ns/1ps
// Complete two-block P3 Swin chain: p3_0 (no shift) -> p3_1 (shift=2).
// The caller writes the 52x52 projected P3 tensor before asserting start.
module swin_p3_live_chain(
  input logic clk,input logic rst_n,input logic start,
  output logic busy,output logic done,
  input logic in_wr_valid,input logic [11:0] in_wr_pixel,
  input logic [2:0] in_wr_co_tile,input logic signed [127:0] in_wr_data,
  input logic out_rd_en,input logic [11:0] out_rd_pixel,
  input logic [2:0] out_rd_co_tile,output logic out_rd_valid,
  output logic signed [127:0] out_rd_data
);
  logic b0_start,b0_busy,b0_done,b1_start,b1_busy,b1_done;
  logic b0y_re; logic [11:0] b0y_pix; logic [2:0] b0y_co; logic b0y_rv; logic signed [127:0] b0y_data;
  logic b1x_wv; logic [11:0] b1x_pix; logic [2:0] b1x_co; logic signed [127:0] b1x_data;
  logic br_start,br_busy,br_done;

  swin_p3_0_live_block b0(
    .clk,.rst_n,.start(b0_start),.busy(b0_busy),.done(b0_done),
    .x_wr_valid(in_wr_valid),.x_wr_pixel(in_wr_pixel),.x_wr_co_tile(in_wr_co_tile),.x_wr_data(in_wr_data),
    .y_rd_en(b0y_re),.y_rd_pixel(b0y_pix),.y_rd_co_tile(b0y_co),.y_rd_valid(b0y_rv),.y_rd_data(b0y_data)
  );
  swin_tensor_bridge16 #(.TOKENS(2704),.CHANNELS(128)) bridge0(
    .clk,.rst_n,.start(br_start),.busy(br_busy),.done(br_done),
    .src_rd_en(b0y_re),.src_rd_token(b0y_pix),.src_rd_co(b0y_co),.src_rd_valid(b0y_rv),.src_rd_data(b0y_data),
    .dst_wr_valid(b1x_wv),.dst_wr_token(b1x_pix),.dst_wr_co(b1x_co),.dst_wr_data(b1x_data)
  );
  swin_p3_1_live_block b1(
    .clk,.rst_n,.start(b1_start),.busy(b1_busy),.done(b1_done),
    .x_wr_valid(b1x_wv),.x_wr_pixel(b1x_pix),.x_wr_co_tile(b1x_co),.x_wr_data(b1x_data),
    .y_rd_en(out_rd_en),.y_rd_pixel(out_rd_pixel),.y_rd_co_tile(out_rd_co_tile),.y_rd_valid(out_rd_valid),.y_rd_data(out_rd_data)
  );

  typedef enum logic[3:0]{I,B0L,B0W,BRL,BRW,B1L,B1W,F} st_t;
  st_t st;
  always_comb begin
    b0_start=1'b0; br_start=1'b0; b1_start=1'b0;
    busy=(st!=I && st!=F); done=(st==F);
    case(st)
      B0L: b0_start=1'b1;
      BRL: br_start=1'b1;
      B1L: b1_start=1'b1;
      default: ;
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) st<=I;
    else case(st)
      I: if(start) st<=B0L;
      B0L: st<=B0W;
      B0W: if(b0_done) st<=BRL;
      BRL: st<=BRW;
      BRW: if(br_done) st<=B1L;
      B1L: st<=B1W;
      B1W: if(b1_done) st<=F;
      F: if(!start) st<=I;
      default: st<=I;
    endcase
  end
endmodule
