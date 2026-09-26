`timescale 1ns/1ps
// ============================================================================
// V6.2 fused Norm1 + cyclic shift + window partition.
//
// X is read directly in shifted window order, normalized by the exact 16-bank
// INT8 LUT, and written to WIN1. This removes the complete N1 frame memory and
// the second full-frame partition read traversal.
// ============================================================================
(* use_dsp = "no" *)
module swin_norm_window_partition_fused16 #(
  parameter int H=30,
  parameter int W=30,
  parameter int CHANNELS=128,
  parameter int LANES=16,
  parameter int DATA_W=8,
  parameter int WS=5,
  parameter int SHIFT_Y=0,
  parameter int SHIFT_X=0,
  parameter int CO_TILES=CHANNELS/LANES,
  parameter int NUM_WINDOWS=(H/WS)*(W/WS),
  parameter int TOKENS=WS*WS,
  parameter int PIXELS=H*W,
  parameter int PIX_W=(PIXELS<=1)?1:$clog2(PIXELS),
  parameter int CO_W=(CO_TILES<=1)?1:$clog2(CO_TILES),
  parameter int WIN_W=(NUM_WINDOWS<=1)?1:$clog2(NUM_WINDOWS),
  parameter int TOK_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter [8*256-1:0] BN_M_MEM="bn_M_i32.mem",
  parameter [8*256-1:0] BN_SHIFT_MEM="bn_shift_i16.mem",
  parameter [8*256-1:0] BN_BIAS_MEM="bn_bias_i32.mem",
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
  input logic clk,
  input logic rst_n,
  input logic start,
  output logic busy,
  output logic done,

  output logic src_rd_en,
  output logic [PIX_W-1:0] src_rd_pixel_id,
  output logic [CO_W-1:0] src_rd_co_tile,
  input logic src_rd_valid,
  input logic signed [LANES*DATA_W-1:0] src_rd_data,

  output logic out_valid,
  input logic out_ready,
  output logic [WIN_W-1:0] out_window_id,
  output logic [TOK_W-1:0] out_token_id,
  output logic [CO_W-1:0] out_co_tile,
  output logic signed [LANES*DATA_W-1:0] out_data
);
  localparam int WPR=W/WS;
  localparam int HPR=H/WS;

  typedef enum logic [1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_DONE} st_t;
  st_t st_q;
  logic [$clog2(HPR)-1:0] win_row_q;
  logic [$clog2(WPR)-1:0] win_col_q;
  logic [$clog2(WS)-1:0] tok_row_q;
  logic [$clog2(WS)-1:0] tok_col_q;
  logic [CO_W-1:0] co_q;

  logic req_valid_q;
  logic [WIN_W-1:0] req_win_q;
  logic [TOK_W-1:0] req_tok_q;
  logic [CO_W-1:0] req_co_q;

  logic norm_in_valid;
  logic norm_out_valid;
  logic signed [LANES*DATA_W-1:0] norm_out_data;
  logic [PIX_W-1:0] unused_norm_pixel;
  logic [CO_W-1:0] unused_norm_co;
  logic norm_meta_valid_q;
  logic [WIN_W-1:0] norm_win_q;
  logic [TOK_W-1:0] norm_tok_q;
  logic [CO_W-1:0] norm_co_q;

  logic issue_fire;
  logic last_issue;
  logic last_output;
  integer src_y,src_x,src_pixel;

  always_comb begin
    src_y=$unsigned(win_row_q)*WS+$unsigned(tok_row_q)+SHIFT_Y;
    if(src_y>=H) src_y=src_y-H;
    src_x=$unsigned(win_col_q)*WS+$unsigned(tok_col_q)+SHIFT_X;
    if(src_x>=W) src_x=src_x-W;
    src_pixel=src_y*W+src_x;

    // The only active integration ties out_ready high. Gating request issue by
    // it keeps the interface safe if the consumer is paused before a request.
    issue_fire=(st_q==S_ISSUE)&&out_ready;
    last_issue=(win_row_q==HPR-1)&&(win_col_q==WPR-1)&&
               (tok_row_q==WS-1)&&(tok_col_q==WS-1)&&(co_q==CO_TILES-1);
    last_output=norm_out_valid&&norm_meta_valid_q&&
                (norm_win_q==NUM_WINDOWS-1)&&(norm_tok_q==TOKENS-1)&&
                (norm_co_q==CO_TILES-1)&&out_ready;

    src_rd_en=issue_fire;
    src_rd_pixel_id=PIX_W'(src_pixel);
    src_rd_co_tile=co_q;
    norm_in_valid=req_valid_q&&src_rd_valid;

    out_valid=norm_out_valid&&norm_meta_valid_q;
    out_window_id=norm_win_q;
    out_token_id=norm_tok_q;
    out_co_tile=norm_co_q;
    out_data=norm_out_data;
    busy=(st_q!=S_IDLE)&&(st_q!=S_DONE);
    done=(st_q==S_DONE);
  end

  norm_affine_16lane #(
    .CHANNELS(CHANNELS),.LANES(LANES),.DATA_W(DATA_W),
    .PIXEL_ID_W(PIX_W),.CO_TILE_W(CO_W),
    .BN_M_MEM(BN_M_MEM),.BN_SHIFT_MEM(BN_SHIFT_MEM),.BN_BIAS_MEM(BN_BIAS_MEM),
    .NORM_LUT00_MEM(NORM_LUT00_MEM),.NORM_LUT01_MEM(NORM_LUT01_MEM),
    .NORM_LUT02_MEM(NORM_LUT02_MEM),.NORM_LUT03_MEM(NORM_LUT03_MEM),
    .NORM_LUT04_MEM(NORM_LUT04_MEM),.NORM_LUT05_MEM(NORM_LUT05_MEM),
    .NORM_LUT06_MEM(NORM_LUT06_MEM),.NORM_LUT07_MEM(NORM_LUT07_MEM),
    .NORM_LUT08_MEM(NORM_LUT08_MEM),.NORM_LUT09_MEM(NORM_LUT09_MEM),
    .NORM_LUT10_MEM(NORM_LUT10_MEM),.NORM_LUT11_MEM(NORM_LUT11_MEM),
    .NORM_LUT12_MEM(NORM_LUT12_MEM),.NORM_LUT13_MEM(NORM_LUT13_MEM),
    .NORM_LUT14_MEM(NORM_LUT14_MEM),.NORM_LUT15_MEM(NORM_LUT15_MEM)
  ) u_norm1_lut(
    .clk,.rst_n,.in_valid(norm_in_valid),.in_pixel_id('0),.in_co_tile(req_co_q),
    .in_data(src_rd_data),.out_valid(norm_out_valid),
    .out_pixel_id(unused_norm_pixel),.out_co_tile(unused_norm_co),.out_data(norm_out_data)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      st_q<=S_IDLE;win_row_q<='0;win_col_q<='0;tok_row_q<='0;tok_col_q<='0;co_q<='0;
      req_valid_q<=1'b0;req_win_q<='0;req_tok_q<='0;req_co_q<='0;
      norm_meta_valid_q<=1'b0;norm_win_q<='0;norm_tok_q<='0;norm_co_q<='0;
    end else begin
      req_valid_q<=issue_fire;
      if(issue_fire) begin
        req_win_q<=WIN_W'($unsigned(win_row_q)*WPR+$unsigned(win_col_q));
        req_tok_q<=TOK_W'($unsigned(tok_row_q)*WS+$unsigned(tok_col_q));
        req_co_q<=co_q;
      end

      norm_meta_valid_q<=norm_in_valid;
      if(norm_in_valid) begin
        norm_win_q<=req_win_q;
        norm_tok_q<=req_tok_q;
        norm_co_q<=req_co_q;
      end

      case(st_q)
        S_IDLE: begin
          req_valid_q<=1'b0;norm_meta_valid_q<=1'b0;
          if(start) begin
            win_row_q<='0;win_col_q<='0;tok_row_q<='0;tok_col_q<='0;co_q<='0;
            st_q<=S_ISSUE;
          end
        end
        S_ISSUE: if(issue_fire) begin
          if(last_issue) st_q<=S_DRAIN;
          else if(co_q==CO_TILES-1) begin
            co_q<='0;
            if(tok_col_q==WS-1) begin
              tok_col_q<='0;
              if(tok_row_q==WS-1) begin
                tok_row_q<='0;
                if(win_col_q==WPR-1) begin win_col_q<='0;win_row_q<=win_row_q+1'b1;end
                else win_col_q<=win_col_q+1'b1;
              end else tok_row_q<=tok_row_q+1'b1;
            end else tok_col_q<=tok_col_q+1'b1;
          end else co_q<=co_q+1'b1;
        end
        S_DRAIN: if(last_output) st_q<=S_DONE;
        S_DONE: st_q<=S_IDLE;
        default: st_q<=S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(rst_n && !out_ready && ((st_q==S_ISSUE)||out_valid))
      $fatal(1,"fused Norm1/partition integration requires out_ready=1");
    if(rst_n && (src_rd_valid!==req_valid_q))
      $fatal(1,"fused Norm1/partition XMEM violated one-cycle read contract");
  end
`endif
endmodule
