`timescale 1ns/1ps
// ============================================================================
// norm_affine_32lane_dualport.sv -- exact 32-lane, one-cycle Norm LUT
//
// One ROM bank is retained for each physical lane position 0..15.  Each bank
// is read at the low and high 16-channel tile addresses in the same clock,
// matching a true-dual-port ROM.  This supplies one 32-lane normalized vector
// per clock without instantiating a full normalized-frame buffer.
// ============================================================================
(* use_dsp = "no" *)
module norm_affine_32lane_dualport #(
  parameter int CHANNELS=128,
  parameter int LANES16=16,
  parameter int LANES32=32,
  parameter int DATA_W=8,
  parameter int CO_TILES16=CHANNELS/LANES16,
  parameter int CO_TILES32=CHANNELS/LANES32,
  parameter int TOKEN_W=12,
  parameter int CO32_W=(CO_TILES32<=1)?1:$clog2(CO_TILES32),
  parameter [8*256-1:0] NORM_LUT00_MEM="norm_lut_lane00_i8.mem",
  parameter [8*256-1:0] NORM_LUT01_MEM="norm_lut_lane01_i8.mem",
  parameter [8*256-1:0] NORM_LUT02_MEM="norm_lut_lane02_i8.mem",
  parameter [8*256-1:0] NORM_LUT03_MEM="norm_lut_lane03_i8.mem",
  parameter [8*256-1:0] NORM_LUT04_MEM="norm_lut_lane04_i8.mem",
  parameter [8*256-1:0] NORM_LUT05_MEM="norm_lut_lane05_i8.mem",
  parameter [8*256-1:0] NORM_LUT06_MEM="norm_lut_lane06_i8.mem",
  parameter [8*256-1:0] NORM_LUT07_MEM="norm_lut_lane07_i8.mem",
  parameter [8*256-1:0] NORM_LUT08_MEM="norm_lut_lane08_i8.mem",
  parameter [8*256-1:0] NORM_LUT09_MEM="norm_lut_lane09_i8.mem",
  parameter [8*256-1:0] NORM_LUT10_MEM="norm_lut_lane10_i8.mem",
  parameter [8*256-1:0] NORM_LUT11_MEM="norm_lut_lane11_i8.mem",
  parameter [8*256-1:0] NORM_LUT12_MEM="norm_lut_lane12_i8.mem",
  parameter [8*256-1:0] NORM_LUT13_MEM="norm_lut_lane13_i8.mem",
  parameter [8*256-1:0] NORM_LUT14_MEM="norm_lut_lane14_i8.mem",
  parameter [8*256-1:0] NORM_LUT15_MEM="norm_lut_lane15_i8.mem"
)(
  input logic clk,
  input logic rst_n,
  input logic in_valid,
  input logic [TOKEN_W-1:0] in_token,
  input logic [CO32_W-1:0] in_co_tile,
  input logic signed [LANES32*DATA_W-1:0] in_data,
  output logic out_valid,
  output logic [TOKEN_W-1:0] out_token,
  output logic [CO32_W-1:0] out_co_tile,
  output logic signed [LANES32*DATA_W-1:0] out_data
);
  localparam int LUT_DEPTH=CO_TILES16*256;
  (* rom_style="block" *) logic signed [7:0] lut00[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut01[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut02[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut03[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut04[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut05[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut06[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut07[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut08[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut09[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut10[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut11[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut12[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut13[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut14[0:LUT_DEPTH-1];
  (* rom_style="block" *) logic signed [7:0] lut15[0:LUT_DEPTH-1];

  initial begin
    $readmemh(NORM_LUT00_MEM,lut00); $readmemh(NORM_LUT01_MEM,lut01);
    $readmemh(NORM_LUT02_MEM,lut02); $readmemh(NORM_LUT03_MEM,lut03);
    $readmemh(NORM_LUT04_MEM,lut04); $readmemh(NORM_LUT05_MEM,lut05);
    $readmemh(NORM_LUT06_MEM,lut06); $readmemh(NORM_LUT07_MEM,lut07);
    $readmemh(NORM_LUT08_MEM,lut08); $readmemh(NORM_LUT09_MEM,lut09);
    $readmemh(NORM_LUT10_MEM,lut10); $readmemh(NORM_LUT11_MEM,lut11);
    $readmemh(NORM_LUT12_MEM,lut12); $readmemh(NORM_LUT13_MEM,lut13);
    $readmemh(NORM_LUT14_MEM,lut14); $readmemh(NORM_LUT15_MEM,lut15);
  end

  always_ff @(posedge clk or negedge rst_n) begin : DUALPORT_NORM_READ
    integer base_lo;
    integer base_hi;
    if(!rst_n) begin
      out_valid<=1'b0; out_token<='0; out_co_tile<='0; out_data<='0;
    end else begin
      out_valid<=in_valid;
      if(in_valid) begin
        base_lo=(($unsigned(in_co_tile)<<1)    <<8);
        base_hi=((($unsigned(in_co_tile)<<1)+1)<<8);
        out_token<=in_token; out_co_tile<=in_co_tile;
        out_data[0*8 +:8]<=lut00[base_lo+$unsigned(in_data[0*8 +:8])];
        out_data[1*8 +:8]<=lut01[base_lo+$unsigned(in_data[1*8 +:8])];
        out_data[2*8 +:8]<=lut02[base_lo+$unsigned(in_data[2*8 +:8])];
        out_data[3*8 +:8]<=lut03[base_lo+$unsigned(in_data[3*8 +:8])];
        out_data[4*8 +:8]<=lut04[base_lo+$unsigned(in_data[4*8 +:8])];
        out_data[5*8 +:8]<=lut05[base_lo+$unsigned(in_data[5*8 +:8])];
        out_data[6*8 +:8]<=lut06[base_lo+$unsigned(in_data[6*8 +:8])];
        out_data[7*8 +:8]<=lut07[base_lo+$unsigned(in_data[7*8 +:8])];
        out_data[8*8 +:8]<=lut08[base_lo+$unsigned(in_data[8*8 +:8])];
        out_data[9*8 +:8]<=lut09[base_lo+$unsigned(in_data[9*8 +:8])];
        out_data[10*8+:8]<=lut10[base_lo+$unsigned(in_data[10*8+:8])];
        out_data[11*8+:8]<=lut11[base_lo+$unsigned(in_data[11*8+:8])];
        out_data[12*8+:8]<=lut12[base_lo+$unsigned(in_data[12*8+:8])];
        out_data[13*8+:8]<=lut13[base_lo+$unsigned(in_data[13*8+:8])];
        out_data[14*8+:8]<=lut14[base_lo+$unsigned(in_data[14*8+:8])];
        out_data[15*8+:8]<=lut15[base_lo+$unsigned(in_data[15*8+:8])];
        out_data[16*8+:8]<=lut00[base_hi+$unsigned(in_data[16*8+:8])];
        out_data[17*8+:8]<=lut01[base_hi+$unsigned(in_data[17*8+:8])];
        out_data[18*8+:8]<=lut02[base_hi+$unsigned(in_data[18*8+:8])];
        out_data[19*8+:8]<=lut03[base_hi+$unsigned(in_data[19*8+:8])];
        out_data[20*8+:8]<=lut04[base_hi+$unsigned(in_data[20*8+:8])];
        out_data[21*8+:8]<=lut05[base_hi+$unsigned(in_data[21*8+:8])];
        out_data[22*8+:8]<=lut06[base_hi+$unsigned(in_data[22*8+:8])];
        out_data[23*8+:8]<=lut07[base_hi+$unsigned(in_data[23*8+:8])];
        out_data[24*8+:8]<=lut08[base_hi+$unsigned(in_data[24*8+:8])];
        out_data[25*8+:8]<=lut09[base_hi+$unsigned(in_data[25*8+:8])];
        out_data[26*8+:8]<=lut10[base_hi+$unsigned(in_data[26*8+:8])];
        out_data[27*8+:8]<=lut11[base_hi+$unsigned(in_data[27*8+:8])];
        out_data[28*8+:8]<=lut12[base_hi+$unsigned(in_data[28*8+:8])];
        out_data[29*8+:8]<=lut13[base_hi+$unsigned(in_data[29*8+:8])];
        out_data[30*8+:8]<=lut14[base_hi+$unsigned(in_data[30*8+:8])];
        out_data[31*8+:8]<=lut15[base_hi+$unsigned(in_data[31*8+:8])];
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if(CHANNELS!=128 || LANES32!=32 || DATA_W!=8)
      $fatal(1,"norm_affine_32lane_dualport is qualified for 128ch/32lane/INT8");
  end
`endif
endmodule
