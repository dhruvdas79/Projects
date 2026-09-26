// ============================================================================
// dense_singleop_postproc_16lane.sv
// raw MAC + folded bias -> strict multiplier/shift requantization -> INT8.
// Reusable for FC1, FC2, or any single dense operation.
// ============================================================================
module dense_singleop_postproc_16lane #(
  parameter int LANES = 16,
  parameter int COUT = 128,
  parameter int TOKEN_ID_W = 10,
  parameter int CO_TILE_W = ((COUT/LANES) <= 1) ? 1 : $clog2(COUT/LANES),
  parameter [8*256-1:0] BIAS_MEM_FILE = "dense_folded_bias_i32.mem",
  parameter [8*256-1:0] M_MEM_FILE = "dense_requant_M_i32.mem",
  parameter [8*256-1:0] SHIFT_MEM_FILE = "dense_requant_shift_i16.mem"
)(
  input  logic clk,
  input  logic rst_n,
  input  logic in_valid,
  input  logic [TOKEN_ID_W-1:0] in_token_id,
  input  logic [CO_TILE_W-1:0] in_co_tile,
  input  logic signed [63:0] mac_sum [0:LANES-1],
  output logic acc_valid_dbg,
  output logic [TOKEN_ID_W-1:0] acc_token_id_dbg,
  output logic [CO_TILE_W-1:0] acc_co_tile_dbg,
  output logic signed [63:0] acc_with_bias_dbg [0:LANES-1],
  output logic out_valid,
  output logic [TOKEN_ID_W-1:0] out_token_id,
  output logic [CO_TILE_W-1:0] out_co_tile,
  output logic signed [7:0] out_data [0:LANES-1]
);
  import fixedpoint_pkg::*;

  logic signed [31:0] bias_rom [0:COUT-1];
  logic signed [31:0] m_rom [0:COUT-1];
  logic signed [15:0] shift_rom [0:COUT-1];
  logic signed [63:0] acc_comb [0:LANES-1];
  logic signed [7:0] out_comb [0:LANES-1];
  string bias_file, m_file, shift_file, romdir;

  initial begin
    bias_file = BIAS_MEM_FILE;
    m_file = M_MEM_FILE;
    shift_file = SHIFT_MEM_FILE;
`ifndef SYNTHESIS
    if ($value$plusargs("DENSEROMDIR=%s", romdir)) begin
      bias_file = {romdir,"/folded_bias_i32.mem"};
      m_file = {romdir,"/requant_M_i32.mem"};
      shift_file = {romdir,"/requant_shift_i16.mem"};
    end
`endif
    $display("Dense postproc bias  : %s", bias_file);
    $display("Dense postproc M     : %s", m_file);
    $display("Dense postproc shift : %s", shift_file);
    $readmemh(bias_file, bias_rom);
    $readmemh(m_file, m_rom);
    $readmemh(shift_file, shift_rom);
  end

  always_comb begin
    for (int lane_comb = 0; lane_comb < LANES; lane_comb++) begin
      int channel_index;
      longint signed requant_wide;
      channel_index = $unsigned(in_co_tile)*LANES + lane_comb;
      if (channel_index < COUT) begin
        acc_comb[lane_comb] = $signed(mac_sum[lane_comb]) + $signed(bias_rom[channel_index]);
        requant_wide = apply_mshift_i64(acc_comb[lane_comb], m_rom[channel_index], shift_rom[channel_index]);
        out_comb[lane_comb] = sat_s8(requant_wide);
      end else begin
        acc_comb[lane_comb] = '0;
        out_comb[lane_comb] = '0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_valid_dbg <= 1'b0;
      acc_token_id_dbg <= '0;
      acc_co_tile_dbg <= '0;
      out_valid <= 1'b0;
      out_token_id <= '0;
      out_co_tile <= '0;
      for (int lane_rst = 0; lane_rst < LANES; lane_rst++) begin
        acc_with_bias_dbg[lane_rst] <= '0;
        out_data[lane_rst] <= '0;
      end
    end else begin
      acc_valid_dbg <= in_valid;
      out_valid <= in_valid;
      if (in_valid) begin
        acc_token_id_dbg <= in_token_id;
        acc_co_tile_dbg <= in_co_tile;
        out_token_id <= in_token_id;
        out_co_tile <= in_co_tile;
        for (int lane_ff = 0; lane_ff < LANES; lane_ff++) begin
          acc_with_bias_dbg[lane_ff] <= acc_comb[lane_ff];
          out_data[lane_ff] <= out_comb[lane_ff];
        end
      end
    end
  end
endmodule
