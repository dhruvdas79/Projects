`timescale 1ns/1ps
// Runtime-shape dense client used by the single physical Swin engine.
// Weights and postprocess vectors come from an external synthesizable cache.
module swin_runtime_dense_client #(
  parameter int PE_K=32,
  parameter int PE_N=32,
  parameter int ROUTE_ID=1
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic [2:0] block_id,
  input  logic [2:0] dense_stage,
  input  logic [11:0] cfg_tokens_m1_i,
  input  logic [3:0] cfg_k_tiles_m1_i,
  input  logic [3:0] cfg_n_tiles_m1_i,
  output logic busy,
  output logic done,

  output logic src_req_valid,
  output logic [11:0] src_req_token,
  output logic [3:0] src_req_ci_tile,
  input  logic src_resp_valid,
  input  logic signed [255:0] src_resp_data,

  output logic weight_req_valid,
  output logic [2:0] weight_req_block,
  output logic [2:0] weight_req_stage,
  output logic [3:0] weight_req_ci_tile,
  output logic [3:0] weight_req_co_tile,
  output logic [4:0] weight_req_row,
  input  logic weight_resp_valid,
  input  logic signed [255:0] weight_resp_data,

  output logic postparam_req_valid,
  output logic [2:0] postparam_req_block,
  output logic [2:0] postparam_req_stage,
  output logic [3:0] postparam_req_co_tile,
  input  logic postparam_resp_valid,
  input  logic signed [31:0] postparam_bias [0:PE_N-1],
  input  logic signed [31:0] postparam_multiplier [0:PE_N-1],
  input  logic signed [15:0] postparam_shift [0:PE_N-1],

  output logic out_valid,
  output logic [2:0] out_stage,
  output logic [11:0] out_token,
  output logic [3:0] out_co_tile,
  output logic signed [255:0] out_data,

  output logic client_req,
  input  logic client_grant,
  output logic [11:0] client_cfg_tokens_m1,
  output logic [3:0] client_cfg_k_tiles_m1,
  output logic [3:0] client_cfg_n_tiles_m1,
  output logic client_input_valid,
  output logic client_weight_valid,
  output logic signed [8:0] client_input_vector [0:PE_K-1],
  output logic signed [8:0] client_weight_row_values [0:PE_N-1],
  input  logic svc_stream_valid,
  input  logic [11:0] svc_stream_token_id,
  input  logic [3:0] svc_active_ci_tile,
  input  logic [3:0] svc_active_co_tile,
  input  logic svc_weight_row_load,
  input  logic [4:0] svc_weight_row_index,
  input  logic svc_done,
  input  logic svc_raw_valid,
  input  logic [11:0] svc_raw_token_id,
  input  logic [3:0] svc_raw_co_tile,
  input  logic signed [63:0] svc_raw_acc [0:PE_N-1],

  output logic post_in_valid,
  output logic [5:0] post_in_route,
  output logic [1:0] post_in_op,
  output logic [1:0] post_in_layer,
  output logic [11:0] post_in_token,
  output logic [6:0] post_in_co,
  output logic signed [63:0] post_in_value [0:PE_N-1],
  output logic signed [31:0] post_in_multiplier [0:PE_N-1],
  output logic signed [15:0] post_in_shift [0:PE_N-1],
  input  logic post_out_valid,
  input  logic [5:0] post_out_route,
  input  logic [1:0] post_out_op,
  input  logic [1:0] post_out_layer,
  input  logic [11:0] post_out_token,
  input  logic [6:0] post_out_co,
  input  logic signed [7:0] post_out_code [0:PE_N-1]
);
  typedef enum logic [2:0] {D_IDLE,D_REQ,D_RUN,D_DRAIN,D_DONE} dstate_t;
  dstate_t state_q;
  logic [2:0] block_q,stage_q;
  logic [11:0] tokens_m1_q;
  logic [3:0] ktiles_m1_q,ntiles_m1_q;
  logic [15:0] expected_q,received_q;
  logic svc_finished_q;

  logic raw_pipe_valid_q;
  logic [11:0] raw_token_q;
  logic [3:0] raw_co_q;
  logic [2:0] raw_stage_q;
  logic signed [63:0] raw_value_q [0:PE_N-1];

  // One-row lookahead makes a one-cycle external cache sustain one weight
  // row per clock after the initial fill.
  logic weight_armed_q;
  logic [2:0] last_weight_block_q,last_weight_stage_q;
  logic [3:0] last_weight_ci_q,last_weight_co_q;
  logic [4:0] last_weight_row_q;
  logic [4:0] weight_request_row;
  logic weight_request_new;

  assign client_cfg_tokens_m1 = tokens_m1_q;
  assign client_cfg_k_tiles_m1 = ktiles_m1_q;
  assign client_cfg_n_tiles_m1 = ntiles_m1_q;

  // V1.1 synchronous-BRAM source prefetch.
  // First request gets token 0. While token N is consumed, token N+1 is
  // requested in the same cycle, sustaining one token/cycle after startup.
  logic src_stream_active;
  assign src_stream_active = (state_q==D_RUN) && client_grant && svc_stream_valid;
  assign src_req_valid = src_stream_active &&
      (!src_resp_valid || (svc_stream_token_id < tokens_m1_q));
  assign src_req_token = src_resp_valid ?
      (svc_stream_token_id + 1'b1) : svc_stream_token_id;
  assign src_req_ci_tile = svc_active_ci_tile;
  assign client_input_valid = src_stream_active && src_resp_valid;

  always_comb begin
    if (weight_resp_valid && svc_weight_row_load && (svc_weight_row_index < PE_K-1))
      weight_request_row = svc_weight_row_index + 1'b1;
    else
      weight_request_row = svc_weight_row_index;
    weight_request_new = !weight_armed_q ||
      (last_weight_block_q != block_q) || (last_weight_stage_q != stage_q) ||
      (last_weight_ci_q != svc_active_ci_tile) || (last_weight_co_q != svc_active_co_tile) ||
      (last_weight_row_q != weight_request_row);
  end
  assign weight_req_valid = (state_q==D_RUN) && client_grant && svc_weight_row_load && weight_request_new;
  assign weight_req_block = block_q;
  assign weight_req_stage = stage_q;
  assign weight_req_ci_tile = svc_active_ci_tile;
  assign weight_req_co_tile = svc_active_co_tile;
  assign weight_req_row = weight_request_row;
  assign client_weight_valid = weight_resp_valid;

  assign postparam_req_valid = (state_q==D_RUN || state_q==D_DRAIN) && client_grant && svc_raw_valid;
  assign postparam_req_block = block_q;
  assign postparam_req_stage = stage_q;
  assign postparam_req_co_tile = svc_raw_co_tile;

  always_comb begin
    for (int lane=0; lane<PE_K; lane=lane+1)
      client_input_vector[lane] = {src_resp_data[lane*8+7],src_resp_data[lane*8 +: 8]};
    for (int lane=0; lane<PE_N; lane=lane+1)
      client_weight_row_values[lane] = {weight_resp_data[lane*8+7],weight_resp_data[lane*8 +: 8]};

    post_in_valid = raw_pipe_valid_q && postparam_resp_valid;
    post_in_route = ROUTE_ID[5:0];
    post_in_op = raw_stage_q[1:0];
    post_in_layer = {1'b0,raw_stage_q[2]};
    post_in_token = raw_token_q;
    post_in_co = {3'b000,raw_co_q};
    for (int lane=0; lane<PE_N; lane=lane+1) begin
      post_in_value[lane] = raw_value_q[lane] +
        $signed({{32{postparam_bias[lane][31]}},postparam_bias[lane]});
      post_in_multiplier[lane] = postparam_multiplier[lane];
      post_in_shift[lane] = postparam_shift[lane];
    end

    out_valid = post_out_valid && (post_out_route==ROUTE_ID[5:0]);
    out_stage = {post_out_layer[0],post_out_op};
    out_token = post_out_token;
    out_co_tile = post_out_co[3:0];
    out_data = '0;
    for (int lane=0; lane<PE_N; lane=lane+1)
      out_data[lane*8 +: 8] = post_out_code[lane];

    busy = (state_q!=D_IDLE) && (state_q!=D_DONE);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q<=D_IDLE; done<=1'b0; client_req<=1'b0;
      block_q<='0;stage_q<='0;tokens_m1_q<='0;ktiles_m1_q<='0;ntiles_m1_q<='0;
      expected_q<='0;received_q<='0;svc_finished_q<=1'b0;
      raw_pipe_valid_q<=1'b0;raw_token_q<='0;raw_co_q<='0;raw_stage_q<='0;
      weight_armed_q<=1'b0;last_weight_block_q<='0;last_weight_stage_q<='0;
      last_weight_ci_q<='0;last_weight_co_q<='0;last_weight_row_q<='0;
      for (int lane=0;lane<PE_N;lane=lane+1) raw_value_q[lane]<='0;
    end else begin
      done<=1'b0;
      raw_pipe_valid_q<=postparam_req_valid;
      if (postparam_req_valid) begin
        raw_token_q<=svc_raw_token_id;raw_co_q<=svc_raw_co_tile;raw_stage_q<=stage_q;
        for (int lane=0;lane<PE_N;lane=lane+1) raw_value_q[lane]<=svc_raw_acc[lane];
      end

      if (!svc_weight_row_load) weight_armed_q<=1'b0;
      else if (weight_req_valid) begin
        weight_armed_q<=1'b1;
        last_weight_block_q<=block_q;last_weight_stage_q<=stage_q;
        last_weight_ci_q<=svc_active_ci_tile;last_weight_co_q<=svc_active_co_tile;
        last_weight_row_q<=weight_request_row;
      end

      if (out_valid) received_q<=received_q+1'b1;
      if (svc_done && client_grant) svc_finished_q<=1'b1;

      case (state_q)
        D_IDLE: begin
          client_req<=1'b0;received_q<='0;svc_finished_q<=1'b0;
          if (start) begin
            block_q<=block_id;stage_q<=dense_stage;
            tokens_m1_q<=cfg_tokens_m1_i;ktiles_m1_q<=cfg_k_tiles_m1_i;ntiles_m1_q<=cfg_n_tiles_m1_i;
            expected_q<=($unsigned(cfg_tokens_m1_i)+1)*($unsigned(cfg_n_tiles_m1_i)+1);
            client_req<=1'b1;state_q<=D_REQ;
          end
        end
        D_REQ: begin
          client_req<=1'b1;
          if (client_grant) begin client_req<=1'b0;state_q<=D_RUN;end
        end
        D_RUN: if (svc_done && client_grant) state_q<=D_DRAIN;
        D_DRAIN: if (svc_finished_q && (received_q==expected_q)) state_q<=D_DONE;
        D_DONE: begin done<=1'b1;state_q<=D_IDLE;end
        default: state_q<=D_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && weight_resp_valid && !weight_armed_q)
      $fatal(1,"single-engine dense weight response without an armed cache request");
    if (rst_n && postparam_resp_valid && !raw_pipe_valid_q)
      $fatal(1,"single-engine dense postparam response without raw vector");
  end
`endif
endmodule
