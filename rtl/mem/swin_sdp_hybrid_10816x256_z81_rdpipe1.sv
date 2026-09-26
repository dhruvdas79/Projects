`timescale 1ns/1ps

// Z81 BANK-A timing version.
//
// Write latency: unchanged.
// Read request: one additional registered request stage.
// Read throughput: one request / clock.
// Read response latency: 2 clocks instead of 1.
//
// Purpose:
// break:
//   Swin address generation -> LUTRAM decode -> RAMD64E -> data FF
//
// into:
//   Swin address generation -> rd_addr_q
//   rd_addr_q -> memory -> rd_data
//
module swin_sdp_hybrid_10816x256_z81_rdpipe1 (
    input  logic         clk,

    input  logic         wr_en,
    input  logic [13:0]  wr_addr,
    input  logic [255:0] wr_data,

    input  logic         rd_en,
    input  logic [13:0]  rd_addr,
    output logic [255:0] rd_data
);

    (* ram_style = "block" *)
    logic [255:0] mem0 [0:4095];

    (* ram_style = "block" *)
    logic [255:0] mem1 [0:4095];

    (* ram_style = "block" *)
    logic [255:0] mem2 [0:2047];

    (* ram_style = "distributed" *)
    logic [255:0] mem_tail [0:575];

    // ----------------------------------------------------------
    // New timing cut.
    // ----------------------------------------------------------
    logic        rd_en_q;
    logic [13:0] rd_addr_q;

    logic [255:0] rd0_q;
    logic [255:0] rd1_q;
    logic [255:0] rd2_q;
    logic [255:0] rdt_q;
    logic [1:0]   rd_sel_q;

    logic [9:0] tail_rd_addr;

    always_comb begin
        if ((rd_addr_q >= 14'd10240) &&
            (rd_addr_q <  14'd10816))
            tail_rd_addr = rd_addr_q - 14'd10240;
        else
            tail_rd_addr = 10'd0;
    end

    wire [255:0] tail_rd_async =
        mem_tail[tail_rd_addr];

    always_ff @(posedge clk) begin

        // Write path unchanged.
        if (wr_en) begin
            if (wr_addr < 14'd4096)
                mem0[wr_addr] <= wr_data;
            else if (wr_addr < 14'd8192)
                mem1[wr_addr - 14'd4096] <= wr_data;
            else if (wr_addr < 14'd10240)
                mem2[wr_addr - 14'd8192] <= wr_data;
            else if (wr_addr < 14'd10816)
                mem_tail[wr_addr - 14'd10240] <= wr_data;
        end

        // P0: register read request/address.
        rd_en_q <= rd_en;

        if (rd_en)
            rd_addr_q <= rd_addr;

        // P1: physical memory read.
        if (rd_en_q) begin
            if (rd_addr_q < 14'd4096) begin
                rd0_q    <= mem0[rd_addr_q];
                rd_sel_q <= 2'd0;
            end
            else if (rd_addr_q < 14'd8192) begin
                rd1_q    <= mem1[rd_addr_q - 14'd4096];
                rd_sel_q <= 2'd1;
            end
            else if (rd_addr_q < 14'd10240) begin
                rd2_q    <= mem2[rd_addr_q - 14'd8192];
                rd_sel_q <= 2'd2;
            end
            else begin
                rdt_q    <= tail_rd_async;
                rd_sel_q <= 2'd3;
            end
        end
    end

    always_comb begin
        case (rd_sel_q)
            2'd0: rd_data = rd0_q;
            2'd1: rd_data = rd1_q;
            2'd2: rd_data = rd2_q;
            default: rd_data = rdt_q;
        endcase
    end

endmodule
