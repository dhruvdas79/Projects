`timescale 1ns/1ps
// ============================================================================
// projection_swin_fpn_head_shared32_singleengine_continuous_top.sv
//
// Continuous Projection -> one reusable physical Swin engine -> FPN -> heads.
// Six logical blocks execute sequentially on the same engine and the same two
// max-P3 ping-pong frame buffers.
// The V5 core remains the single owner of the global shared 32x32 MAC service;
// this wrapper replaces only the profiled post-Swin input adapter with the
// synthesizable tensor graph/URAM adapter.
//
// Weights, bias, requant constants and 256-entry SiLU values remain on a clean
// external asset-memory interface.  In simulation they are supplied by the
// simulation-only asset adapter.  On FPGA they should be supplied by BRAM/URAM
// caches or a DDR/AXI DMA controller.
// ============================================================================
module projection_swin_fpn_head_shared32_singleengine_continuous_top #(
  parameter int PE_K = 32,
  parameter int PE_N = 32
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic abort,

  // Projection activation/weight memory interface.
  output logic [1:0]          proj_mem_layer_id,
  output logic                proj_stream_valid,
  output logic [11:0]         proj_stream_pixel_id,
  output logic [3:0]          proj_active_ci_tile,
  output logic [2:0]          proj_active_co_tile,
  output logic                proj_weight_row_load,
  output logic [4:0]          proj_weight_row_index,
  input  logic signed [7:0]   proj_input_vector_i [0:PE_K-1],
  input  logic signed [7:0]   proj_weight_row_values_i [0:PE_N-1],

  // Projection postprocess constants.
  output logic                proj_post_req_valid,
  output logic [1:0]          proj_post_layer_id,
  output logic [6:0]          proj_post_channel_base,
  input  logic signed [31:0]  proj_bias_vec_i [0:PE_N-1],
  input  logic signed [31:0]  proj_requant_m_vec_i [0:PE_N-1],
  input  logic        [15:0]  proj_requant_shift_vec_i [0:PE_N-1],
  input  logic signed [31:0]  proj_poly_coeff_i [0:31],

  // Optional final Swin readback/debug interface.  It is automatically
  // isolated while the continuous fusion engine owns the same read ports.
  input  logic                p4_out_rd_en,
  input  logic [9:0]          p4_out_rd_pixel,
  input  logic [2:0]          p4_out_rd_co_tile,
  output logic                p4_out_rd_valid,
  output logic signed [127:0] p4_out_rd_data,

  input  logic                p3_out_rd_en,
  input  logic [11:0]         p3_out_rd_pixel,
  input  logic [2:0]          p3_out_rd_co_tile,
  output logic                p3_out_rd_valid,
  output logic signed [127:0] p3_out_rd_data,

  // P5 projection debug stream; also captured internally by the tensor graph.
  output logic                p5_proj_out_valid,
  output logic [11:0]         p5_proj_out_pixel,
  output logic [1:0]          p5_proj_out_co_tile,
  output logic signed [255:0] p5_proj_out_data,

  // Runtime Swin asset-cache interface. Synthesis RTL contains no file I/O;
  // connect these ports to BRAM caches and an AXI/DDR prefetch controller.
  output logic                swin_weight_req_valid,
  output logic [2:0]          swin_weight_req_block,
  output logic [2:0]          swin_weight_req_stage,
  output logic [3:0]          swin_weight_req_ci_tile,
  output logic [3:0]          swin_weight_req_co_tile,
  output logic [4:0]          swin_weight_req_row,
  input  logic                swin_weight_resp_valid,
  input  logic signed [255:0] swin_weight_resp_data,
  output logic                swin_postparam_req_valid,
  output logic [2:0]          swin_postparam_req_block,
  output logic [2:0]          swin_postparam_req_stage,
  output logic [3:0]          swin_postparam_req_co_tile,
  input  logic                swin_postparam_resp_valid,
  input  logic signed [31:0]  swin_postparam_bias [0:31],
  input  logic signed [31:0]  swin_postparam_multiplier [0:31],
  input  logic signed [15:0]  swin_postparam_shift [0:31],
  output logic                swin_norm_req_valid,
  output logic [2:0]          swin_norm_req_block,
  output logic                swin_norm_req_sel,
  output logic [1:0]          swin_norm_req_co_tile,
  output logic signed [7:0]   swin_norm_req_code [0:31],
  input  logic                swin_norm_resp_valid,
  input  logic signed [7:0]   swin_norm_resp_value [0:31],
  output logic                swin_poly_req_valid,
  output logic [2:0]          swin_poly_req_block,
  output logic signed [7:0]   swin_poly_req_code [0:31],
  input  logic                swin_poly_resp_valid,
  input  logic signed [7:0]   swin_poly_resp_value [0:31],
  output logic                swin_resparam_req_valid,
  output logic [2:0]          swin_resparam_req_block,
  output logic                swin_resparam_req_sel,
  input  logic                swin_resparam_resp_valid,
  input  logic [31:0]         swin_resparam_a_mult,
  input  logic signed [15:0]  swin_resparam_a_shift,
  input  logic [31:0]         swin_resparam_b_mult,
  input  logic signed [15:0]  swin_resparam_b_shift,
  output logic                swin_relpos_req_valid,
  output logic [2:0]          swin_relpos_req_block,
  output logic [2:0]          swin_relpos_req_head,
  output logic [4:0]          swin_relpos_req_query,
  input  logic                swin_relpos_resp_valid,
  input  logic signed [15:0]  swin_relpos_resp_bias [0:31],
  output logic                swin_exp_req_valid,
  output logic [2:0]          swin_exp_req_block,
  output logic signed [7:0]   swin_exp_req_delta [0:31],
  input  logic                swin_exp_resp_valid,
  input  logic [15:0]         swin_exp_resp_value [0:31],
  output logic [2:0]          swin_active_block,
  output logic [5:0]          swin_engine_state,
  output logic [31:0]         swin_block_cycle_count,

  // Post-Swin stage asset-memory interface.  This interface carries no input
  // activation tensor; all activations come from the continuous graph adapter.
  output logic [4:0]          post_stage_id,
  output logic                post_stage_prepare_req,
  input  logic                post_weight_prepare_done,
  output logic                post_stage_done_pulse,
  // One-cycle next-stage look-ahead for a DDR/BRAM ping-pong weight cache.
  output logic                post_stage_prefetch_req,
  output logic [4:0]          post_stage_prefetch_id,
  output logic                p3_head_stream_active,
  output logic [2:0]          p3_head_stream_phase,
  output logic                post_adapter_stream_valid,
  output logic [11:0]         post_adapter_token,
  output logic [5:0]          post_adapter_ci_tile,
  output logic [5:0]          post_adapter_co_tile,
  output logic                post_adapter_weight_row_load,
  output logic [4:0]          post_adapter_weight_row_index,
  input  logic signed [8:0]   post_adapter_weight_row_values [0:PE_N-1],
  output logic [5:0]          post_adapter_post_co_tile,
  input  logic signed [31:0]  post_adapter_bias [0:PE_N-1],
  input  logic signed [31:0]  post_adapter_multiplier [0:PE_N-1],
  input  logic signed [15:0]  post_adapter_shift [0:PE_N-1],
  output logic signed [7:0]   post_adapter_poly_code [0:PE_N-1],
  input  logic signed [7:0]   post_adapter_poly_value [0:PE_N-1],

  // All post-Swin stage outputs, including padded 4/1-lane predictions.
  output logic                fpn_head_out_valid,
  output logic [4:0]          fpn_head_out_stage_id,
  output logic [11:0]         fpn_head_out_token,
  output logic [5:0]          fpn_head_out_co_tile,
  output logic [31:0]         fpn_head_out_lane_mask,
  output logic signed [7:0]   fpn_head_out_data [0:PE_N-1],
  output logic [13:0]         post_stage_vector_count,

  // Controller/status.
  output logic busy,
  output logic done,
  output logic aborted,
  output logic [3:0] state_code,
  output logic projection_busy,
  output logic projection_done,
  output logic p4_swin_busy,
  output logic p4_swin_done,
  output logic p3_swin_busy,
  output logic p3_swin_done,
  output logic post_busy,
  output logic post_done,

  // Continuous graph diagnostics.
  output logic fusion_busy,
  output logic [1:0] fusion_kind,
  output logic [13:0] fusion_word_index,
  output logic [13:0] p5_capture_count,
  output logic continuous_graph_error
);
  logic tensor_prepare_done;
  logic core_stage_prepare_done;
  logic signed [8:0] continuous_input_vector [0:PE_K-1];

  logic core_p4_rd_en;
  logic [9:0] core_p4_rd_pixel;
  logic [2:0] core_p4_rd_co_tile;
  logic core_p4_rd_valid;
  logic signed [127:0] core_p4_rd_data;
  logic tensor_p4_rd_en;
  logic [9:0] tensor_p4_rd_pixel;
  logic [2:0] tensor_p4_rd_co_tile;

  logic core_p3_rd_en;
  logic [11:0] core_p3_rd_pixel;
  logic [2:0] core_p3_rd_co_tile;
  logic core_p3_rd_valid;
  logic signed [127:0] core_p3_rd_data;
  logic tensor_p3_rd_en;
  logic [11:0] tensor_p3_rd_pixel;
  logic [2:0] tensor_p3_rd_co_tile;

  assign core_stage_prepare_done = tensor_prepare_done & post_weight_prepare_done;

  // Tensor fusion owns the final-Swin read ports only while active.
  always_comb begin
    if (fusion_busy) begin
      core_p4_rd_en      = tensor_p4_rd_en;
      core_p4_rd_pixel   = tensor_p4_rd_pixel;
      core_p4_rd_co_tile = tensor_p4_rd_co_tile;
      core_p3_rd_en      = tensor_p3_rd_en;
      core_p3_rd_pixel   = tensor_p3_rd_pixel;
      core_p3_rd_co_tile = tensor_p3_rd_co_tile;
    end else begin
      core_p4_rd_en      = p4_out_rd_en;
      core_p4_rd_pixel   = p4_out_rd_pixel;
      core_p4_rd_co_tile = p4_out_rd_co_tile;
      core_p3_rd_en      = p3_out_rd_en;
      core_p3_rd_pixel   = p3_out_rd_pixel;
      core_p3_rd_co_tile = p3_out_rd_co_tile;
    end
  end

  assign p4_out_rd_valid = (!fusion_busy) && core_p4_rd_valid;
  assign p4_out_rd_data  = core_p4_rd_data;
  assign p3_out_rd_valid = (!fusion_busy) && core_p3_rd_valid;
  assign p3_out_rd_data  = core_p3_rd_data;

  projection_swin_fpn_head_shared32_singleengine_top #(
    .PE_K(PE_K), .PE_N(PE_N)
  ) u_core (
    .clk, .rst_n, .start, .abort,
    .proj_mem_layer_id,
    .proj_stream_valid,
    .proj_stream_pixel_id,
    .proj_active_ci_tile,
    .proj_active_co_tile,
    .proj_weight_row_load,
    .proj_weight_row_index,
    .proj_input_vector_i,
    .proj_weight_row_values_i,
    .proj_post_req_valid,
    .proj_post_layer_id,
    .proj_post_channel_base,
    .proj_bias_vec_i,
    .proj_requant_m_vec_i,
    .proj_requant_shift_vec_i,
    .proj_poly_coeff_i,
    .p4_out_rd_en(core_p4_rd_en),
    .p4_out_rd_pixel(core_p4_rd_pixel),
    .p4_out_rd_co_tile(core_p4_rd_co_tile),
    .p4_out_rd_valid(core_p4_rd_valid),
    .p4_out_rd_data(core_p4_rd_data),
    .p3_out_rd_en(core_p3_rd_en),
    .p3_out_rd_pixel(core_p3_rd_pixel),
    .p3_out_rd_co_tile(core_p3_rd_co_tile),
    .p3_out_rd_valid(core_p3_rd_valid),
    .p3_out_rd_data(core_p3_rd_data),
    .p5_proj_out_valid,
    .p5_proj_out_pixel,
    .p5_proj_out_co_tile,
    .p5_proj_out_data,
    .swin_weight_req_valid,
    .swin_weight_req_block,
    .swin_weight_req_stage,
    .swin_weight_req_ci_tile,
    .swin_weight_req_co_tile,
    .swin_weight_req_row,
    .swin_weight_resp_valid,
    .swin_weight_resp_data,
    .swin_postparam_req_valid,
    .swin_postparam_req_block,
    .swin_postparam_req_stage,
    .swin_postparam_req_co_tile,
    .swin_postparam_resp_valid,
    .swin_postparam_bias,
    .swin_postparam_multiplier,
    .swin_postparam_shift,
    .swin_norm_req_valid,
    .swin_norm_req_block,
    .swin_norm_req_sel,
    .swin_norm_req_co_tile,
    .swin_norm_req_code,
    .swin_norm_resp_valid,
    .swin_norm_resp_value,
    .swin_poly_req_valid,
    .swin_poly_req_block,
    .swin_poly_req_code,
    .swin_poly_resp_valid,
    .swin_poly_resp_value,
    .swin_resparam_req_valid,
    .swin_resparam_req_block,
    .swin_resparam_req_sel,
    .swin_resparam_resp_valid,
    .swin_resparam_a_mult,
    .swin_resparam_a_shift,
    .swin_resparam_b_mult,
    .swin_resparam_b_shift,
    .swin_relpos_req_valid,
    .swin_relpos_req_block,
    .swin_relpos_req_head,
    .swin_relpos_req_query,
    .swin_relpos_resp_valid,
    .swin_relpos_resp_bias,
    .swin_exp_req_valid,
    .swin_exp_req_block,
    .swin_exp_req_delta,
    .swin_exp_resp_valid,
    .swin_exp_resp_value,
    .swin_active_block,
    .swin_engine_state,
    .swin_block_cycle_count,
    .post_stage_id,
    .post_stage_prepare_req,
    .post_stage_prepare_done(core_stage_prepare_done),
    .post_stage_done_pulse,
    .post_stage_prefetch_req,
    .post_stage_prefetch_id,
    .p3_head_stream_active,
    .p3_head_stream_phase,
    .post_adapter_stream_valid,
    .post_adapter_token,
    .post_adapter_ci_tile,
    .post_adapter_co_tile,
    .post_adapter_weight_row_load,
    .post_adapter_weight_row_index,
    .post_adapter_input_vector(continuous_input_vector),
    .post_adapter_weight_row_values,
    .post_adapter_post_co_tile,
    .post_adapter_bias,
    .post_adapter_multiplier,
    .post_adapter_shift,
    .post_adapter_poly_code,
    .post_adapter_poly_value,
    .fpn_head_out_valid,
    .fpn_head_out_stage_id,
    .fpn_head_out_token,
    .fpn_head_out_co_tile,
    .fpn_head_out_lane_mask,
    .fpn_head_out_data,
    .post_stage_vector_count,
    .busy,
    .done,
    .aborted,
    .state_code,
    .projection_busy,
    .projection_done,
    .p4_swin_busy,
    .p4_swin_done,
    .p3_swin_busy,
    .p3_swin_done,
    .post_busy,
    .post_done
  );

  post_swin_continuous_tensor_adapter #(
    .PE_K(PE_K), .PE_N(PE_N), .FUSION_LANES(4)
  ) u_tensor_graph (
    .clk,
    .rst_n,
    .run_start(start),
    .stage_id(post_stage_id),
    .stage_prepare_req(post_stage_prepare_req),
    .tensor_prepare_done,
    .adapter_stream_valid(post_adapter_stream_valid),
    .adapter_token(post_adapter_token),
    .adapter_ci_tile(post_adapter_ci_tile),
    .adapter_weight_row_load(post_adapter_weight_row_load),
    .adapter_weight_row_index(post_adapter_weight_row_index),
    .adapter_input_vector(continuous_input_vector),
    .out_valid(fpn_head_out_valid),
    .out_stage_id(fpn_head_out_stage_id),
    .out_token(fpn_head_out_token),
    .out_co_tile(fpn_head_out_co_tile),
    .out_lane_mask(fpn_head_out_lane_mask),
    .out_data(fpn_head_out_data),
    .p4_src_rd_en(tensor_p4_rd_en),
    .p4_src_rd_pixel(tensor_p4_rd_pixel),
    .p4_src_rd_co_tile(tensor_p4_rd_co_tile),
    .p4_src_rd_valid(core_p4_rd_valid),
    .p4_src_rd_data(core_p4_rd_data),
    .p3_src_rd_en(tensor_p3_rd_en),
    .p3_src_rd_pixel(tensor_p3_rd_pixel),
    .p3_src_rd_co_tile(tensor_p3_rd_co_tile),
    .p3_src_rd_valid(core_p3_rd_valid),
    .p3_src_rd_data(core_p3_rd_data),
    .p5_proj_valid(p5_proj_out_valid),
    .p5_proj_pixel(p5_proj_out_pixel),
    .p5_proj_co_tile(p5_proj_out_co_tile),
    .p5_proj_data(p5_proj_out_data),
    .fusion_busy,
    .fusion_kind,
    .fusion_word_index,
    .p5_capture_count,
    .graph_error(continuous_graph_error)
  );

`ifndef SYNTHESIS
  initial $display("[CONTINUOUS_UNIFIED_V63_SINGLE_ENGINE_COMPILED] %m 200MHZ_TARGET REAL_INTERSTAGE_GRAPH");
  always_ff @(posedge clk) begin
    if (rst_n && post_stage_prepare_req && core_stage_prepare_done && continuous_graph_error)
      $fatal(1, "continuous top released a stage with graph_error");
  end
`endif
endmodule
