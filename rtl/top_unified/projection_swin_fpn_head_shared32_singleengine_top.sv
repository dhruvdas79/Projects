`timescale 1ns/1ps
// ============================================================================
// projection_swin_shared32_top.sv
//
// Corrected top for the requested integration:
//   P3/P4/P5 projection client
//        -> same global shared32 MAC service
//   then P4 Swin chain and P3 Swin chain
//        -> same global shared32 MAC service
//   then 29 post-Swin FPN/head convolutions
//        -> same global shared32 MAC service
//
// There is exactly ONE physical ws32x32_weight_stationary_core instance in the
// final hierarchy: inside swin_shared32_mac_service.
//
// Projection P3/P4 32-lane outputs are written directly into P3/P4 Swin input
// memories through the 32-lane bridge write ports.  P5 projection is exposed as
// a 32-lane stream for the later FPN/head integration.
// ============================================================================
module projection_swin_fpn_head_shared32_singleengine_top #(
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

    // One reusable Swin-engine asset-cache interface. Complete block weights
    // may reside in DDR; the cache returns one 32-lane row/vector per request.
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

    // Post-Swin FPN/head runtime memory adapter.  In the profiled test this is
    // connected to the exported asset loader; in hardware connect BRAM/URAM/DDR.
    output logic [4:0]          post_stage_id,
    output logic                post_stage_prepare_req,
    input  logic                post_stage_prepare_done,
    output logic                post_stage_done_pulse,
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
    input  logic signed [8:0]   post_adapter_input_vector [0:PE_K-1],
    input  logic signed [8:0]   post_adapter_weight_row_values [0:PE_N-1],
    output logic [5:0]          post_adapter_post_co_tile,
    input  logic signed [31:0]  post_adapter_bias [0:PE_N-1],
    input  logic signed [31:0]  post_adapter_multiplier [0:PE_N-1],
    input  logic signed [15:0]  post_adapter_shift [0:PE_N-1],
    output logic signed [7:0]   post_adapter_poly_code [0:PE_N-1],
    input  logic signed [7:0]   post_adapter_poly_value [0:PE_N-1],
    output logic                fpn_head_out_valid,
    output logic [4:0]          fpn_head_out_stage_id,
    output logic [11:0]         fpn_head_out_token,
    output logic [5:0]          fpn_head_out_co_tile,
    output logic [31:0]         fpn_head_out_lane_mask,
    output logic signed [7:0]   fpn_head_out_data [0:PE_N-1],
    output logic [13:0]         post_stage_vector_count,

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
    output logic post_done
);
    localparam int NUM_CLIENTS = 3; // 0 projection, 1 one reusable Swin engine, 2 post-Swin FPN/head

    logic child_rst_n;
    assign child_rst_n = rst_n & ~abort;

    typedef enum logic [3:0] {M_IDLE,M_PROJ_LAUNCH,M_PROJ_WAIT,M_P4_LAUNCH,M_P4_WAIT,
      M_P3_LAUNCH,M_P3_WAIT,M_POST_LAUNCH,M_POST_WAIT,M_DONE,M_ABORTED} mst_t;
    mst_t mst_q;
    logic proj_start, p4_start, p3_start, post_start;

    localparam int unsigned P3_EXPECTED_PROJ_VECS = 2704 * 4;
    localparam int unsigned P4_EXPECTED_PROJ_VECS =  676 * 4;
    localparam int unsigned P5_EXPECTED_PROJ_VECS =  169 * 4;
    logic [13:0] p3_proj_vec_count_q;
    logic [13:0] p4_proj_vec_count_q;
    logic [13:0] p5_proj_vec_count_q;
    logic projection_counts_complete;

    always_comb begin
        proj_start = 1'b0; p4_start = 1'b0; p3_start = 1'b0; post_start = 1'b0;
        busy       = (mst_q != M_IDLE) && (mst_q != M_DONE) && (mst_q != M_ABORTED);
        done       = (mst_q == M_DONE);
        aborted    = (mst_q == M_ABORTED);
        state_code = mst_q;
        case (mst_q)
            M_PROJ_LAUNCH: proj_start = 1'b1;
            M_P4_LAUNCH:   p4_start   = 1'b1;
            M_P3_LAUNCH:   p3_start   = 1'b1;
            M_POST_LAUNCH: post_start = 1'b1;
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
                M_P3_WAIT:     if (p3_swin_done) mst_q <= M_POST_LAUNCH;
                M_POST_LAUNCH: mst_q <= M_POST_WAIT;
                M_POST_WAIT:   if (post_done) mst_q <= M_DONE;
                M_DONE:        if (!start) mst_q <= M_IDLE;
                M_ABORTED:     if (!abort && !start) mst_q <= M_IDLE;
                default:       mst_q <= M_IDLE;
            endcase
        end
    end

    // --------------------- Global shared32 service ---------------------------
    logic [NUM_CLIENTS-1:0] client_req, client_grant;
    logic [11:0] client_cfg_tokens_m1 [0:NUM_CLIENTS-1];
    logic [5:0]  client_cfg_k_tiles_m1 [0:NUM_CLIENTS-1];
    logic [5:0]  client_cfg_n_tiles_m1 [0:NUM_CLIENTS-1];

    // Legacy Swin chains use 4-bit tile fields; the unified service uses
    // 6-bit fields so post-Swin 3x3 layers can represent up to 36 K tiles.
    logic [3:0] proj_cfg_k_tiles_m1, proj_cfg_n_tiles_m1;
    logic [3:0] swin_cfg_k_tiles_m1, swin_cfg_n_tiles_m1;
    assign client_cfg_k_tiles_m1[0] = {2'b00, proj_cfg_k_tiles_m1};
    assign client_cfg_n_tiles_m1[0] = {2'b00, proj_cfg_n_tiles_m1};
    assign client_cfg_k_tiles_m1[1] = {2'b00, swin_cfg_k_tiles_m1};
    assign client_cfg_n_tiles_m1[1] = {2'b00, swin_cfg_n_tiles_m1};
    logic client_input_valid [0:NUM_CLIENTS-1];
    logic client_weight_valid [0:NUM_CLIENTS-1];
    // Projection and post-Swin adapters retain their original same-cycle contract.
    assign client_input_valid[0] = 1'b1;
    assign client_weight_valid[0] = 1'b1;
    assign client_input_valid[2] = 1'b1;
    assign client_weight_valid[2] = 1'b1;

    logic signed [8:0] client_input_vector [0:NUM_CLIENTS-1][0:31];
    logic signed [8:0] client_weight_row_values [0:NUM_CLIENTS-1][0:31];

    logic svc_start, svc_busy, svc_done;
    logic [11:0] svc_cfg_tokens_m1;
    logic [5:0]  svc_cfg_k_tiles_m1, svc_cfg_n_tiles_m1;
    logic svc_input_valid, svc_weight_valid;
    logic signed [8:0] svc_input_vector [0:31];
    logic signed [8:0] svc_weight_row_values [0:31];

    logic svc_stream_valid; logic [11:0] svc_stream_token_id;
    logic [5:0] svc_active_ci_tile, svc_active_co_tile;
    logic svc_weight_row_load; logic [4:0] svc_weight_row_index;
    logic svc_raw_valid; logic [11:0] svc_raw_token_id; logic [5:0] svc_raw_co_tile;
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

    swin_shared32_arbiter8 #(.NUM_CLIENTS(NUM_CLIENTS),.TILE_W(6)) u_global_arb (
        .clk,.rst_n(child_rst_n),
        .client_req(client_req),.client_grant(client_grant),
        .client_cfg_tokens_m1(client_cfg_tokens_m1),
        .client_cfg_k_tiles_m1(client_cfg_k_tiles_m1),
        .client_cfg_n_tiles_m1(client_cfg_n_tiles_m1),
        .client_input_valid(client_input_valid),.client_weight_valid(client_weight_valid),
        .client_input_vector(client_input_vector),
        .client_weight_row_values(client_weight_row_values),
        .svc_start(svc_start),.svc_busy(svc_busy),.svc_done(svc_done),
        .svc_cfg_tokens_m1(svc_cfg_tokens_m1),.svc_cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.svc_cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .svc_input_valid(svc_input_valid),.svc_weight_valid(svc_weight_valid),
        .svc_input_vector(svc_input_vector),.svc_weight_row_values(svc_weight_row_values)
    );

`ifdef FAST_SIM_MAC
    // Transaction-level numerical model used only by the fast Linux XSim flow.
    // The synthesis build does not define FAST_SIM_MAC and therefore retains
    // the physical one-core 32x32 DSP implementation below.
    swin_shared32_mac_service_fast_sim #(.PE_K(PE_K),.PE_N(PE_N),.TILE_W(6)) u_fast_shared32_service (
        .clk,.rst_n(child_rst_n),.start(svc_start),.busy(svc_busy),.done(svc_done),
        .cfg_tokens_m1(svc_cfg_tokens_m1),.cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .stream_valid(svc_stream_valid),.stream_token_id(svc_stream_token_id),.active_ci_tile(svc_active_ci_tile),.active_co_tile(svc_active_co_tile),
        .weight_row_load(svc_weight_row_load),.weight_row_index(svc_weight_row_index),
        .input_vector_valid(svc_input_valid),.weight_row_valid(svc_weight_valid),
        .input_vector(svc_input_vector),.weight_row_values(svc_weight_row_values),
        .raw_valid(svc_raw_valid),.raw_token_id(svc_raw_token_id),.raw_co_tile(svc_raw_co_tile),.raw_acc(svc_raw_acc)
    );
`else
    swin_shared32_mac_service #(.PE_K(PE_K),.PE_N(PE_N),.TILE_W(6)) u_only_shared32_service (
        .clk,.rst_n(child_rst_n),.start(svc_start),.busy(svc_busy),.done(svc_done),
        .cfg_tokens_m1(svc_cfg_tokens_m1),.cfg_k_tiles_m1(svc_cfg_k_tiles_m1),.cfg_n_tiles_m1(svc_cfg_n_tiles_m1),
        .stream_valid(svc_stream_valid),.stream_token_id(svc_stream_token_id),.active_ci_tile(svc_active_ci_tile),.active_co_tile(svc_active_co_tile),
        .weight_row_load(svc_weight_row_load),.weight_row_index(svc_weight_row_index),
        .input_vector_valid(svc_input_valid),.weight_row_valid(svc_weight_valid),
        .input_vector(svc_input_vector),.weight_row_values(svc_weight_row_values),
        .raw_valid(svc_raw_valid),.raw_token_id(svc_raw_token_id),.raw_co_tile(svc_raw_co_tile),.raw_acc(svc_raw_acc)
    );
`endif

`ifdef FAST_SIM_REQUANT
    shared_requant32_service_fast_sim #(.LANES(32),.ROUTE_W(6)) u_fast_global_requant_service (
        .clk(clk),.rst_n(child_rst_n),
        .in_valid(post_mux_valid),.in_route(post_mux_route),.in_op(post_mux_op),
        .in_layer(post_mux_layer),.in_token(post_mux_token),.in_co(post_mux_co),
        .in_value(post_mux_value),.in_multiplier(post_mux_multiplier),.in_shift(post_mux_shift),
        .out_valid(post_out_valid),.out_route(post_out_route),.out_op(post_out_op),
        .out_layer(post_out_layer),.out_token(post_out_token),.out_co(post_out_co),
        .out_code(post_out_code)
    );
`else
    shared_requant32_service #(.LANES(32),.ROUTE_W(6),.LATENCY(7)) u_only_global_requant_service (
        .clk(clk),.rst_n(child_rst_n),
        .in_valid(post_mux_valid),.in_route(post_mux_route),.in_op(post_mux_op),
        .in_layer(post_mux_layer),.in_token(post_mux_token),.in_co(post_mux_co),
        .in_value(post_mux_value),.in_multiplier(post_mux_multiplier),.in_shift(post_mux_shift),
        .out_valid(post_out_valid),.out_route(post_out_route),.out_op(post_out_op),
        .out_layer(post_out_layer),.out_token(post_out_token),.out_co(post_out_co),
        .out_code(post_out_code)
    );
`endif

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
        .client_req(client_req[0]),.client_grant(client_grant[0]),.client_cfg_tokens_m1(client_cfg_tokens_m1[0]),.client_cfg_k_tiles_m1(proj_cfg_k_tiles_m1),.client_cfg_n_tiles_m1(proj_cfg_n_tiles_m1),.client_input_vector(client_input_vector[0]),.client_weight_row_values(client_weight_row_values[0]),
        .svc_stream_valid(svc_stream_valid),.svc_stream_token_id(svc_stream_token_id),.svc_active_ci_tile(svc_active_ci_tile[3:0]),.svc_active_co_tile(svc_active_co_tile[3:0]),.svc_weight_row_load(svc_weight_row_load),.svc_weight_row_index(svc_weight_row_index),.svc_done(svc_done),.svc_raw_valid(svc_raw_valid),.svc_raw_token_id(svc_raw_token_id),.svc_raw_co_tile(svc_raw_co_tile[3:0]),.svc_raw_acc(svc_raw_acc),
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

    // ---------------- One reusable physical Swin engine --------------------
    swin_single_reusable_chain_shared32 u_single_swin (
      .clk,.rst_n(child_rst_n),.p4_start,.p4_busy(p4_swin_busy),.p4_done(p4_swin_done),
      .p3_start,.p3_busy(p3_swin_busy),.p3_done(p3_swin_done),
      .p4_proj_wr_valid(p4_proj_wr32_valid),.p4_proj_wr_pixel(proj_out_pixel_index[9:0]),
      .p4_proj_wr_co_tile(proj_out_channel_base[6:5]),.p4_proj_wr_data(proj_out_data),
      .p3_proj_wr_valid(p3_proj_wr32_valid),.p3_proj_wr_pixel(proj_out_pixel_index),
      .p3_proj_wr_co_tile(proj_out_channel_base[6:5]),.p3_proj_wr_data(proj_out_data),
      .p4_out_rd_en,.p4_out_rd_pixel,.p4_out_rd_co_tile,.p4_out_rd_valid,.p4_out_rd_data,
      .p3_out_rd_en,.p3_out_rd_pixel,.p3_out_rd_co_tile,.p3_out_rd_valid,.p3_out_rd_data,
      .weight_req_valid(swin_weight_req_valid),.weight_req_block(swin_weight_req_block),
      .weight_req_stage(swin_weight_req_stage),.weight_req_ci_tile(swin_weight_req_ci_tile),
      .weight_req_co_tile(swin_weight_req_co_tile),.weight_req_row(swin_weight_req_row),
      .weight_resp_valid(swin_weight_resp_valid),.weight_resp_data(swin_weight_resp_data),
      .postparam_req_valid(swin_postparam_req_valid),.postparam_req_block(swin_postparam_req_block),
      .postparam_req_stage(swin_postparam_req_stage),.postparam_req_co_tile(swin_postparam_req_co_tile),
      .postparam_resp_valid(swin_postparam_resp_valid),.postparam_bias(swin_postparam_bias),
      .postparam_multiplier(swin_postparam_multiplier),.postparam_shift(swin_postparam_shift),
      .norm_req_valid(swin_norm_req_valid),.norm_req_block(swin_norm_req_block),
      .norm_req_sel(swin_norm_req_sel),.norm_req_co_tile(swin_norm_req_co_tile),
      .norm_req_code(swin_norm_req_code),.norm_resp_valid(swin_norm_resp_valid),.norm_resp_value(swin_norm_resp_value),
      .poly_req_valid(swin_poly_req_valid),.poly_req_block(swin_poly_req_block),.poly_req_code(swin_poly_req_code),
      .poly_resp_valid(swin_poly_resp_valid),.poly_resp_value(swin_poly_resp_value),
      .resparam_req_valid(swin_resparam_req_valid),.resparam_req_block(swin_resparam_req_block),
      .resparam_req_sel(swin_resparam_req_sel),.resparam_resp_valid(swin_resparam_resp_valid),
      .resparam_a_mult(swin_resparam_a_mult),.resparam_a_shift(swin_resparam_a_shift),
      .resparam_b_mult(swin_resparam_b_mult),.resparam_b_shift(swin_resparam_b_shift),
      .relpos_req_valid(swin_relpos_req_valid),.relpos_req_block(swin_relpos_req_block),
      .relpos_req_head(swin_relpos_req_head),.relpos_req_query(swin_relpos_req_query),
      .relpos_resp_valid(swin_relpos_resp_valid),.relpos_resp_bias(swin_relpos_resp_bias),
      .exp_req_valid(swin_exp_req_valid),.exp_req_block(swin_exp_req_block),
      .exp_req_delta(swin_exp_req_delta),.exp_resp_valid(swin_exp_resp_valid),.exp_resp_value(swin_exp_resp_value),
      .client_req(client_req[1]),.client_grant(client_grant[1]),
      .client_cfg_tokens_m1(client_cfg_tokens_m1[1]),.client_cfg_k_tiles_m1(swin_cfg_k_tiles_m1),
      .client_cfg_n_tiles_m1(swin_cfg_n_tiles_m1),.client_input_valid(client_input_valid[1]),
      .client_weight_valid(client_weight_valid[1]),.client_input_vector(client_input_vector[1]),
      .client_weight_row_values(client_weight_row_values[1]),
      .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile(svc_active_ci_tile[3:0]),
      .svc_active_co_tile(svc_active_co_tile[3:0]),.svc_weight_row_load,.svc_weight_row_index,.svc_done,
      .svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile(svc_raw_co_tile[3:0]),.svc_raw_acc,
      .post_in_valid(post_client_valid[1]),.post_in_route(post_client_route[1]),
      .post_in_op(post_client_op[1]),.post_in_layer(post_client_layer[1]),
      .post_in_token(post_client_token[1]),.post_in_co(post_client_co[1]),
      .post_in_value(post_client_value[1]),.post_in_multiplier(post_client_multiplier[1]),
      .post_in_shift(post_client_shift[1]),.post_out_valid,.post_out_route,.post_out_op,.post_out_layer,
      .post_out_token,.post_out_co,.post_out_code,.active_block(swin_active_block),
      .engine_state(swin_engine_state),.block_cycle_count(swin_block_cycle_count)
    );

    // --------------------- Post-Swin FPN/head client ----------------------
    // All 29 convs, including 4-channel and 1-channel prediction layers, use
    // this same global 32x32 service.  Unused prediction lanes are masked.
    post_swin_fpn_head_shared32_client u_post_swin_fpn_head (
        .clk,.rst_n(child_rst_n),.start(post_start),.abort,.busy(post_busy),.done(post_done),
        .stage_id(post_stage_id),.stage_prepare_req(post_stage_prepare_req),
        .stage_prepare_done(post_stage_prepare_done),.stage_done_pulse(post_stage_done_pulse),
        .stage_prefetch_req(post_stage_prefetch_req),
        .stage_prefetch_id(post_stage_prefetch_id),
        .p3_stream_active(p3_head_stream_active),
        .p3_stream_phase(p3_head_stream_phase),
        .adapter_stream_valid(post_adapter_stream_valid),.adapter_token(post_adapter_token),
        .adapter_ci_tile(post_adapter_ci_tile),.adapter_co_tile(post_adapter_co_tile),
        .adapter_weight_row_load(post_adapter_weight_row_load),
        .adapter_weight_row_index(post_adapter_weight_row_index),
        .adapter_input_vector(post_adapter_input_vector),
        .adapter_weight_row_values(post_adapter_weight_row_values),
        .adapter_post_co_tile(post_adapter_post_co_tile),.adapter_bias(post_adapter_bias),
        .adapter_multiplier(post_adapter_multiplier),.adapter_shift(post_adapter_shift),
        .adapter_poly_code(post_adapter_poly_code),.adapter_poly_value(post_adapter_poly_value),
        .client_req(client_req[2]),.client_grant(client_grant[2]),
        .client_cfg_tokens_m1(client_cfg_tokens_m1[2]),
        .client_cfg_k_tiles_m1(client_cfg_k_tiles_m1[2]),
        .client_cfg_n_tiles_m1(client_cfg_n_tiles_m1[2]),
        .client_input_vector(client_input_vector[2]),
        .client_weight_row_values(client_weight_row_values[2]),
        .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
        .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,
        .svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
        .post_in_valid(post_client_valid[2]),.post_in_route(post_client_route[2]),
        .post_in_op(post_client_op[2]),.post_in_layer(post_client_layer[2]),
        .post_in_token(post_client_token[2]),.post_in_co(post_client_co[2]),
        .post_in_value(post_client_value[2]),
        .post_in_multiplier(post_client_multiplier[2]),.post_in_shift(post_client_shift[2]),
        .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,
        .post_out_co,.post_out_code,.out_valid(fpn_head_out_valid),
        .out_stage_id(fpn_head_out_stage_id),.out_token(fpn_head_out_token),
        .out_co_tile(fpn_head_out_co_tile),.out_lane_mask(fpn_head_out_lane_mask),
        .out_data(fpn_head_out_data),.stage_vector_count(post_stage_vector_count)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (child_rst_n && !$onehot0(post_client_valid))
            $fatal(1, "projection_swin_fpn_head_shared32_singleengine_top: simultaneous global requant producers");
        if (child_rst_n && projection_done && !projection_counts_complete)
            $fatal(1,
              "TOP_PROJECTION_DONE_EARLY P3=%0d/%0d P4=%0d/%0d P5=%0d/%0d",
              p3_proj_vec_count_q, P3_EXPECTED_PROJ_VECS,
              p4_proj_vec_count_q, P4_EXPECTED_PROJ_VECS,
              p5_proj_vec_count_q, P5_EXPECTED_PROJ_VECS);
    end
`endif
endmodule
