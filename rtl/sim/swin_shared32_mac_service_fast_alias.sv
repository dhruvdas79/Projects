`timescale 1ns/1ps
// ============================================================================
// Simulation-only compatibility wrapper for post-Swin blockwise tests.
//
// It intentionally has the SAME module name/interface as the synthesizable
// swin_shared32_mac_service, but internally uses the already-qualified exact
// transaction-level integer MAC model.  Compile this file ONLY in the special
// post_swin_shared32_profiled_fast_tb.f filelist supplied by this patch.
// Synthesis filelists are not modified to reference this wrapper.
// ============================================================================
module swin_shared32_mac_service #(
    parameter int PE_K       = 32,
    parameter int PE_N       = 32,
    parameter int DATA_W     = 9,
    parameter int ACC_W      = 48,  // compatibility only; fast model accumulates in RAW_W
    parameter int RAW_W      = 64,
    parameter int TOKEN_W    = 12,
    parameter int TILE_W     = 4,
    parameter int WROW_W     = 5,
    parameter int PSUM_DEPTH = 4096,
    parameter int DRAIN_CYCLES = PE_K + PE_N, // compatibility only
    parameter int MEM_DRAIN_CYCLES = 4,        // compatibility only
    parameter int PE_LATENCY = PE_K + PE_N     // tolerance for newer local wrappers
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
    // Keep compatibility parameters referenced so strict linters do not flag
    // them as accidental omissions. They do not alter numerical behavior.
    localparam int _COMPAT_ACC_W = ACC_W;
    localparam int _COMPAT_DRAIN = DRAIN_CYCLES + MEM_DRAIN_CYCLES + PE_LATENCY;

    swin_shared32_mac_service_fast_sim #(
        .PE_K(PE_K),
        .PE_N(PE_N),
        .DATA_W(DATA_W),
        .RAW_W(RAW_W),
        .TOKEN_W(TOKEN_W),
        .TILE_W(TILE_W),
        .WROW_W(WROW_W),
        .PSUM_DEPTH(PSUM_DEPTH)
    ) u_fast_post_mac (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .cfg_tokens_m1(cfg_tokens_m1),
        .cfg_k_tiles_m1(cfg_k_tiles_m1),
        .cfg_n_tiles_m1(cfg_n_tiles_m1),
        .stream_valid(stream_valid),
        .stream_token_id(stream_token_id),
        .active_ci_tile(active_ci_tile),
        .active_co_tile(active_co_tile),
        .weight_row_load(weight_row_load),
        .weight_row_index(weight_row_index),
        .input_vector_valid(input_vector_valid),
        .weight_row_valid(weight_row_valid),
        .input_vector(input_vector),
        .weight_row_values(weight_row_values),
        .raw_valid(raw_valid),
        .raw_token_id(raw_token_id),
        .raw_co_tile(raw_co_tile),
        .raw_acc(raw_acc)
    );

`ifndef SYNTHESIS
    initial begin
        if (_COMPAT_ACC_W <= 0 || _COMPAT_DRAIN <= 0)
            $fatal(1, "post fast MAC alias: invalid compatibility parameters");
        $display("[POST_FAST_MAC_ALIAS] %m exact transaction-level 32x32 service enabled");
    end
`endif
endmodule
