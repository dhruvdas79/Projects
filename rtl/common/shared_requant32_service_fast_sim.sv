`timescale 1ns/1ps
// ============================================================================
// Simulation-only direct-arithmetic replacement for the seven-stage Booth
// requantizer.  It preserves the strict signed product truncation, rounding and
// INT8 saturation, while removing thousands of shift/add pipeline events.
//
// This module is excluded from synthesis.  Define FAST_SIM_REQUANT only for
// numerical end-to-end simulation.
// ============================================================================
module shared_requant32_service_fast_sim #(
    parameter int LANES   = 32,
    parameter int ROUTE_W = 6
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                         in_valid,
    input  logic [ROUTE_W-1:0]           in_route,
    input  logic [1:0]                   in_op,
    input  logic [1:0]                   in_layer,
    input  logic [11:0]                  in_token,
    input  logic [6:0]                   in_co,
    input  logic signed [63:0]           in_value      [0:LANES-1],
    input  logic signed [31:0]           in_multiplier [0:LANES-1],
    input  logic signed [15:0]           in_shift      [0:LANES-1],

    output logic                         out_valid,
    output logic [ROUTE_W-1:0]           out_route,
    output logic [1:0]                   out_op,
    output logic [1:0]                   out_layer,
    output logic [11:0]                  out_token,
    output logic [6:0]                   out_co,
    output logic signed [7:0]            out_code       [0:LANES-1]
);
    import fixedpoint_pkg::*;

    always_ff @(posedge clk or negedge rst_n) begin : P_FAST_REQUANT
        logic signed [95:0] product_full;
        logic signed [63:0] product_i64;
        longint signed rounded_v;
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_route <= '0;
            out_op    <= '0;
            out_layer <= '0;
            out_token <= '0;
            out_co    <= '0;
            for (int lane = 0; lane < LANES; lane = lane + 1)
                out_code[lane] <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                out_route <= in_route;
                out_op    <= in_op;
                out_layer <= in_layer;
                out_token <= in_token;
                out_co    <= in_co;
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    product_full = $signed(in_value[lane]) * $signed(in_multiplier[lane]);
                    // The qualified RTL intentionally uses 64-bit two's-
                    // complement product assignment.  Keep the low 64 bits.
                    product_i64 = product_full[63:0];
                    rounded_v = round_shift(product_i64, $signed(in_shift[lane]));
                    out_code[lane] <= sat_s8(rounded_v);
                end
            end
        end
    end
endmodule
