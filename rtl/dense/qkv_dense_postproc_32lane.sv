`timescale 1ns/1ps
// ============================================================================
// qkv_dense_postproc_32lane.sv -- FAST-NODSP
//
// S1: 32 parallel bias adds and descriptor capture.
// S2..S8: fully pipelined radix-4 Booth shift/add requantization.
//
// Initiation interval: one 32-lane vector per clock.
// Runtime multipliers: none. DSP use is prohibited on this module.
// ============================================================================
(* use_dsp = "no" *)
module qkv_dense_postproc_32lane #(
  parameter int LANES=32, parameter int COUT=128, parameter int TOKEN_ID_W=10,
  parameter int CO_TILE_W=((COUT/LANES)<=1)?1:$clog2(COUT/LANES),
  parameter [8*256-1:0] Q_BIAS_MEM = "q_folded_bias_i32.mem", parameter [8*256-1:0] Q_M_MEM = "q_requant_M_i32.mem", parameter [8*256-1:0] Q_SHIFT_MEM = "q_requant_shift_i16.mem",
  parameter [8*256-1:0] K_BIAS_MEM = "k_folded_bias_i32.mem", parameter [8*256-1:0] K_M_MEM = "k_requant_M_i32.mem", parameter [8*256-1:0] K_SHIFT_MEM = "k_requant_shift_i16.mem",
  parameter [8*256-1:0] V_BIAS_MEM = "v_folded_bias_i32.mem", parameter [8*256-1:0] V_M_MEM = "v_requant_M_i32.mem", parameter [8*256-1:0] V_SHIFT_MEM = "v_requant_shift_i16.mem"
)(
  input logic clk,input logic rst_n,
  input logic in_valid,input logic [1:0] in_op,
  input logic [TOKEN_ID_W-1:0] in_token_id,input logic [CO_TILE_W-1:0] in_co_tile,
  input logic signed [63:0] mac_sum [0:LANES-1],
  output logic acc_valid_dbg,output logic [1:0] acc_op_dbg,
  output logic [TOKEN_ID_W-1:0] acc_token_id_dbg,output logic [CO_TILE_W-1:0] acc_co_tile_dbg,
  output logic signed [63:0] acc_with_bias_dbg [0:LANES-1],
  output logic out_valid,output logic [1:0] out_op,
  output logic [TOKEN_ID_W-1:0] out_token_id,output logic [CO_TILE_W-1:0] out_co_tile,
  output logic signed [7:0] out_data [0:LANES-1]
);
  localparam logic [1:0] OP_Q=2'd0, OP_K=2'd1, OP_V=2'd2;
  localparam int REQ_LAT = 7;

  logic signed [31:0] q_bias[0:COUT-1],k_bias[0:COUT-1],v_bias[0:COUT-1];
  logic signed [31:0] q_m[0:COUT-1],k_m[0:COUT-1],v_m[0:COUT-1];
  logic signed [15:0] q_s[0:COUT-1],k_s[0:COUT-1],v_s[0:COUT-1];

  logic signed [63:0] acc_comb [0:LANES-1];
  logic signed [31:0] m_comb [0:LANES-1];
  logic signed [15:0] s_comb [0:LANES-1];
  logic signed [31:0] m_q [0:LANES-1];
  logic signed [15:0] s_q [0:LANES-1];

  logic req_valid;
  logic signed [7:0] req_code [0:LANES-1];
  logic [1:0] op_pipe [0:REQ_LAT-1];
  logic [TOKEN_ID_W-1:0] token_pipe [0:REQ_LAT-1];
  logic [CO_TILE_W-1:0] co_pipe [0:REQ_LAT-1];
  logic meta_valid [0:REQ_LAT-1];

  integer lane;
  integer stage;

  initial begin
    $readmemh(Q_BIAS_MEM, q_bias); $readmemh(Q_M_MEM, q_m); $readmemh(Q_SHIFT_MEM, q_s);
    $readmemh(K_BIAS_MEM, k_bias); $readmemh(K_M_MEM, k_m); $readmemh(K_SHIFT_MEM, k_s);
    $readmemh(V_BIAS_MEM, v_bias); $readmemh(V_M_MEM, v_m); $readmemh(V_SHIFT_MEM, v_s);
  end

  always_comb begin
    for (int lane_comb=0; lane_comb<LANES; lane_comb++) begin
      int channel_index;
      logic signed [31:0] bias_sel;
      channel_index = $unsigned(in_co_tile)*LANES + lane_comb;
      bias_sel='0; m_comb[lane_comb]='0; s_comb[lane_comb]='0;
      if (channel_index < COUT) begin
        case (in_op)
          OP_Q: begin bias_sel=q_bias[channel_index]; m_comb[lane_comb]=q_m[channel_index]; s_comb[lane_comb]=q_s[channel_index]; end
          OP_K: begin bias_sel=k_bias[channel_index]; m_comb[lane_comb]=k_m[channel_index]; s_comb[lane_comb]=k_s[channel_index]; end
          OP_V: begin bias_sel=v_bias[channel_index]; m_comb[lane_comb]=v_m[channel_index]; s_comb[lane_comb]=v_s[channel_index]; end
          default: begin end
        endcase
        acc_comb[lane_comb] = $signed(mac_sum[lane_comb]) + $signed(bias_sel);
      end else begin
        acc_comb[lane_comb] = '0;
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
    out_op = op_pipe[REQ_LAT-1];
    out_token_id = token_pipe[REQ_LAT-1];
    out_co_tile = co_pipe[REQ_LAT-1];
    for (int out_lane=0; out_lane<LANES; out_lane++)
      out_data[out_lane] = req_code[out_lane];
  end

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      acc_valid_dbg<=1'b0; acc_op_dbg<='0; acc_token_id_dbg<='0; acc_co_tile_dbg<='0;
      for(stage=0; stage<REQ_LAT; stage=stage+1) begin
        meta_valid[stage] <= 1'b0;
        op_pipe[stage] <= '0;
        token_pipe[stage] <= '0;
        co_pipe[stage] <= '0;
      end
      for(lane=0; lane<LANES; lane=lane+1) begin
        acc_with_bias_dbg[lane]<='0; m_q[lane]<='0; s_q[lane]<='0;
      end
    end else begin
      // Bias / descriptor stage.
      acc_valid_dbg<=in_valid;
      if(in_valid) begin
        acc_op_dbg<=in_op; acc_token_id_dbg<=in_token_id; acc_co_tile_dbg<=in_co_tile;
        for(lane=0; lane<LANES; lane=lane+1) begin
          acc_with_bias_dbg[lane]<=acc_comb[lane];
          m_q[lane]<=m_comb[lane];
          s_q[lane]<=s_comb[lane];
        end
      end

      // Metadata follows the 7-cycle requant pipeline.
      meta_valid[0] <= acc_valid_dbg;
      if(acc_valid_dbg) begin
        op_pipe[0] <= acc_op_dbg;
        token_pipe[0] <= acc_token_id_dbg;
        co_pipe[0] <= acc_co_tile_dbg;
      end
      for(stage=1; stage<REQ_LAT; stage=stage+1) begin
        meta_valid[stage] <= meta_valid[stage-1];
        if(meta_valid[stage-1]) begin
          op_pipe[stage] <= op_pipe[stage-1];
          token_pipe[stage] <= token_pipe[stage-1];
          co_pipe[stage] <= co_pipe[stage-1];
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && (req_valid !== meta_valid[REQ_LAT-1]))
      $fatal(1, "qkv postproc metadata / data pipeline misalignment");
  end
`endif
endmodule
