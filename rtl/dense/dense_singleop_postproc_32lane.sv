`timescale 1ns/1ps
// ============================================================================
// dense_singleop_postproc_32lane.sv -- FAST-NODSP
//
// S1: 32 parallel bias adds and descriptor capture.
// S2..S8: fully pipelined exact radix-4 Booth shift/add requantization.
// Initiation interval is one 32-lane vector per clock; no runtime multiplier.
// ============================================================================
(* use_dsp = "no" *)
module dense_singleop_postproc_32lane #(
  parameter int LANES = 32,
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
  localparam int REQ_LAT = 7;

  logic signed [31:0] bias_rom [0:COUT-1];
  logic signed [31:0] m_rom [0:COUT-1];
  logic signed [15:0] shift_rom [0:COUT-1];
  logic signed [63:0] acc_comb [0:LANES-1];
  logic signed [31:0] m_comb [0:LANES-1];
  logic signed [15:0] s_comb [0:LANES-1];
  logic signed [31:0] m_q [0:LANES-1];
  logic signed [15:0] s_q [0:LANES-1];

  logic req_valid;
  logic signed [7:0] req_code [0:LANES-1];
  logic [TOKEN_ID_W-1:0] token_pipe [0:REQ_LAT-1];
  logic [CO_TILE_W-1:0] co_pipe [0:REQ_LAT-1];
  logic meta_valid [0:REQ_LAT-1];
  integer lane;
  integer stage;

  initial begin
`ifndef SYNTHESIS
    $display("Dense postproc bias  : %s", BIAS_MEM_FILE);
    $display("Dense postproc M     : %s", M_MEM_FILE);
    $display("Dense postproc shift : %s", SHIFT_MEM_FILE);
`endif
    $readmemh(BIAS_MEM_FILE, bias_rom);
    $readmemh(M_MEM_FILE, m_rom);
    $readmemh(SHIFT_MEM_FILE, shift_rom);
  end

  always_comb begin
    for (int lane_comb = 0; lane_comb < LANES; lane_comb++) begin
      int channel_index;
      channel_index = $unsigned(in_co_tile)*LANES + lane_comb;
      if (channel_index < COUT) begin
        acc_comb[lane_comb] = $signed(mac_sum[lane_comb]) + $signed(bias_rom[channel_index]);
        m_comb[lane_comb] = m_rom[channel_index];
        s_comb[lane_comb] = shift_rom[channel_index];
      end else begin
        acc_comb[lane_comb] = '0;
        m_comb[lane_comb] = '0;
        s_comb[lane_comb] = '0;
      end
    end
  end

  requant_s8_shiftadd_pipe #(.LANES(LANES)) u_requant_pipe (
    .clk(clk), .rst_n(rst_n),
    .in_valid(acc_valid_dbg),
    .in_value(acc_with_bias_dbg),
    .in_multiplier(m_q),
    .in_shift(s_q),
    .out_valid(req_valid),
    .out_code(req_code)
  );

  always_comb begin
    out_valid = req_valid;
    out_token_id = token_pipe[REQ_LAT-1];
    out_co_tile = co_pipe[REQ_LAT-1];
    for (int out_lane=0; out_lane<LANES; out_lane++)
      out_data[out_lane] = req_code[out_lane];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_valid_dbg <= 1'b0;
      acc_token_id_dbg <= '0;
      acc_co_tile_dbg <= '0;
      for(stage=0; stage<REQ_LAT; stage=stage+1) begin
        meta_valid[stage] <= 1'b0;
        token_pipe[stage] <= '0;
        co_pipe[stage] <= '0;
      end
      for (lane=0; lane<LANES; lane=lane+1) begin
        acc_with_bias_dbg[lane] <= '0;
        m_q[lane] <= '0;
        s_q[lane] <= '0;
      end
    end else begin
      acc_valid_dbg <= in_valid;
      if (in_valid) begin
        acc_token_id_dbg <= in_token_id;
        acc_co_tile_dbg <= in_co_tile;
        for (lane=0; lane<LANES; lane=lane+1) begin
          acc_with_bias_dbg[lane] <= acc_comb[lane];
          m_q[lane] <= m_comb[lane];
          s_q[lane] <= s_comb[lane];
        end
      end

      meta_valid[0] <= acc_valid_dbg;
      if(acc_valid_dbg) begin
        token_pipe[0] <= acc_token_id_dbg;
        co_pipe[0] <= acc_co_tile_dbg;
      end
      for(stage=1; stage<REQ_LAT; stage=stage+1) begin
        meta_valid[stage] <= meta_valid[stage-1];
        if(meta_valid[stage-1]) begin
          token_pipe[stage] <= token_pipe[stage-1];
          co_pipe[stage] <= co_pipe[stage-1];
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && (req_valid !== meta_valid[REQ_LAT-1]))
      $fatal(1, "dense postproc metadata / data pipeline misalignment");
  end
`endif
endmodule
