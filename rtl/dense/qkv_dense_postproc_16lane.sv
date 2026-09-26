// ============================================================================
// qkv_dense_postproc_16lane.sv -- V5
// raw MAC + Q/K/V folded bias -> M/shift requant -> strict INT8.
// Metadata and lane data are registered in the same pipeline stage.
// ============================================================================
module qkv_dense_postproc_16lane #(
  parameter int LANES=16, parameter int COUT=128, parameter int TOKEN_ID_W=10,
  parameter [8*256-1:0] Q_BIAS_MEM = "q_folded_bias_i32.mem", parameter [8*256-1:0] Q_M_MEM = "q_requant_M_i32.mem", parameter [8*256-1:0] Q_SHIFT_MEM = "q_requant_shift_i16.mem",
  parameter [8*256-1:0] K_BIAS_MEM = "k_folded_bias_i32.mem", parameter [8*256-1:0] K_M_MEM = "k_requant_M_i32.mem", parameter [8*256-1:0] K_SHIFT_MEM = "k_requant_shift_i16.mem",
  parameter [8*256-1:0] V_BIAS_MEM = "v_folded_bias_i32.mem", parameter [8*256-1:0] V_M_MEM = "v_requant_M_i32.mem", parameter [8*256-1:0] V_SHIFT_MEM = "v_requant_shift_i16.mem"
)(
  input logic clk,input logic rst_n,
  input logic in_valid,input logic [1:0] in_op,
  input logic [TOKEN_ID_W-1:0] in_token_id,input logic [2:0] in_co_tile,
  input logic signed [63:0] mac_sum [0:LANES-1],
  output logic acc_valid_dbg,output logic [1:0] acc_op_dbg,
  output logic [TOKEN_ID_W-1:0] acc_token_id_dbg,output logic [2:0] acc_co_tile_dbg,
  output logic signed [63:0] acc_with_bias_dbg [0:LANES-1],
  output logic out_valid,output logic [1:0] out_op,
  output logic [TOKEN_ID_W-1:0] out_token_id,output logic [2:0] out_co_tile,
  output logic signed [7:0] out_data [0:LANES-1]
);
  import fixedpoint_pkg::*;
  localparam logic [1:0] OP_Q=2'd0, OP_K=2'd1, OP_V=2'd2;
  logic signed [31:0] q_bias[0:COUT-1],k_bias[0:COUT-1],v_bias[0:COUT-1];
  logic signed [31:0] q_m[0:COUT-1],k_m[0:COUT-1],v_m[0:COUT-1];
  logic signed [15:0] q_s[0:COUT-1],k_s[0:COUT-1],v_s[0:COUT-1];
  string romdir;
  string q_bf,q_mf,q_sf,k_bf,k_mf,k_sf,v_bf,v_mf,v_sf;
  logic signed [63:0] acc_comb [0:LANES-1];
  logic signed [7:0]  out_comb [0:LANES-1];

  initial begin
    q_bf=Q_BIAS_MEM; q_mf=Q_M_MEM; q_sf=Q_SHIFT_MEM;
    k_bf=K_BIAS_MEM; k_mf=K_M_MEM; k_sf=K_SHIFT_MEM;
    v_bf=V_BIAS_MEM; v_mf=V_M_MEM; v_sf=V_SHIFT_MEM;
`ifndef SYNTHESIS
    if ($value$plusargs("QKVROMDIR=%s",romdir)) begin
      q_bf={romdir,"/q_folded_bias_i32.mem"}; q_mf={romdir,"/q_requant_M_i32.mem"}; q_sf={romdir,"/q_requant_shift_i16.mem"};
      k_bf={romdir,"/k_folded_bias_i32.mem"}; k_mf={romdir,"/k_requant_M_i32.mem"}; k_sf={romdir,"/k_requant_shift_i16.mem"};
      v_bf={romdir,"/v_folded_bias_i32.mem"}; v_mf={romdir,"/v_requant_M_i32.mem"}; v_sf={romdir,"/v_requant_shift_i16.mem"};
    end
`endif
    $readmemh(q_bf,q_bias); $readmemh(q_mf,q_m); $readmemh(q_sf,q_s);
    $readmemh(k_bf,k_bias); $readmemh(k_mf,k_m); $readmemh(k_sf,k_s);
    $readmemh(v_bf,v_bias); $readmemh(v_mf,v_m); $readmemh(v_sf,v_s);
  end

  always_comb begin
    for (int lane_comb=0; lane_comb<LANES; lane_comb++) begin
      int channel_index;
      logic signed [31:0] bias_sel, m_sel;
      logic signed [15:0] s_sel;
      longint signed wide_sel;
      channel_index = $unsigned(in_co_tile)*LANES + lane_comb;
      bias_sel='0; m_sel='0; s_sel='0;
      if (channel_index < COUT) begin
        case (in_op)
          OP_Q: begin bias_sel=q_bias[channel_index]; m_sel=q_m[channel_index]; s_sel=q_s[channel_index]; end
          OP_K: begin bias_sel=k_bias[channel_index]; m_sel=k_m[channel_index]; s_sel=k_s[channel_index]; end
          OP_V: begin bias_sel=v_bias[channel_index]; m_sel=v_m[channel_index]; s_sel=v_s[channel_index]; end
          default: begin end
        endcase
      end
      acc_comb[lane_comb] = $signed(mac_sum[lane_comb]) + $signed(bias_sel);
      wide_sel = apply_mshift_i64(acc_comb[lane_comb], m_sel, $signed(s_sel));
      out_comb[lane_comb] = sat_s8(wide_sel);
    end
  end

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      acc_valid_dbg<=1'b0; acc_op_dbg<='0; acc_token_id_dbg<='0; acc_co_tile_dbg<='0;
      out_valid<=1'b0; out_op<='0; out_token_id<='0; out_co_tile<='0;
      for(int lane_rst=0; lane_rst<LANES; lane_rst++) begin
        acc_with_bias_dbg[lane_rst]<='0; out_data[lane_rst]<='0;
      end
    end else begin
      acc_valid_dbg<=in_valid; out_valid<=in_valid;
      if(in_valid) begin
        acc_op_dbg<=in_op; acc_token_id_dbg<=in_token_id; acc_co_tile_dbg<=in_co_tile;
        out_op<=in_op; out_token_id<=in_token_id; out_co_tile<=in_co_tile;
        for(int lane_ff=0; lane_ff<LANES; lane_ff++) begin
          acc_with_bias_dbg[lane_ff]<=acc_comb[lane_ff];
          out_data[lane_ff]<=out_comb[lane_ff];
        end
      end
    end
  end
endmodule
