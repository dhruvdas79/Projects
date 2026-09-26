`timescale 1ns/1ps
// ============================================================================
// Simulation-only transaction-level replacement for the physical 32x32
// systolic MAC service.
//
// Purpose:
//   * Preserve the shared-service request/weight/input/raw-result protocol.
//   * Preserve exact integer dot-product arithmetic and tile accumulation.
//   * Eliminate event activity from 1024 cycle-accurate PE instances.
//
// This module is NEVER used by the synthesis filelist.  The synthesizable build
// continues to instantiate swin_shared32_mac_service and its physical 32x32
// DSP array.  Define FAST_SIM_MAC only for numerical end-to-end simulation.
// ============================================================================
module swin_shared32_mac_service_fast_sim #(
    parameter int PE_K       = 32,
    parameter int PE_N       = 32,
    parameter int DATA_W     = 9,
    parameter int RAW_W      = 64,
    parameter int TOKEN_W    = 12,
    parameter int TILE_W     = 4,
    parameter int WROW_W     = 5,
    parameter int PSUM_DEPTH = 4096
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic busy,
    output logic done,

    input  logic [TOKEN_W-1:0] cfg_tokens_m1,
    input  logic [TILE_W-1:0]  cfg_k_tiles_m1,
    input  logic [TILE_W-1:0]  cfg_n_tiles_m1,

    output logic                         stream_valid,
    output logic [TOKEN_W-1:0]           stream_token_id,
    output logic [TILE_W-1:0]            active_ci_tile,
    output logic [TILE_W-1:0]            active_co_tile,
    output logic                         weight_row_load,
    output logic [WROW_W-1:0]            weight_row_index,

    input  logic                         input_vector_valid,
    input  logic                         weight_row_valid,
    input  logic signed [DATA_W-1:0]     input_vector [0:PE_K-1],
    input  logic signed [DATA_W-1:0]     weight_row_values [0:PE_N-1],

    output logic                         raw_valid,
    output logic [TOKEN_W-1:0]           raw_token_id,
    output logic [TILE_W-1:0]            raw_co_tile,
    output logic signed [RAW_W-1:0]      raw_acc [0:PE_N-1]
);
    typedef enum logic [2:0] {
        F_IDLE,
        F_LOAD,
        F_STREAM,
        F_RESULT_GUARD,
        F_DONE
    } fstate_t;

    fstate_t state_q;
    logic [TOKEN_W-1:0] token_q;
    logic [TILE_W-1:0] ci_tile_q;
    logic [TILE_W-1:0] co_tile_q;
    logic [WROW_W-1:0] weight_row_q;

    // One 32x32 weight tile and one frame-sized partial-sum bank.  The first
    // CI tile overwrites every active token, so a bulk reset of psum_mem is not
    // required and would only slow simulation startup.
    logic signed [DATA_W-1:0] weight_tile [0:PE_K-1][0:PE_N-1];
    logic signed [RAW_W-1:0]  psum_mem [0:PSUM_DEPTH-1][0:PE_N-1];

    assign busy             = (state_q != F_IDLE) && (state_q != F_DONE);
    assign stream_valid     = (state_q == F_STREAM);
    assign stream_token_id  = token_q;
    assign active_ci_tile   = ci_tile_q;
    assign active_co_tile   = co_tile_q;
    assign weight_row_load  = (state_q == F_LOAD);
    assign weight_row_index = weight_row_q;

    always_ff @(posedge clk or negedge rst_n) begin : P_FAST_MAC
        longint signed dot_v;
        longint signed total_v;
        if (!rst_n) begin
            state_q      <= F_IDLE;
            token_q      <= '0;
            ci_tile_q    <= '0;
            co_tile_q    <= '0;
            weight_row_q <= '0;
            done         <= 1'b0;
            raw_valid    <= 1'b0;
            raw_token_id <= '0;
            raw_co_tile  <= '0;
            for (int lane = 0; lane < PE_N; lane = lane + 1)
                raw_acc[lane] <= '0;
        end else begin
            done      <= 1'b0;
            raw_valid <= 1'b0;

            case (state_q)
                F_IDLE: begin
                    if (start) begin
                        token_q      <= '0;
                        ci_tile_q    <= '0;
                        co_tile_q    <= '0;
                        weight_row_q <= '0;
                        state_q      <= F_LOAD;
                    end
                end

                F_LOAD: begin
                    if (weight_row_valid) begin
                        for (int lane = 0; lane < PE_N; lane = lane + 1)
                            weight_tile[weight_row_q][lane] <= weight_row_values[lane];

                        if (weight_row_q == PE_K-1) begin
                            token_q      <= '0;
                            weight_row_q <= '0;
                            state_q      <= F_STREAM;
                        end else begin
                            weight_row_q <= weight_row_q + 1'b1;
                        end
                    end
                end

                F_STREAM: begin
                    if (input_vector_valid) begin
                        for (int lane = 0; lane < PE_N; lane = lane + 1) begin
                            dot_v = 64'sd0;
                            for (int k = 0; k < PE_K; k = k + 1)
                                dot_v = dot_v + ($signed(input_vector[k]) * $signed(weight_tile[k][lane]));

                            if (ci_tile_q == '0)
                                total_v = dot_v;
                            else
                                total_v = $signed(psum_mem[token_q][lane]) + dot_v;

                            if (ci_tile_q == cfg_k_tiles_m1)
                                raw_acc[lane] <= total_v[RAW_W-1:0];
                            else
                                psum_mem[token_q][lane] <= total_v[RAW_W-1:0];
                        end

                        if (ci_tile_q == cfg_k_tiles_m1) begin
                            raw_valid    <= 1'b1;
                            raw_token_id <= token_q;
                            raw_co_tile  <= co_tile_q;
                        end

                        if (token_q == cfg_tokens_m1) begin
                            token_q <= '0;
                            if (ci_tile_q == cfg_k_tiles_m1) begin
                                ci_tile_q <= '0;
                                if (co_tile_q == cfg_n_tiles_m1) begin
                                    // Keep the arbiter grant alive for one full
                                    // cycle after the final raw vector.
                                    state_q <= F_RESULT_GUARD;
                                end else begin
                                    co_tile_q    <= co_tile_q + 1'b1;
                                    weight_row_q <= '0;
                                    state_q      <= F_LOAD;
                                end
                            end else begin
                                ci_tile_q    <= ci_tile_q + 1'b1;
                                weight_row_q <= '0;
                                state_q      <= F_LOAD;
                            end
                        end else begin
                            token_q <= token_q + 1'b1;
                        end
                    end
                end

                F_RESULT_GUARD: begin
                    state_q <= F_DONE;
                end

                F_DONE: begin
                    done    <= 1'b1;
                    state_q <= F_IDLE;
                end

                default: state_q <= F_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (PE_K != 32 || PE_N != 32)
            $fatal(1, "fast MAC model is qualified only for PE_K=PE_N=32");
        if (PSUM_DEPTH < 2704)
            $fatal(1, "fast MAC model PSUM_DEPTH must cover the P3 token count");
    end
`endif
endmodule
