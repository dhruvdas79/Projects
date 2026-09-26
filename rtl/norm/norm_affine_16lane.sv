`timescale 1ns/1ps
// ============================================================================
// norm_affine_16lane.sv -- FAST exact banked-LUT normalization
//
// For each physical lane, channel tile and signed INT8 input select a
// precomputed strict affine output. The lane banks are independent, so all 16
// values are read in parallel without DSPs.
//
// Throughput: one 16-lane vector per clock (II=1)
// Latency   : one clock
// DSP usage : zero
// V5.0 synthesis: 16 synchronous banked ROMs, block-ROM inference requested.
// ============================================================================
(* use_dsp = "no" *)
module norm_affine_16lane #(
    parameter int CHANNELS   = 128,
    parameter int LANES      = 16,
    parameter int DATA_W     = 8,
    parameter int CO_TILES   = CHANNELS / LANES,
    parameter int PIXEL_ID_W = 10,
    parameter int CO_TILE_W  = (CO_TILES <= 1) ? 1 : $clog2(CO_TILES),
    // Legacy descriptors retained for interface compatibility/audit.
    parameter [8*256-1:0] BN_M_MEM = "bn_M_i32.mem",
    parameter [8*256-1:0] BN_SHIFT_MEM = "bn_shift_i16.mem",
    parameter [8*256-1:0] BN_BIAS_MEM = "bn_bias_i32.mem",
    parameter [8*256-1:0] NORM_LUT00_MEM = "norm_lut_lane00_i8.mem",
    parameter [8*256-1:0] NORM_LUT01_MEM = "norm_lut_lane01_i8.mem",
    parameter [8*256-1:0] NORM_LUT02_MEM = "norm_lut_lane02_i8.mem",
    parameter [8*256-1:0] NORM_LUT03_MEM = "norm_lut_lane03_i8.mem",
    parameter [8*256-1:0] NORM_LUT04_MEM = "norm_lut_lane04_i8.mem",
    parameter [8*256-1:0] NORM_LUT05_MEM = "norm_lut_lane05_i8.mem",
    parameter [8*256-1:0] NORM_LUT06_MEM = "norm_lut_lane06_i8.mem",
    parameter [8*256-1:0] NORM_LUT07_MEM = "norm_lut_lane07_i8.mem",
    parameter [8*256-1:0] NORM_LUT08_MEM = "norm_lut_lane08_i8.mem",
    parameter [8*256-1:0] NORM_LUT09_MEM = "norm_lut_lane09_i8.mem",
    parameter [8*256-1:0] NORM_LUT10_MEM = "norm_lut_lane10_i8.mem",
    parameter [8*256-1:0] NORM_LUT11_MEM = "norm_lut_lane11_i8.mem",
    parameter [8*256-1:0] NORM_LUT12_MEM = "norm_lut_lane12_i8.mem",
    parameter [8*256-1:0] NORM_LUT13_MEM = "norm_lut_lane13_i8.mem",
    parameter [8*256-1:0] NORM_LUT14_MEM = "norm_lut_lane14_i8.mem",
    parameter [8*256-1:0] NORM_LUT15_MEM = "norm_lut_lane15_i8.mem"
) (
    input logic clk,input logic rst_n,
    input logic in_valid,
    input logic [PIXEL_ID_W-1:0] in_pixel_id,
    input logic [CO_TILE_W-1:0] in_co_tile,
    input logic signed [LANES*DATA_W-1:0] in_data,
    output logic out_valid,
    output logic [PIXEL_ID_W-1:0] out_pixel_id,
    output logic [CO_TILE_W-1:0] out_co_tile,
    output logic signed [LANES*DATA_W-1:0] out_data
);
    (* rom_style = "block" *) logic signed [7:0] lut00 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut01 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut02 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut03 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut04 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut05 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut06 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut07 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut08 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut09 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut10 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut11 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut12 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut13 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut14 [0:CO_TILES*256-1];
    (* rom_style = "block" *) logic signed [7:0] lut15 [0:CO_TILES*256-1];

    initial begin
        $readmemh(NORM_LUT00_MEM, lut00);
        $readmemh(NORM_LUT01_MEM, lut01);
        $readmemh(NORM_LUT02_MEM, lut02);
        $readmemh(NORM_LUT03_MEM, lut03);
        $readmemh(NORM_LUT04_MEM, lut04);
        $readmemh(NORM_LUT05_MEM, lut05);
        $readmemh(NORM_LUT06_MEM, lut06);
        $readmemh(NORM_LUT07_MEM, lut07);
        $readmemh(NORM_LUT08_MEM, lut08);
        $readmemh(NORM_LUT09_MEM, lut09);
        $readmemh(NORM_LUT10_MEM, lut10);
        $readmemh(NORM_LUT11_MEM, lut11);
        $readmemh(NORM_LUT12_MEM, lut12);
        $readmemh(NORM_LUT13_MEM, lut13);
        $readmemh(NORM_LUT14_MEM, lut14);
        $readmemh(NORM_LUT15_MEM, lut15);
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            out_valid<=1'b0; out_pixel_id<='0; out_co_tile<='0; out_data<='0;
        end else begin
            out_valid <= in_valid;
            if(in_valid) begin : norm_block_rom_read
                int base_addr;
                base_addr = $unsigned(in_co_tile) << 8;
                out_pixel_id <= in_pixel_id;
                out_co_tile <= in_co_tile;
                out_data[0*DATA_W +: DATA_W] <= lut00[base_addr + $unsigned(in_data[0*DATA_W +: DATA_W])];
                out_data[1*DATA_W +: DATA_W] <= lut01[base_addr + $unsigned(in_data[1*DATA_W +: DATA_W])];
                out_data[2*DATA_W +: DATA_W] <= lut02[base_addr + $unsigned(in_data[2*DATA_W +: DATA_W])];
                out_data[3*DATA_W +: DATA_W] <= lut03[base_addr + $unsigned(in_data[3*DATA_W +: DATA_W])];
                out_data[4*DATA_W +: DATA_W] <= lut04[base_addr + $unsigned(in_data[4*DATA_W +: DATA_W])];
                out_data[5*DATA_W +: DATA_W] <= lut05[base_addr + $unsigned(in_data[5*DATA_W +: DATA_W])];
                out_data[6*DATA_W +: DATA_W] <= lut06[base_addr + $unsigned(in_data[6*DATA_W +: DATA_W])];
                out_data[7*DATA_W +: DATA_W] <= lut07[base_addr + $unsigned(in_data[7*DATA_W +: DATA_W])];
                out_data[8*DATA_W +: DATA_W] <= lut08[base_addr + $unsigned(in_data[8*DATA_W +: DATA_W])];
                out_data[9*DATA_W +: DATA_W] <= lut09[base_addr + $unsigned(in_data[9*DATA_W +: DATA_W])];
                out_data[10*DATA_W +: DATA_W] <= lut10[base_addr + $unsigned(in_data[10*DATA_W +: DATA_W])];
                out_data[11*DATA_W +: DATA_W] <= lut11[base_addr + $unsigned(in_data[11*DATA_W +: DATA_W])];
                out_data[12*DATA_W +: DATA_W] <= lut12[base_addr + $unsigned(in_data[12*DATA_W +: DATA_W])];
                out_data[13*DATA_W +: DATA_W] <= lut13[base_addr + $unsigned(in_data[13*DATA_W +: DATA_W])];
                out_data[14*DATA_W +: DATA_W] <= lut14[base_addr + $unsigned(in_data[14*DATA_W +: DATA_W])];
                out_data[15*DATA_W +: DATA_W] <= lut15[base_addr + $unsigned(in_data[15*DATA_W +: DATA_W])];
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(LANES != 16 || DATA_W != 8 || CHANNELS != 128)
            $fatal(1,"FAST norm LUT expects CHANNELS=128, LANES=16, DATA_W=8");
        if(BN_M_MEM=="" || BN_SHIFT_MEM=="" || BN_BIAS_MEM=="")
            $fatal(1,"Missing retained norm descriptors");
    end
`endif
endmodule
