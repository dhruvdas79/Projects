`timescale 1ns/1ps
// ============================================================================
// P3/P4/P5 projection client using one shared MAC and one global requant pipe.
//
// v3.1 projection-X fix:
//   * raw MAC result, bias, multiplier, shift and metadata are captured in one
//     register stage before entering the global requant service;
//   * projection PolySiLU uses one deterministic embedded three-profile LUT
//     module instead of 32 generated-block $readmemh instances;
//   * simulation assertions identify the first stage that produces X.
//
// v3.3 projection-count guard:
//   * each layer advances only after the exact number of 32-lane output vectors
//     has returned from the global requant + projection SiLU path;
//   * a premature MAC-service done pulse can no longer skip projection outputs.
//
// The legacy LUT filename parameters are retained for interface compatibility;
// active LUT values are embedded from the same generated_projection files.
// ============================================================================
module projection_p3p4p5_shared32_client #(
    parameter int PE_K=32,
    parameter int PE_N=32,
    parameter int DATA_W=8,
    parameter int SVC_DATA_W=9,
    parameter int RAW_W=64,
    parameter int PIX_ID_W=12,
    parameter int POLY_DRAIN_CYCLES=20,
    parameter int POST_ROUTE_ID=0,
    parameter [8*256-1:0] P3_SILU_LUT_MEM="generated_projection/p3_silu_lut_i8.mem",
    parameter [8*256-1:0] P4_SILU_LUT_MEM="generated_projection/p4_silu_lut_i8.mem",
    parameter [8*256-1:0] P5_SILU_LUT_MEM="generated_projection/p5_silu_lut_i8.mem"
)(
    input logic clk,
    input logic rst_n,
    input logic start,
    output logic busy,
    output logic done,

    output logic [1:0] mem_layer_id,
    output logic stream_valid,
    output logic [PIX_ID_W-1:0] stream_pixel_id,
    output logic [3:0] active_ci_tile,
    output logic [2:0] active_co_tile,
    output logic weight_row_load,
    output logic [4:0] weight_row_index,

    input logic signed [DATA_W-1:0] input_vector_i[0:PE_K-1],
    input logic signed [DATA_W-1:0] weight_row_values_i[0:PE_N-1],

    output logic post_req_valid_o,
    output logic [1:0] post_layer_id_o,
    output logic [6:0] post_channel_base_o,
    input logic signed [31:0] bias_vec_i[0:PE_N-1],
    input logic signed [31:0] requant_m_vec_i[0:PE_N-1],
    input logic [15:0] requant_shift_vec_i[0:PE_N-1],
    input logic signed [31:0] poly_coeff_i[0:31],

    output logic client_req,
    input logic client_grant,
    output logic [11:0] client_cfg_tokens_m1,
    output logic [3:0] client_cfg_k_tiles_m1,
    output logic [3:0] client_cfg_n_tiles_m1,
    output logic signed [SVC_DATA_W-1:0] client_input_vector[0:PE_K-1],
    output logic signed [SVC_DATA_W-1:0] client_weight_row_values[0:PE_N-1],

    input logic svc_stream_valid,
    input logic [11:0] svc_stream_token_id,
    input logic [3:0] svc_active_ci_tile,
    input logic [3:0] svc_active_co_tile,
    input logic svc_weight_row_load,
    input logic [4:0] svc_weight_row_index,
    input logic svc_done,
    input logic svc_raw_valid,
    input logic [11:0] svc_raw_token_id,
    input logic [3:0] svc_raw_co_tile,
    input logic signed [RAW_W-1:0] svc_raw_acc[0:PE_N-1],

    output logic post_in_valid,
    output logic [5:0] post_in_route,
    output logic [1:0] post_in_op,
    output logic [1:0] post_in_layer,
    output logic [11:0] post_in_token,
    output logic [6:0] post_in_co,
    output logic signed [63:0] post_in_value[0:PE_N-1],
    output logic signed [31:0] post_in_multiplier[0:PE_N-1],
    output logic signed [15:0] post_in_shift[0:PE_N-1],

    input logic post_out_valid,
    input logic [5:0] post_out_route,
    input logic [1:0] post_out_op,
    input logic [1:0] post_out_layer,
    input logic [11:0] post_out_token,
    input logic [6:0] post_out_co,
    input logic signed [7:0] post_out_code[0:PE_N-1],

    output logic out_valid,
    output logic [1:0] out_layer_id,
    output logic [11:0] out_pixel_index,
    output logic [6:0] out_channel_base,
    output logic signed [PE_N*8-1:0] out_data
);
    typedef enum logic[2:0] {S_IDLE,S_REQ,S_RUN,S_DRAIN,S_NEXT,S_DONE} st_t;
    st_t st_q;
    logic [1:0] layer_q;
    logic [5:0] drain_q;

    logic [11:0] cfg_tokens_m1;
    logic [3:0] cfg_k_tiles_m1;
    logic [3:0] cfg_n_tiles_m1;

    // One out_valid vector contains 32 output channels.
    localparam int unsigned P3_EXPECTED_OUT_VECS = 2704 * 4; // 10816
    localparam int unsigned P4_EXPECTED_OUT_VECS =  676 * 4; //  2704
    localparam int unsigned P5_EXPECTED_OUT_VECS =  169 * 4; //   676
    localparam int unsigned OUT_VEC_COUNT_W = 14;

    logic [OUT_VEC_COUNT_W-1:0] out_vec_count_q;
    logic [OUT_VEC_COUNT_W-1:0] expected_out_vecs;

    always_comb begin
      unique case(layer_q)
        2'd0: begin
          cfg_tokens_m1 = 12'd2703;
          cfg_k_tiles_m1 = 4'd1;
          cfg_n_tiles_m1 = 4'd3;
          expected_out_vecs = P3_EXPECTED_OUT_VECS[OUT_VEC_COUNT_W-1:0];
        end
        2'd1: begin
          cfg_tokens_m1 = 12'd675;
          cfg_k_tiles_m1 = 4'd3;
          cfg_n_tiles_m1 = 4'd3;
          expected_out_vecs = P4_EXPECTED_OUT_VECS[OUT_VEC_COUNT_W-1:0];
        end
        default: begin
          cfg_tokens_m1 = 12'd168;
          cfg_k_tiles_m1 = 4'd7;
          cfg_n_tiles_m1 = 4'd3;
          expected_out_vecs = P5_EXPECTED_OUT_VECS[OUT_VEC_COUNT_W-1:0];
        end
      endcase
    end

    assign client_cfg_tokens_m1=cfg_tokens_m1;
    assign client_cfg_k_tiles_m1=cfg_k_tiles_m1;
    assign client_cfg_n_tiles_m1=cfg_n_tiles_m1;
    assign mem_layer_id=layer_q;
    assign stream_valid=svc_stream_valid && client_grant;
    assign stream_pixel_id=svc_stream_token_id[PIX_ID_W-1:0];
    assign active_ci_tile=svc_active_ci_tile;
    assign active_co_tile=svc_active_co_tile[2:0];
    assign weight_row_load=svc_weight_row_load && client_grant;
    assign weight_row_index=svc_weight_row_index;

    always_comb begin
      for (int lane_svc=0; lane_svc<PE_K; lane_svc=lane_svc+1)
        client_input_vector[lane_svc] =
          {{(SVC_DATA_W-DATA_W){input_vector_i[lane_svc][DATA_W-1]}}, input_vector_i[lane_svc]};
      for (int lane_svc=0; lane_svc<PE_N; lane_svc=lane_svc+1)
        client_weight_row_values[lane_svc] =
          {{(SVC_DATA_W-DATA_W){weight_row_values_i[lane_svc][DATA_W-1]}}, weight_row_values_i[lane_svc]};
    end

    // External descriptor adapter context remains combinational and refers to
    // the same raw vector that is captured below.
    assign post_req_valid_o=svc_raw_valid && client_grant;
    assign post_layer_id_o=layer_q;
    assign post_channel_base_o={svc_raw_co_tile[1:0],5'b0};

    // Register the complete request before global arbitration/requantization.
    // This removes the direct raw-MAC -> TB descriptor -> global service delta
    // path and guarantees that data and descriptors are sampled together.
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        post_in_valid <= 1'b0;
        post_in_route <= '0;
        post_in_op <= '0;
        post_in_layer <= '0;
        post_in_token <= '0;
        post_in_co <= '0;
        for (int lane_post=0; lane_post<PE_N; lane_post=lane_post+1) begin
          post_in_value[lane_post] <= '0;
          post_in_multiplier[lane_post] <= '0;
          post_in_shift[lane_post] <= '0;
        end
      end else begin
        post_in_valid <= svc_raw_valid && client_grant;
        if (svc_raw_valid && client_grant) begin
          post_in_route <= POST_ROUTE_ID[5:0];
          post_in_op <= 2'd0;
          post_in_layer <= layer_q;
          post_in_token <= svc_raw_token_id;
          post_in_co <= {svc_raw_co_tile[1:0],5'b0};
          for (int lane_post=0; lane_post<PE_N; lane_post=lane_post+1) begin
            post_in_value[lane_post] <= $signed(svc_raw_acc[lane_post]) +
              $signed({{32{bias_vec_i[lane_post][31]}},bias_vec_i[lane_post]});
            post_in_multiplier[lane_post] <= requant_m_vec_i[lane_post];
            post_in_shift[lane_post] <= $signed(requant_shift_vec_i[lane_post]);
          end
        end
      end
    end

    logic lut_accept;
    logic signed [7:0] lut_code[0:PE_N-1];
    assign lut_accept = post_out_valid && (post_out_route == POST_ROUTE_ID[5:0]);

    projection_silu_lut32_embedded #(.LANES(PE_N)) u_projection_silu_lut (
      .layer_id(post_out_layer),
      .in_code(post_out_code),
      .out_code(lut_code)
    );

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        out_valid <= 1'b0;
        out_layer_id <= '0;
        out_pixel_index <= '0;
        out_channel_base <= '0;
        out_data <= '0;
      end else begin
        out_valid <= lut_accept;
        if (lut_accept) begin
          out_layer_id <= post_out_layer;
          out_pixel_index <= post_out_token;
          out_channel_base <= post_out_co;
          for (int lane_out=0; lane_out<PE_N; lane_out=lane_out+1)
            out_data[lane_out*8 +: 8] <= lut_code[lane_out];
        end
      end
    end

    // Count vectors at the exact point where the 32-lane projection result is
    // accepted from the global requant service. Reset only between layers.
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        out_vec_count_q <= '0;
      end else if ((st_q == S_IDLE) ||
                   ((st_q == S_NEXT) && (layer_q != 2'd2))) begin
        out_vec_count_q <= '0;
      end else if (lut_accept) begin
        out_vec_count_q <= out_vec_count_q + 1'b1;
      end
    end

    always_ff @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        st_q<=S_IDLE;
        layer_q<=2'd0;
        busy<=1'b0;
        done<=1'b0;
        client_req<=1'b0;
        drain_q<='0;
      end else begin
        done<=1'b0;
        unique case(st_q)
          S_IDLE: begin
            busy<=1'b0;
            client_req<=1'b0;
            layer_q<=2'd0;
            if(start) begin busy<=1'b1; client_req<=1'b1; st_q<=S_REQ; end
          end
          S_REQ: begin
            client_req<=1'b1;
            if(client_grant) begin client_req<=1'b0; st_q<=S_RUN; end
          end
          S_RUN: begin
            if(svc_done && client_grant) begin drain_q<='0; st_q<=S_DRAIN; end
          end
          S_DRAIN: begin
            // First honor the minimum physical pipeline drain. Then remain in
            // this state until every expected projection vector has returned.
            if (drain_q < POLY_DRAIN_CYCLES-1) begin
              drain_q <= drain_q + 1'b1;
            end else if (out_vec_count_q == expected_out_vecs) begin
              st_q <= S_NEXT;
            end
          end
          S_NEXT: begin
            if(layer_q==2'd2) st_q<=S_DONE;
            else begin layer_q<=layer_q+1'b1; client_req<=1'b1; st_q<=S_REQ; end
          end
          S_DONE: begin busy<=1'b0; done<=1'b1; if(!start) st_q<=S_IDLE; end
          default: st_q<=S_IDLE;
        endcase
      end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n && svc_raw_valid && client_grant) begin
        for (int lane_chk=0; lane_chk<PE_N; lane_chk=lane_chk+1) begin
          if ((^svc_raw_acc[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_MAC_RAW layer=%0d token=%0d co=%0d lane=%0d",
              layer_q,svc_raw_token_id,svc_raw_co_tile,lane_chk);
          if ((^bias_vec_i[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_BIAS layer=%0d token=%0d co=%0d lane=%0d",
              layer_q,svc_raw_token_id,svc_raw_co_tile,lane_chk);
          if ((^requant_m_vec_i[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_MULT layer=%0d token=%0d co=%0d lane=%0d",
              layer_q,svc_raw_token_id,svc_raw_co_tile,lane_chk);
          if ((^requant_shift_vec_i[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_SHIFT layer=%0d token=%0d co=%0d lane=%0d",
              layer_q,svc_raw_token_id,svc_raw_co_tile,lane_chk);
        end
      end
      if (rst_n && post_in_valid) begin
        for (int lane_chk=0; lane_chk<PE_N; lane_chk=lane_chk+1) begin
          if ((^post_in_value[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_CAPTURED_VALUE layer=%0d token=%0d co=%0d lane=%0d",
              post_in_layer,post_in_token,post_in_co,lane_chk);
        end
      end
      if (rst_n && lut_accept) begin
        for (int lane_chk=0; lane_chk<PE_N; lane_chk=lane_chk+1) begin
          if ((^post_out_code[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_REQUANT_OUTPUT layer=%0d token=%0d co=%0d lane=%0d",
              post_out_layer,post_out_token,post_out_co,lane_chk);
          if ((^lut_code[lane_chk]) === 1'bx)
            $fatal(1,"PROJ_X_AT_SILU_LUT layer=%0d token=%0d co=%0d lane=%0d",
              post_out_layer,post_out_token,post_out_co,lane_chk);
        end
      end
      if (rst_n && post_in_valid && ((^poly_coeff_i[0]) === 1'bx))
        $fatal(1,"projection PolySiLU descriptor contains X");
      if (rst_n && lut_accept && (out_vec_count_q >= expected_out_vecs))
        $fatal(1,"PROJ_OUTPUT_OVERFLOW layer=%0d count=%0d expected=%0d",
          layer_q, out_vec_count_q, expected_out_vecs);
      if (rst_n && (st_q == S_NEXT) && (out_vec_count_q != expected_out_vecs))
        $fatal(1,"PROJ_LAYER_EARLY_ADVANCE layer=%0d count=%0d expected=%0d",
          layer_q, out_vec_count_q, expected_out_vecs);
      if (rst_n && (st_q == S_DONE) &&
          ((layer_q != 2'd2) || (out_vec_count_q != P5_EXPECTED_OUT_VECS)))
        $fatal(1,"PROJ_DONE_WITH_BAD_COUNT layer=%0d count=%0d",
          layer_q, out_vec_count_q);
    end
`endif
endmodule
