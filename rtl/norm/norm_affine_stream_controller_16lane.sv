`timescale 1ns/1ps
// ============================================================================
// norm_affine_stream_controller_16lane.sv -- V6.2 BRAM pipeline controller
//
// The source RAM is a fixed one-cycle-latency synchronous memory.  Requests
// advance every clock, while request metadata is delayed one clock to align
// with src_rd_valid/src_rd_data.  The previous request/wait protocol inserted
// an avoidable bubble between every vector.
//
// Request II : 1 clock
// Norm II    : 1 clock
// DSP usage  : zero
// ============================================================================
module norm_affine_stream_controller_16lane #(
    parameter int PIXELS      = 900,
    parameter int CHANNELS    = 128,
    parameter int LANES       = 16,
    parameter int DATA_W      = 8,
    parameter int CO_TILES    = CHANNELS / LANES,
    parameter int PIXEL_ID_W  = (PIXELS   <= 1) ? 1 : $clog2(PIXELS),
    parameter int CO_TILE_W   = (CO_TILES <= 1) ? 1 : $clog2(CO_TILES)
) (
    input  logic clk,input logic rst_n,input logic start,output logic done,
    output logic src_rd_en,
    output logic [PIXEL_ID_W-1:0] src_rd_pixel_id,
    output logic [CO_TILE_W-1:0] src_rd_co_tile,
    input  logic src_rd_valid,
    input  logic signed [LANES*DATA_W-1:0] src_rd_data,
    output logic norm_in_valid,
    output logic [PIXEL_ID_W-1:0] norm_in_pixel_id,
    output logic [CO_TILE_W-1:0] norm_in_co_tile,
    output logic signed [LANES*DATA_W-1:0] norm_in_data,
    input  logic norm_out_valid,
    input  logic [PIXEL_ID_W-1:0] norm_out_pixel_id,
    input  logic [CO_TILE_W-1:0] norm_out_co_tile,
    input  logic signed [LANES*DATA_W-1:0] norm_out_data,
    output logic dst_wr_valid,
    output logic [PIXEL_ID_W-1:0] dst_wr_pixel_id,
    output logic [CO_TILE_W-1:0] dst_wr_co_tile,
    output logic signed [LANES*DATA_W-1:0] dst_wr_data
);
    typedef enum logic [1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_DONE} state_t;
    state_t state_q;

    logic [PIXEL_ID_W-1:0] issue_pixel_q;
    logic [CO_TILE_W-1:0] issue_co_q;
    logic req_meta_valid_q;
    logic [PIXEL_ID_W-1:0] req_pixel_q;
    logic [CO_TILE_W-1:0] req_co_q;
    logic issue_fire;
    logic last_issue;
    logic last_output;

    always_comb begin
        issue_fire = (state_q == S_ISSUE);
        last_issue = (issue_pixel_q == PIXELS-1) &&
                     (issue_co_q == CO_TILES-1);

        src_rd_en = issue_fire;
        src_rd_pixel_id = issue_pixel_q;
        src_rd_co_tile = issue_co_q;

        norm_in_valid = src_rd_valid && req_meta_valid_q;
        norm_in_pixel_id = req_pixel_q;
        norm_in_co_tile = req_co_q;
        norm_in_data = src_rd_data;

        dst_wr_valid = norm_out_valid;
        dst_wr_pixel_id = norm_out_pixel_id;
        dst_wr_co_tile = norm_out_co_tile;
        dst_wr_data = norm_out_data;

        last_output = norm_out_valid &&
                      (norm_out_pixel_id == PIXELS-1) &&
                      (norm_out_co_tile == CO_TILES-1);
        done = (state_q == S_DONE);
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state_q <= S_IDLE;
            issue_pixel_q <= '0;
            issue_co_q <= '0;
            req_meta_valid_q <= 1'b0;
            req_pixel_q <= '0;
            req_co_q <= '0;
        end else begin
            // One-cycle source-RAM request metadata pipeline.
            req_meta_valid_q <= issue_fire;
            if (issue_fire) begin
                req_pixel_q <= issue_pixel_q;
                req_co_q <= issue_co_q;
            end

            case(state_q)
                S_IDLE: begin
                    req_meta_valid_q <= 1'b0;
                    if(start) begin
                        issue_pixel_q <= '0;
                        issue_co_q <= '0;
                        state_q <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    if(last_issue) begin
                        state_q <= S_DRAIN;
                    end else if(issue_co_q == CO_TILES-1) begin
                        issue_co_q <= '0;
                        issue_pixel_q <= issue_pixel_q + 1'b1;
                    end else begin
                        issue_co_q <= issue_co_q + 1'b1;
                    end
                end

                S_DRAIN: begin
                    if(last_output) state_q <= S_DONE;
                end

                S_DONE: state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n && (src_rd_valid !== req_meta_valid_q))
        $fatal(1, "norm source RAM violated fixed one-cycle read contract");
    end
`endif
endmodule
