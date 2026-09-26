`timescale 1ns/1ps
import post_swin_stage_cfg_pkg::*;
// ============================================================================
// post_swin_fpn_head_shared32_client.sv
//
// Runtime-programmed post-Swin FPN/head convolution client.  All 29 exported
// convolutions are executed sequentially through the SAME 32x32 MAC service.
// COUT=4 and COUT=1 prediction layers use the low lanes of the 32-lane result;
// no 32x4 or 32x1 PE arrays exist in this architecture.
//
// The tensor/weight/constant storage is intentionally outside this module.
// A simulation adapter can load the exported .mem assets one stage at a time;
// a production design can connect BRAM/URAM/DDR DMA adapters to the same ports.
// ============================================================================
module post_swin_fpn_head_shared32_client #(
  parameter int PE_K = 32,
  parameter int PE_N = 32,
  parameter int TOKEN_W = 12,
  parameter int TILE_W = 6,
  parameter logic [5:0] POST_ROUTE = 6'd48
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic abort,
  output logic busy,
  output logic done,

  output logic [4:0] stage_id,
  output logic       stage_prepare_req,
  input  logic       stage_prepare_done,
  output logic       stage_done_pulse,

  // Look-ahead contract for a two-bank DDR/BRAM weight cache. The request is
  // a one-cycle pulse issued as soon as the current stage acquires the MAC.
  output logic       stage_prefetch_req,
  output logic [4:0] stage_prefetch_id,
  output logic       p3_stream_active,
  output logic [2:0] p3_stream_phase,

  // Runtime memory-adapter context.
  output logic                         adapter_stream_valid,
  output logic [TOKEN_W-1:0]           adapter_token,
  output logic [TILE_W-1:0]            adapter_ci_tile,
  output logic [TILE_W-1:0]            adapter_co_tile,
  output logic                         adapter_weight_row_load,
  output logic [4:0]                   adapter_weight_row_index,
  input  logic signed [8:0]            adapter_input_vector [0:PE_K-1],
  input  logic signed [8:0]            adapter_weight_row_values [0:PE_N-1],

  output logic [TILE_W-1:0]            adapter_post_co_tile,
  input  logic signed [31:0]           adapter_bias [0:PE_N-1],
  input  logic signed [31:0]           adapter_multiplier [0:PE_N-1],
  input  logic signed [15:0]           adapter_shift [0:PE_N-1],

  output logic signed [7:0]            adapter_poly_code [0:PE_N-1],
  input  logic signed [7:0]            adapter_poly_value [0:PE_N-1],

  // Shared-MAC arbiter client interface.
  output logic                         client_req,
  input  logic                         client_grant,
  output logic [TOKEN_W-1:0]           client_cfg_tokens_m1,
  output logic [TILE_W-1:0]            client_cfg_k_tiles_m1,
  output logic [TILE_W-1:0]            client_cfg_n_tiles_m1,
  output logic signed [8:0]            client_input_vector [0:PE_K-1],
  output logic signed [8:0]            client_weight_row_values [0:PE_N-1],

  input  logic                         svc_stream_valid,
  input  logic [TOKEN_W-1:0]           svc_stream_token_id,
  input  logic [TILE_W-1:0]            svc_active_ci_tile,
  input  logic [TILE_W-1:0]            svc_active_co_tile,
  input  logic                         svc_weight_row_load,
  input  logic [4:0]                   svc_weight_row_index,
  input  logic                         svc_done,
  input  logic                         svc_raw_valid,
  input  logic [TOKEN_W-1:0]           svc_raw_token_id,
  input  logic [TILE_W-1:0]            svc_raw_co_tile,
  input  logic signed [63:0]           svc_raw_acc [0:PE_N-1],

  // Shared requant service producer/consumer interface.
  output logic                         post_in_valid,
  output logic [5:0]                   post_in_route,
  output logic [1:0]                   post_in_op,
  output logic [1:0]                   post_in_layer,
  output logic [11:0]                  post_in_token,
  output logic [6:0]                   post_in_co,
  output logic signed [63:0]           post_in_value [0:PE_N-1],
  output logic signed [31:0]           post_in_multiplier [0:PE_N-1],
  output logic signed [15:0]           post_in_shift [0:PE_N-1],

  input  logic                         post_out_valid,
  input  logic [5:0]                   post_out_route,
  input  logic [1:0]                   post_out_op,
  input  logic [1:0]                   post_out_layer,
  input  logic [11:0]                  post_out_token,
  input  logic [6:0]                   post_out_co,
  input  logic signed [7:0]            post_out_code [0:PE_N-1],

  // One 32-lane vector per completed output tile.
  output logic                         out_valid,
  output logic [4:0]                   out_stage_id,
  output logic [TOKEN_W-1:0]           out_token,
  output logic [TILE_W-1:0]            out_co_tile,
  output logic [31:0]                  out_lane_mask,
  output logic signed [7:0]            out_data [0:PE_N-1],
  output logic [13:0]                  stage_vector_count
);
  typedef enum logic [3:0] {
    C_IDLE, C_PREP, C_REQ, C_RUN, C_DRAIN, C_NEXT, C_DONE, C_ABORT
  } cstate_t;
  cstate_t state_q;
  logic svc_done_seen_q;
  logic [13:0] expected_vectors;
  logic result_accept;
  logic next_stage_valid;
  logic [4:0] next_stage_id;
  logic next_is_p3;

  post_swin_p3_stream_scheduler u_p3_stream_scheduler (
    .current_stage_id(stage_id),
    .next_valid(next_stage_valid),
    .next_stage_id(next_stage_id),
    .p3_stream_active(p3_stream_active),
    .p3_stream_phase(p3_stream_phase),
    .next_is_p3(next_is_p3)
  );

  assign stage_prefetch_id = next_stage_id;

  assign expected_vectors = stage_expected_vectors(stage_id);
  assign client_cfg_tokens_m1  = stage_tokens_m1(stage_id);
  assign client_cfg_k_tiles_m1 = stage_k_tiles_m1(stage_id);
  assign client_cfg_n_tiles_m1 = stage_n_tiles_m1(stage_id);

  assign stage_prepare_req = (state_q == C_PREP);
  assign client_req = (state_q == C_REQ) ||
                      ((state_q == C_RUN) && !svc_done_seen_q);

  assign adapter_stream_valid   = svc_stream_valid && client_grant;
  assign adapter_token          = svc_stream_token_id;
  assign adapter_ci_tile        = svc_active_ci_tile;
  assign adapter_co_tile        = svc_active_co_tile;
  assign adapter_weight_row_load  = svc_weight_row_load && client_grant;
  assign adapter_weight_row_index = svc_weight_row_index;
  assign adapter_post_co_tile     = svc_raw_co_tile;

  always_comb begin
    for (int lane = 0; lane < PE_K; lane = lane + 1)
      client_input_vector[lane] = adapter_input_vector[lane];
    for (int lane = 0; lane < PE_N; lane = lane + 1)
      client_weight_row_values[lane] = adapter_weight_row_values[lane];
  end

  always_comb begin
    post_in_valid = svc_raw_valid && client_grant &&
                    ((state_q == C_RUN) || (state_q == C_DRAIN));
    post_in_route = POST_ROUTE;
    post_in_op    = 2'd0;
    post_in_layer = stage_id[1:0];
    post_in_token = svc_raw_token_id;
    post_in_co    = {1'b0, svc_raw_co_tile};
    for (int lane = 0; lane < PE_N; lane = lane + 1) begin
      post_in_value[lane]      = $signed(svc_raw_acc[lane]) +
                                 $signed(adapter_bias[lane]);
      post_in_multiplier[lane] = adapter_multiplier[lane];
      post_in_shift[lane]      = adapter_shift[lane];
      adapter_poly_code[lane]  = post_out_code[lane];
    end
  end

  assign result_accept = post_out_valid && (post_out_route == POST_ROUTE) &&
                         ((state_q == C_RUN) || (state_q == C_DRAIN));

  always_comb begin
    out_valid     = result_accept;
    out_stage_id  = stage_id;
    out_token     = post_out_token;
    out_co_tile   = post_out_co[TILE_W-1:0];
    out_lane_mask = (post_out_co[TILE_W-1:0] == stage_n_tiles_m1(stage_id))
                    ? stage_last_lane_mask(stage_id) : 32'hffff_ffff;
    for (int lane = 0; lane < PE_N; lane = lane + 1) begin
      if (stage_use_silu(stage_id)) out_data[lane] = adapter_poly_value[lane];
      else                          out_data[lane] = post_out_code[lane];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= C_IDLE;
      stage_id <= '0;
      stage_vector_count <= '0;
      svc_done_seen_q <= 1'b0;
      stage_done_pulse <= 1'b0;
      stage_prefetch_req <= 1'b0;
      busy <= 1'b0;
      done <= 1'b0;
    end else begin
      stage_done_pulse <= 1'b0;
      stage_prefetch_req <= 1'b0;
      done <= 1'b0;
      if (abort) begin
        state_q <= C_ABORT;
        busy <= 1'b0;
      end else begin
        case (state_q)
          C_IDLE: begin
            busy <= 1'b0;
            if (start) begin
              stage_id <= 5'd0;
              stage_vector_count <= '0;
              svc_done_seen_q <= 1'b0;
              busy <= 1'b1;
              state_q <= C_PREP;
            end
          end
          C_PREP: begin
            if (stage_prepare_done) state_q <= C_REQ;
          end
          C_REQ: begin
            if (client_grant) begin
              // Start loading the next stage while the current stage uses the
              // shared MAC. A production cache may ignore this pulse when the
              // requested stage is already resident.
              if (next_stage_valid) stage_prefetch_req <= 1'b1;
              state_q <= C_RUN;
            end
          end
          C_RUN: begin
            if (svc_done) svc_done_seen_q <= 1'b1;
            if (result_accept) begin
              stage_vector_count <= stage_vector_count + 1'b1;
              if ((stage_vector_count + 1'b1) == expected_vectors)
                state_q <= C_DRAIN;
            end
          end
          C_DRAIN: begin
            if (svc_done) svc_done_seen_q <= 1'b1;
            if (svc_done_seen_q || svc_done) begin
              stage_done_pulse <= 1'b1;
              state_q <= C_NEXT;
            end
          end
          C_NEXT: begin
            if (!next_stage_valid) begin
              state_q <= C_DONE;
            end else begin
              stage_id <= next_stage_id;
              stage_vector_count <= '0;
              svc_done_seen_q <= 1'b0;
              state_q <= C_PREP;
            end
          end
          C_DONE: begin
            busy <= 1'b0;
            done <= 1'b1;
            if (!start) state_q <= C_IDLE;
          end
          C_ABORT: begin
            busy <= 1'b0;
            if (!abort && !start) state_q <= C_IDLE;
          end
          default: state_q <= C_IDLE;
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  initial $display("[POST_SHARED32_V64_P3STREAM_COMPILED] %m ONE_32X32_PADDED_PREDICTION_LANES");
  always_ff @(posedge clk) begin
    if (rst_n && result_accept && (stage_vector_count >= expected_vectors))
      $fatal(1, "post_swin client: excess output vectors stage=%0d", stage_id);
    if (rst_n && (state_q == C_DRAIN) &&
        (stage_vector_count != expected_vectors))
      $fatal(1, "post_swin client: bad vector count stage=%0d got=%0d expected=%0d",
             stage_id, stage_vector_count, expected_vectors);
  end
`endif
endmodule
