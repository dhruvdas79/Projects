// ============================================================================
// psum_banked_mem.sv
// Vivado synthesis-safe banked partial-sum memory.
// ============================================================================
`timescale 1ns/1ps

module psum_banked_mem #(
    parameter int DEPTH  = 2704,
    parameter int PE_N   = 16,
    parameter int ACC_W  = 64,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int OUTPUT_REG = 0
) (
    input  logic                         clk,

    input  logic                         rd_en,
    input  logic [ADDR_W-1:0]            rd_addr,
    output logic signed [ACC_W-1:0]      rd_data [0:PE_N-1],

    input  logic                         wr_en,
    input  logic [ADDR_W-1:0]            wr_addr,
    input  logic signed [ACC_W-1:0]      wr_data [0:PE_N-1]
);

    genvar lane;
    generate
        for (lane = 0; lane < PE_N; lane = lane + 1) begin : G_PSUM_BANK
            (* ram_style = "block" *)
            logic signed [ACC_W-1:0] mem_bank [0:DEPTH-1];

            if (OUTPUT_REG != 0) begin : G_OUTPUT_REG
                // mem_rd_q is the synchronous BRAM read. rd_data is the
                // second stage Vivado may absorb into the optional DO_REG.
                logic signed [ACC_W-1:0] mem_rd_q;
                always_ff @(posedge clk) begin
                    if (wr_en)
                        mem_bank[wr_addr] <= wr_data[lane];
                    if (rd_en)
                        mem_rd_q <= mem_bank[rd_addr];
                    rd_data[lane] <= mem_rd_q;
                end
            end else begin : G_NO_OUTPUT_REG
                always_ff @(posedge clk) begin
                    if (wr_en)
                        mem_bank[wr_addr] <= wr_data[lane];
                    if (rd_en)
                        rd_data[lane] <= mem_bank[rd_addr];
                end
            end
        end
    endgenerate

endmodule
