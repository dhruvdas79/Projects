`timescale 1ns/1ps
// ============================================================================
// projection_swin_shared32_top.sv
//
// Corrected top for the requested integration:
//   P3/P4/P5 projection client
//        -> same global shared32 MAC service
//   then P4 Swin chain and P3 Swin chain
//        -> same global shared32 MAC service
//
// There is exactly ONE physical ws32x32_weight_stationary_core instance in the
// final hierarchy: inside swin_shared32_mac_service.
//
// Projection P3/P4 32-lane outputs are written directly into P3/P4 Swin input
// memories through the 32-lane bridge write ports.  P5 projection is exposed as
// a 32-lane stream for the later FPN/head integration.
// ============================================================================
module projection_swin_shared32_top #(
    parameter int PE_K = 32,
    parameter int PE_N = 32
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic abort,

    // Projection input/weight adapter context output.
    output logic [1:0]          proj_mem_layer_id,
    output logic                proj_stream_valid,
    output logic [11:0]         proj_stream_pixel_id,
    output logic [3:0]          proj_active_ci_tile,
    output logic [2:0]          proj_active_co_tile,
    output logic                proj_weight_row_load,
    output logic [4:0]          proj_weight_row_index,

    // Projection adapter data input.  These come from the real projection
    // activation/weight memory adapter, same as the verified projection design.
    input  logic signed [7:0]   proj_input_vector_i [0:PE_K-1],
    input  logic signed [7:0]   proj_weight_row_values_i [0:PE_N-1],

    // Projection postprocess constant adapter.
    output logic                proj_post_req_valid,
    output logic [1:0]          proj_post_layer_id,
    output logic [6:0]          proj_post_channel_base,
    input  logic signed [31:0]  proj_bias_vec_i [0:PE_N-1],
    input  logic signed [31:0]  proj_requant_m_vec_i [0:PE_N-1],
    input  logic        [15:0]  proj_requant_shift_vec_i [0:PE_N-1],
    input  logic signed [31:0]  proj_poly_coeff_i [0:31],

    // Swin outputs for later FPN/head.
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

    // P5 projection stream for post-Swin/FPN path.  It is not consumed by Swin.
    output logic                p5_proj_out_valid,
    output logic [11:0]         p5_proj_out_pixel,
    output logic [1:0]          p5_proj_out_co_tile,
    output logic signed [255:0] p5_proj_out_data,

    output logic busy,
    output logic done,
    output logic aborted,
    output logic [3:0] state_code,
    output logic projection_busy,
    output logic projection_done,
    output logic p4_swin_busy,
    output logic p4_swin_done,
    output logic p3_swin_busy,
    output logic p3_swin_done
);
    localparam int NUM_CLIENTS = 3; // 0 projection, 1 P4 chain, 2 P3 chain

    logic child_rst_n;
    assign child_rst_n = rst_n & ~abort;

    typedef enum logic [3:0] {M_IDLE,M_PROJ_LAUNCH,M_PROJ_WAIT,M_P4_LAUNCH,M_P4_WAIT,M_P3_LAUNCH,M_P3_WAIT,M_DONE,M_ABORTED} mst_t;
    mst_t mst_q;
    logic proj_start, p4_start, p3_start;

    localparam int unsigned P3_EXPECTED_PROJ_VECS = 2704 * 4;
    localparam int unsigned P4_EXPECTED_PROJ_VECS =  676 * 4;
    localparam int unsigned P5_EXPECTED_PROJ_VECS =  169 * 4;
    logic [13:0] p3_proj_vec_count_q;
    logic [13:0] p4_proj_vec_count_q;
    logic [13:0] p5_proj_vec_count_q;
    logic projection_counts_complete;

    always_comb begin
        proj_start = 1'b0; p4_start = 1'b0; p3_start = 1'b0;
        busy       = (mst_q != M_IDLE) && (mst_q != M_DONE) && (mst_q != M_ABORTED);
        done       = (mst_q == M_DONE);
        aborted    = (mst_q == M_ABORTED);
        state_code = mst_q;
        case (mst_q)
            M_PROJ_LAUNCH: proj_start = 1'b1;
            M_P4_LAUNCH:   p4_start   = 1'b1;
            M_P3_LAUNCH:   p3_start   = 1'b1;
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mst_q <= M_IDLE;
        else if (abort) mst_q <= M_ABORTED;
        else begin
            case (mst_q)
                M_IDLE:        if (start) mst_q <= M_PROJ_LAUNCH;
                M_PROJ_LAUNCH: mst_q <= M_PROJ_WAIT;
                M_PROJ_WAIT:   if (projection_done && projection_counts_complete)
                                   mst_q <= M_P4_LAUNCH;
                M_P4_LAUNCH:   mst_q <= M_P4_WAIT;
                M_P4_WAIT:     if (p4_swin_done) mst_q <= M_P3_LAUNCH;
                M_P3_LAUNCH:   mst_q <= M_P3_WAIT;
                M_P3_WAIT:     if (p3_swin_done) mst_q <= M_DONE;
                M_DONE:        if (!start) mst_q <= M_IDLE;
                M_ABORTED:     if (!abort && !start) mst_q <= M_IDLE;
                default:       mst_q <= M_IDLE;
            endcase
        end
    end

    // --------------------- Global shared32 service ---------------------------
    logic [NUM_CLIENTS-1:0] client_req, client_grant;
    logic [11:0] client_cfg_tokens_m1 [0:NUM_CLIENTS-1];
    logic [3:0]  client_cfg_k_tiles_m1 [0:NUM_CLIENTS-1];
    logic [3:0]  client_cfg_n_tiles_m1 [0:NUM_CLIENTS-1];
    logic signed [8:0] client_input_vector [0:NUM_CLIENTS-1][0:31];
    logic signed [8:0] client_weight_row_values [0:NUM_CLIENTS-1][0:31];

    logic svc_start, svc_busy, svc_done;
    logic [11:0] svc_cfg_tokens_m1;
    logic [3:0]  svc_cfg_k_tiles_m1, svc_cfg_n_tiles_m1;
    logic signed [8:0] svc_input_vector [0:31];
    logic signed [8:0] svc_weight_row_values [0:31];

    logic svc_stream_valid; logic [11:0] svc_stream_token_id;
    logic [3:0] svc_active_ci_tile, svc_active_co_tile;
    logic svc_weight_row_load; logic [4:0] svc_weight_row_index;
    logic svc_raw_valid; logic [11:0] svc_raw_token_id; logic [3:0] svc_raw_co_tile;
    logic signed [63:0] svc_raw_acc [0:31];

    // Exactly one global, no-DSP, 32-lane requant service. Projection and all
    // six Swin blocks route their post-MAC vectors through this physical unit.
    logic [NUM_CLIENTS-1:0] post_client_valid;
    logic [5:0] post_client_route [0:NUM_CLIENTS-1];
    logic [1:0] post_client_op [0:NUM_CLIENTS-1];
    logic [1:0] post_client_layer [0:NUM_CLIENTS-1];
    logic [11:0] post_client_token [0:NUM_CLIENTS-1];
    logic [6:0] post_client_co [0:NUM_CLIENTS-1];
    logic signed [63:0] post_client_value [0:NUM_CLIENTS-1][0:31];
    logic signed [31:0] post_client_multiplier [0:NUM_CLIENTS-1][0:31];
    logic signed [15:0] post_client_shift [0:NUM_CLIENTS-1][0:31];

    logic post_mux_valid;
    logic [5:0] post_mux_route;
    logic [1:0] post_mux_op, post_mux_layer;
    logic [11:0] post_mux_token;
    logic [6:0] post_mux_co;
    logic signed [63:0] post_mux_value [0:31];
    logic signed [31:0] post_mux_multiplier [0:31];
    logic signed [15:0] post_mux_shift [0:31];

    logic post_out_valid;
    logic [5:0] post_out_route;
    logic [1:0] post_out_op, post_out_layer;
    logic [11:0] post_out_token;
    logic [6:0] post_out_co;
    logic signed [7:0] post_out_code [0:31];


    always_comb begin
        post_mux_valid = 1'b0;
        post_mux_route = '0;
        post_mux_op = '0;
        post_mux_layer = '0;
        post_mux_token = '0;
        post_mux_co = '0;
        for (int post_lane =0; post_lane<32; post_lane=post_lane+1) begin
            post_mux_value[post_lane] = '0;
            post_mux_multiplier[post_lane] = '0;
            post_mux_shift[post_lane] = '0;
        end
        for (int post_sel =0; post_sel<NUM_CLIENTS; post_sel=post_sel+1) begin
            if (post_client_valid[post_sel]) begin
                post_mux_valid = 1'b1;
                post_mux_route = post_client_route[post_sel];
                post_mux_op = post_client_op[post_sel];
                post_mux_layer = post_client_layer[post_sel];
                post_mux_token = post_client_token[post_sel];
                post_mux_co = post_client_co[post_sel];
                for (int post_lane =0; post_lane<32; post_lane=post_lane+1) begin
                    post_mux_value[post_lane] = post_client_value[post_sel][post_lane];
                    post_mux_multiplier[post_lane] = post_client_multiplier[post_sel][post_lane];
                    post_mux_shift[post_lane] = post_client_shift[post_sel][post_lane];
                end
            end
        end
    end

    swin_shared32_arbiter8 #(.NUM_CLIENTS(NUM_CLIENTS)) u_global_arb (
        .clk,.rst_n(child_rst_n),
        .client_req(client_req),.client_grant(client_grant),
        .client_cfg_tokens_m1(client_cfg_tokens_m1),
        .client_cfg_k_tiles_m1(client_cfg_k_tiles_m1),
        .client_cfg_n_tiles_m1(client_cfg_n_tiles_m1),
        .client_input_vector(client_input_vector),
        .client_weight_row_values(client_weight_row_values),
        .svc_start(svc_start),.svc_busy(svc_busy),.svc_done(svc_done),
        .svc_cfg_tokens_m1(svc_cfg_tokens_m1),.svc_cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.svc_cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .svc_input_vector(svc_input_vector),.svc_weight_row_values(svc_weight_row_values)
    );

    swin_shared32_mac_service #(.PE_K(PE_K),.PE_N(PE_N)) u_only_shared32_service (
        .clk,.rst_n(child_rst_n),.start(svc_start),.busy(svc_busy),.done(svc_done),
        .cfg_tokens_m1(svc_cfg_tokens_m1),.cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .stream_valid(svc_stream_valid),.stream_token_id(svc_stream_token_id),.active_ci_tile(svc_active_ci_tile),.active_co_tile(svc_active_co_tile),
        .weight_row_load(svc_weight_row_load),.weight_row_index(svc_weight_row_index),
        .input_vector(svc_input_vector),.weight_row_values(svc_weight_row_values),
        .raw_valid(svc_raw_valid),.raw_token_id(svc_raw_token_id),.raw_co_tile(svc_raw_co_tile),.raw_acc(svc_raw_acc)
    );

    shared_requant32_service #(.LANES(32),.ROUTE_W(6),.LATENCY(7)) u_only_global_requant_service (
        .clk(clk),.rst_n(child_rst_n),
        .in_valid(post_mux_valid),.in_route(post_mux_route),.in_op(post_mux_op),
        .in_layer(post_mux_layer),.in_token(post_mux_token),.in_co(post_mux_co),
        .in_value(post_mux_value),.in_multiplier(post_mux_multiplier),.in_shift(post_mux_shift),
        .out_valid(post_out_valid),.out_route(post_out_route),.out_op(post_out_op),
        .out_layer(post_out_layer),.out_token(post_out_token),.out_co(post_out_co),
        .out_code(post_out_code)
    );

    // --------------------- Projection client --------------------------------
    logic proj_out_valid; logic [1:0] proj_out_layer_id; logic [11:0] proj_out_pixel_index;
    logic [6:0] proj_out_channel_base; logic signed [255:0] proj_out_data;

    assign projection_counts_complete =
      (p3_proj_vec_count_q == P3_EXPECTED_PROJ_VECS) &&
      (p4_proj_vec_count_q == P4_EXPECTED_PROJ_VECS) &&
      (p5_proj_vec_count_q == P5_EXPECTED_PROJ_VECS);

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        p3_proj_vec_count_q <= '0;
        p4_proj_vec_count_q <= '0;
        p5_proj_vec_count_q <= '0;
      end else begin
        if ((mst_q == M_IDLE) && start) begin
          p3_proj_vec_count_q <= '0;
          p4_proj_vec_count_q <= '0;
          p5_proj_vec_count_q <= '0;
        end else if (proj_out_valid) begin
          unique case (proj_out_layer_id)
            2'd0: p3_proj_vec_count_q <= p3_proj_vec_count_q + 1'b1;
            2'd1: p4_proj_vec_count_q <= p4_proj_vec_count_q + 1'b1;
            2'd2: p5_proj_vec_count_q <= p5_proj_vec_count_q + 1'b1;
            default: ;
          endcase
        end
      end
    end

    projection_p3p4p5_shared32_client #(.PE_K(PE_K),.PE_N(PE_N)) u_projection (
        .clk,.rst_n(child_rst_n),.start(proj_start),.busy(projection_busy),.done(projection_done),
        .mem_layer_id(proj_mem_layer_id),.stream_valid(proj_stream_valid),.stream_pixel_id(proj_stream_pixel_id),
        .active_ci_tile(proj_active_ci_tile),.active_co_tile(proj_active_co_tile),
        .weight_row_load(proj_weight_row_load),.weight_row_index(proj_weight_row_index),
        .input_vector_i(proj_input_vector_i),.weight_row_values_i(proj_weight_row_values_i),
        .post_req_valid_o(proj_post_req_valid),.post_layer_id_o(proj_post_layer_id),.post_channel_base_o(proj_post_channel_base),
        .bias_vec_i(proj_bias_vec_i),.requant_m_vec_i(proj_requant_m_vec_i),.requant_shift_vec_i(proj_requant_shift_vec_i),.poly_coeff_i(proj_poly_coeff_i),
        .client_req(client_req[0]),.client_grant(client_grant[0]),.client_cfg_tokens_m1(client_cfg_tokens_m1[0]),.client_cfg_k_tiles_m1(client_cfg_k_tiles_m1[0]),.client_cfg_n_tiles_m1(client_cfg_n_tiles_m1[0]),.client_input_vector(client_input_vector[0]),.client_weight_row_values(client_weight_row_values[0]),
        .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
        .post_in_valid(post_client_valid[0]),.post_in_route(post_client_route[0]),.post_in_op(post_client_op[0]),.post_in_layer(post_client_layer[0]),.post_in_token(post_client_token[0]),.post_in_co(post_client_co[0]),
        .post_in_value(post_client_value[0]),.post_in_multiplier(post_client_multiplier[0]),.post_in_shift(post_client_shift[0]),
        .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code,
        .out_valid(proj_out_valid),.out_layer_id(proj_out_layer_id),.out_pixel_index(proj_out_pixel_index),.out_channel_base(proj_out_channel_base),.out_data(proj_out_data)
    );

    // P3/P4 projection streams feed Swin input memories through 32-lane writes.
    logic p3_proj_wr32_valid, p4_proj_wr32_valid;
    assign p3_proj_wr32_valid = proj_out_valid && (proj_out_layer_id == 2'd0);
    assign p4_proj_wr32_valid = proj_out_valid && (proj_out_layer_id == 2'd1);

    assign p5_proj_out_valid   = proj_out_valid && (proj_out_layer_id == 2'd2);
    assign p5_proj_out_pixel   = proj_out_pixel_index;
    assign p5_proj_out_co_tile = proj_out_channel_base[6:5];
    assign p5_proj_out_data    = proj_out_data;

    // --------------------- Shared Swin chains -------------------------------
    swin_p4_live_chain_shared32 u_p4_chain (
        .clk,.rst_n(child_rst_n),.start(p4_start),.busy(p4_swin_busy),.done(p4_swin_done),
        .in_wr_valid(1'b0),.in_wr_pixel('0),.in_wr_co_tile('0),.in_wr_data('0),
        .in_wr32_valid(p4_proj_wr32_valid),.in_wr32_pixel(proj_out_pixel_index[9:0]),.in_wr32_co_tile(proj_out_channel_base[6:5]),.in_wr32_data(proj_out_data),
        .out_rd_en(p4_out_rd_en),.out_rd_pixel(p4_out_rd_pixel),.out_rd_co_tile(p4_out_rd_co_tile),.out_rd_valid(p4_out_rd_valid),.out_rd_data(p4_out_rd_data),
        .client_req(client_req[1]),.client_grant(client_grant[1]),.client_cfg_tokens_m1(client_cfg_tokens_m1[1]),.client_cfg_k_tiles_m1(client_cfg_k_tiles_m1[1]),.client_cfg_n_tiles_m1(client_cfg_n_tiles_m1[1]),.client_input_vector(client_input_vector[1]),.client_weight_row_values(client_weight_row_values[1]),
        .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
        .post_in_valid(post_client_valid[1]),.post_in_route(post_client_route[1]),.post_in_op(post_client_op[1]),.post_in_layer(post_client_layer[1]),.post_in_token(post_client_token[1]),.post_in_co(post_client_co[1]),
        .post_in_value(post_client_value[1]),.post_in_multiplier(post_client_multiplier[1]),.post_in_shift(post_client_shift[1]),
        .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
    );

    swin_p3_live_chain_shared32 u_p3_chain (
        .clk,.rst_n(child_rst_n),.start(p3_start),.busy(p3_swin_busy),.done(p3_swin_done),
        .in_wr_valid(1'b0),.in_wr_pixel('0),.in_wr_co_tile('0),.in_wr_data('0),
        .in_wr32_valid(p3_proj_wr32_valid),.in_wr32_pixel(proj_out_pixel_index),.in_wr32_co_tile(proj_out_channel_base[6:5]),.in_wr32_data(proj_out_data),
        .out_rd_en(p3_out_rd_en),.out_rd_pixel(p3_out_rd_pixel),.out_rd_co_tile(p3_out_rd_co_tile),.out_rd_valid(p3_out_rd_valid),.out_rd_data(p3_out_rd_data),
        .client_req(client_req[2]),.client_grant(client_grant[2]),.client_cfg_tokens_m1(client_cfg_tokens_m1[2]),.client_cfg_k_tiles_m1(client_cfg_k_tiles_m1[2]),.client_cfg_n_tiles_m1(client_cfg_n_tiles_m1[2]),.client_input_vector(client_input_vector[2]),.client_weight_row_values(client_weight_row_values[2]),
        .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
        .post_in_valid(post_client_valid[2]),.post_in_route(post_client_route[2]),.post_in_op(post_client_op[2]),.post_in_layer(post_client_layer[2]),.post_in_token(post_client_token[2]),.post_in_co(post_client_co[2]),
        .post_in_value(post_client_value[2]),.post_in_multiplier(post_client_multiplier[2]),.post_in_shift(post_client_shift[2]),
        .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (child_rst_n && !$onehot0(post_client_valid))
            $fatal(1, "projection_swin_shared32_top: simultaneous global requant producers");
        if (child_rst_n && projection_done && !projection_counts_complete)
            $fatal(1,
              "TOP_PROJECTION_DONE_EARLY P3=%0d/%0d P4=%0d/%0d P5=%0d/%0d",
              p3_proj_vec_count_q, P3_EXPECTED_PROJ_VECS,
              p4_proj_vec_count_q, P4_EXPECTED_PROJ_VECS,
              p5_proj_vec_count_q, P5_EXPECTED_PROJ_VECS);
    end
`endif
endmodule
