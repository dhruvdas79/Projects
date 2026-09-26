`timescale 1ns/1ps
// ============================================================================
// V6.2 pipelined window-memory reader.
// One synchronous APWIN request is issued each clock when the one-entry output
// register is available. Request metadata is delayed one cycle to align with
// the registered bridge response.
// ============================================================================
module swin_window_reader_mem16 #(
  parameter int NUM_WINDOWS = 36,
  parameter int TOKENS = 25,
  parameter int CHANNELS = 128,
  parameter int LANES = 16,
  parameter int DATA_W = 8,
  parameter int CO_TILES = CHANNELS/LANES,
  parameter int WIN_W = (NUM_WINDOWS <= 1) ? 1 : $clog2(NUM_WINDOWS),
  parameter int TOK_W = (TOKENS <= 1) ? 1 : $clog2(TOKENS),
  parameter int CO_W = (CO_TILES <= 1) ? 1 : $clog2(CO_TILES)
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  output logic busy,
  output logic done,

  output logic mem_rd_en,
  output logic [WIN_W-1:0] mem_rd_window_id,
  output logic [TOK_W-1:0] mem_rd_token_id,
  output logic [CO_W-1:0] mem_rd_co_tile,
  input  logic mem_rd_valid,
  input  logic signed [LANES*DATA_W-1:0] mem_rd_data,

  output logic out_valid,
  input  logic out_ready,
  output logic [WIN_W-1:0] out_window_id,
  output logic [TOK_W-1:0] out_token_id,
  output logic [CO_W-1:0] out_co_tile,
  output logic signed [LANES*DATA_W-1:0] out_data
);
  typedef enum logic [1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_DONE} state_t;
  state_t state_q;

  logic [WIN_W-1:0] window_q;
  logic [TOK_W-1:0] token_q;
  logic [CO_W-1:0] co_q;

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

  always_comb begin
    issue_fire = (state_q == S_ISSUE) && (!out_valid_q || out_ready);
    response_fire = req_meta_valid_q && mem_rd_valid;
    last_issue = (window_q == NUM_WINDOWS-1) &&
                 (token_q == TOKENS-1) &&
                 (co_q == CO_TILES-1);
    last_output = out_valid_q && out_ready &&
                  (out_window_q == NUM_WINDOWS-1) &&
                  (out_token_q == TOKENS-1) &&
                  (out_co_q == CO_TILES-1);

    mem_rd_en = issue_fire;
    mem_rd_window_id = window_q;
    mem_rd_token_id = token_q;
    mem_rd_co_tile = co_q;

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
      window_q <= '0; token_q <= '0; co_q <= '0;
      req_meta_valid_q <= 1'b0;
      req_window_q <= '0; req_token_q <= '0; req_co_q <= '0;
      out_valid_q <= 1'b0;
      out_window_q <= '0; out_token_q <= '0; out_co_q <= '0; out_data_q <= '0;
    end else begin
      req_meta_valid_q <= issue_fire;
      if (issue_fire) begin
        req_window_q <= window_q;
        req_token_q <= token_q;
        req_co_q <= co_q;
      end

      if (out_valid_q && out_ready) out_valid_q <= 1'b0;
      if (response_fire) begin
        out_valid_q <= 1'b1;
        out_window_q <= req_window_q;
        out_token_q <= req_token_q;
        out_co_q <= req_co_q;
        out_data_q <= mem_rd_data;
      end

      case (state_q)
        S_IDLE: begin
          req_meta_valid_q <= 1'b0;
          out_valid_q <= 1'b0;
          if (start) begin
            window_q <= '0; token_q <= '0; co_q <= '0;
            state_q <= S_ISSUE;
          end
        end

        S_ISSUE: if (issue_fire) begin
          if (last_issue) begin
            state_q <= S_DRAIN;
          end else if (co_q == CO_TILES-1) begin
            co_q <= '0;
            if (token_q == TOKENS-1) begin
              token_q <= '0;
              window_q <= window_q + 1'b1;
            end else token_q <= token_q + 1'b1;
          end else co_q <= co_q + 1'b1;
        end

        S_DRAIN: if (last_output) state_q <= S_DONE;
        S_DONE: state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && (mem_rd_valid !== req_meta_valid_q))
      $fatal(1,"window reader APWIN violated one-cycle read contract");
    if (rst_n && response_fire && out_valid_q && !out_ready)
      $fatal(1,"window reader output-buffer overflow");
  end
`endif
endmodule
