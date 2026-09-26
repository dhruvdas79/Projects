`timescale 1ns/1ps
// ============================================================================
// V6.2 cyclic-shift/window-partition streamer for synchronous source RAM.
// Requests are issued at II=1 when the downstream is ready. A one-entry output
// register absorbs the fixed one-cycle RAM response and supports backpressure.
// ============================================================================
(* use_dsp = "no" *)
module swin_window_partition_mem16 #(
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
  parameter int TOK_W = (TOKENS <= 1) ? 1 : $clog2(TOKENS)
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
  localparam int WPR = W/WS;
  localparam int HPR = H/WS;

  typedef enum logic [1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_DONE} state_t;
  state_t state_q;

  logic [$clog2(HPR)-1:0] win_row_q;
  logic [$clog2(WPR)-1:0] win_col_q;
  logic [$clog2(WS)-1:0] tok_row_q;
  logic [$clog2(WS)-1:0] tok_col_q;
  logic [CO_W-1:0] co_tile_q;

  logic req_meta_valid_q;
  logic [WIN_W-1:0] req_window_q;
  logic [TOK_W-1:0] req_token_q;
  logic [CO_W-1:0] req_co_q;

  logic out_valid_q;
  logic [WIN_W-1:0] out_window_q;
  logic [TOK_W-1:0] out_token_q;
  logic [CO_W-1:0] out_co_q;
  logic signed [LANES*DATA_W-1:0] out_data_q;

  logic issue_fire;
  logic response_fire;
  logic last_issue;
  logic last_output;
  integer src_y;
  integer src_x;
  integer src_pixel;

  always_comb begin
    src_y = $unsigned(win_row_q)*WS + $unsigned(tok_row_q) + SHIFT_Y;
    if (src_y >= H) src_y = src_y - H;
    src_x = $unsigned(win_col_q)*WS + $unsigned(tok_col_q) + SHIFT_X;
    if (src_x >= W) src_x = src_x - W;
    src_pixel = src_y*W + src_x;

    // A request may be launched when the output register is empty or is being
    // consumed in this cycle. This sustains II=1 for the always-ready top use.
    issue_fire = (state_q == S_ISSUE) && (!out_valid_q || out_ready);
    response_fire = req_meta_valid_q && src_rd_valid;
    last_issue = (win_row_q == HPR-1) && (win_col_q == WPR-1) &&
                 (tok_row_q == WS-1) && (tok_col_q == WS-1) &&
                 (co_tile_q == CO_TILES-1);
    last_output = out_valid_q && out_ready &&
                  (out_window_q == NUM_WINDOWS-1) &&
                  (out_token_q == TOKENS-1) &&
                  (out_co_q == CO_TILES-1);

    src_rd_en = issue_fire;
    src_rd_pixel_id = PIX_W'(src_pixel);
    src_rd_co_tile = co_tile_q;

    out_valid = out_valid_q;
    out_window_id = out_window_q;
    out_token_id = out_token_q;
    out_co_tile = out_co_q;
    out_data = out_data_q;
    busy = (state_q != S_IDLE) && (state_q != S_DONE);
    done = (state_q == S_DONE);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      win_row_q <= '0; win_col_q <= '0; tok_row_q <= '0; tok_col_q <= '0; co_tile_q <= '0;
      req_meta_valid_q <= 1'b0;
      req_window_q <= '0; req_token_q <= '0; req_co_q <= '0;
      out_valid_q <= 1'b0;
      out_window_q <= '0; out_token_q <= '0; out_co_q <= '0; out_data_q <= '0;
    end else begin
      req_meta_valid_q <= issue_fire;
      if (issue_fire) begin
        req_window_q <= WIN_W'($unsigned(win_row_q)*WPR + $unsigned(win_col_q));
        req_token_q <= TOK_W'($unsigned(tok_row_q)*WS + $unsigned(tok_col_q));
        req_co_q <= co_tile_q;
      end

      // Consume current output; a simultaneous response refills the register.
      if (out_valid_q && out_ready) out_valid_q <= 1'b0;
      if (response_fire) begin
        out_valid_q <= 1'b1;
        out_window_q <= req_window_q;
        out_token_q <= req_token_q;
        out_co_q <= req_co_q;
        out_data_q <= src_rd_data;
      end

      case (state_q)
        S_IDLE: begin
          req_meta_valid_q <= 1'b0;
          out_valid_q <= 1'b0;
          if (start) begin
            win_row_q <= '0; win_col_q <= '0; tok_row_q <= '0; tok_col_q <= '0; co_tile_q <= '0;
            state_q <= S_ISSUE;
          end
        end

        S_ISSUE: if (issue_fire) begin
          if (last_issue) begin
            state_q <= S_DRAIN;
          end else if (co_tile_q == CO_TILES-1) begin
            co_tile_q <= '0;
            if (tok_col_q == WS-1) begin
              tok_col_q <= '0;
              if (tok_row_q == WS-1) begin
                tok_row_q <= '0;
                if (win_col_q == WPR-1) begin
                  win_col_q <= '0;
                  win_row_q <= win_row_q + 1'b1;
                end else win_col_q <= win_col_q + 1'b1;
              end else tok_row_q <= tok_row_q + 1'b1;
            end else tok_col_q <= tok_col_q + 1'b1;
          end else co_tile_q <= co_tile_q + 1'b1;
        end

        S_DRAIN: if (last_output) state_q <= S_DONE;
        S_DONE: state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && (src_rd_valid !== req_meta_valid_q))
      $fatal(1,"window partition source RAM violated one-cycle read contract");
    if (rst_n && response_fire && out_valid_q && !out_ready)
      $fatal(1,"window partition output-buffer overflow");
  end
`endif
endmodule
