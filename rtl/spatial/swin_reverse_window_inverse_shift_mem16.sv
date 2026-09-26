`timescale 1ns/1ps
// Fused reverse-window + inverse cyclic shift.
// Writes directly into the destination tensor memory. This is the corrected
// replacement for the partner reverse module: no 6-bit emit_pixel counter,
// no permanent DONE lock, and no frame-private duplication.
(* use_dsp = "no" *)
module swin_reverse_window_inverse_shift_mem16 #(
  parameter int H = 30,
  parameter int W = 30,
  parameter int CHANNELS = 128,
  parameter int LANES = 16,
  parameter int DATA_W = 8,
  parameter int WS = 5,
  parameter int SHIFT_Y = 0,
  parameter int SHIFT_X = 0,
  parameter int CO_TILES = CHANNELS/LANES,
  parameter int NUM_WINDOWS = (H/WS)*(W/WS),
  parameter int TOKENS = WS*WS,
  parameter int PIXELS = H*W,
  parameter int PIX_W = (PIXELS <= 1) ? 1 : $clog2(PIXELS),
  parameter int CO_W = (CO_TILES <= 1) ? 1 : $clog2(CO_TILES),
  parameter int WIN_W = (NUM_WINDOWS <= 1) ? 1 : $clog2(NUM_WINDOWS),
  parameter int TOK_W = (TOKENS <= 1) ? 1 : $clog2(TOKENS),
  parameter int TOTAL_BEATS = NUM_WINDOWS*TOKENS*CO_TILES,
  parameter int CNT_W = (TOTAL_BEATS <= 1) ? 1 : $clog2(TOTAL_BEATS+1)
)(
  input logic clk,
  input logic rst_n,
  input logic start,
  output logic busy,
  output logic done,
  input logic in_valid,
  output logic in_ready,
  input logic [WIN_W-1:0] in_window_id,
  input logic [TOK_W-1:0] in_token_id,
  input logic [CO_W-1:0] in_co_tile,
  input logic signed [LANES*DATA_W-1:0] in_data,
  output logic dst_wr_valid,
  output logic [PIX_W-1:0] dst_wr_pixel_id,
  output logic [CO_W-1:0] dst_wr_co_tile,
  output logic signed [LANES*DATA_W-1:0] dst_wr_data
);
  localparam int WPR = W/WS;
  logic active;
  logic [CNT_W-1:0] beat_count;
  int win_row, win_col, tok_row, tok_col;
  int shifted_y, shifted_x, final_y, final_x, final_pixel;

  always_comb begin
    // Small comparator/subtract decode; avoids generic divider/modulo hardware.
    win_row = 0; win_col = in_window_id;
    for (int r=0; r<(H/WS); r++) begin
      if (in_window_id >= r*WPR) begin win_row=r; win_col=in_window_id-r*WPR; end
    end
    tok_row = 0; tok_col = in_token_id;
    for (int r=0; r<WS; r++) begin
      if (in_token_id >= r*WS) begin tok_row=r; tok_col=in_token_id-r*WS; end
    end
    shifted_y = win_row*WS + tok_row;
    shifted_x = win_col*WS + tok_col;
    final_y = shifted_y + SHIFT_Y;
    if (final_y >= H) final_y = final_y - H;
    final_x = shifted_x + SHIFT_X;
    if (final_x >= W) final_x = final_x - W;
    final_pixel = final_y*W + final_x;
    in_ready = active;
    dst_wr_valid = active && in_valid && in_ready;
    dst_wr_pixel_id = final_pixel[PIX_W-1:0];
    dst_wr_co_tile = in_co_tile;
    dst_wr_data = in_data;
    busy = active;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin active<=0; done<=0; beat_count<='0; end
    else begin
      done<=0;
      if(start && !active) begin active<=1; beat_count<='0; end
      else if(active && in_valid && in_ready) begin
        if(beat_count == TOTAL_BEATS-1) begin active<=0; done<=1; end
        else beat_count<=beat_count+1'b1;
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(rst_n && active && in_valid && in_ready) begin
      if(in_window_id >= NUM_WINDOWS) $fatal(1,"reverse: window_id out of range");
      if(in_token_id >= TOKENS) $fatal(1,"reverse: token_id out of range");
      if(in_co_tile >= CO_TILES) $fatal(1,"reverse: co_tile out of range");
    end
  end
`endif
endmodule
