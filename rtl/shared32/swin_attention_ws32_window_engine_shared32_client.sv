`timescale 1ns/1ps
// ============================================================================
// swin_attention_ws32_window_engine_shared32_client.sv
//
// Local-window attention client for ONE shared swin_shared32_mac_service.
// This module replaces the two private dense_ws32x32_controller instances
// (QK and PV) with requests to the shared service.
//
// QK mode: S8 Q x S8 K, both sign-extended to 9-bit service lanes.
// PV mode: U8 P x S8 V, P is zero-extended to positive 9-bit, V sign-extended.
// ============================================================================
(* use_dsp = "no" *)
module swin_attention_ws32_window_engine_shared32_client #(
    parameter int HEADS    = 4,
    parameter int TOKENS   = 25,
    parameter int HEAD_DIM = 32,
    parameter int LANES    = 32,
    parameter int CHUNKS   = HEAD_DIM / LANES,
    parameter int SOFTMAX_LANES = 4,
    parameter int SOFTMAX_DIV_LANES = 1,
    parameter int TOK_W    = (TOKENS <= 1) ? 1 : $clog2(TOKENS),
    parameter int CO_W     = ((HEADS*CHUNKS) <= 1) ? 1 : $clog2(HEADS*CHUNKS),
    parameter logic signed [31:0] QK_M = 32'sd1,
    parameter int QK_SHIFT = 31,
    parameter logic signed [31:0] CTX_M = 32'sd1,
    parameter int CTX_SHIFT = 31,
    parameter [8*256-1:0] RELPOS_EXPANDED_MEM = "relpos_expanded_i16.mem",
    parameter [8*256-1:0] EXP_LUT_MEM = "softmax_exp_lut_u16.mem"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    output logic busy,
    output logic done,

    input logic signed [LANES*8-1:0] q_mem [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
    input logic signed [LANES*8-1:0] k_mem [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
    input logic signed [LANES*8-1:0] v_mem [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [TOK_W-1:0]       out_token,
    output logic [CO_W-1:0]        out_co_tile,
    output logic signed [LANES*8-1:0] out_data,

    // Shared service client port.
    output logic client_req,
    input  logic client_grant,
    output logic [11:0] client_cfg_tokens_m1,
    output logic [3:0]  client_cfg_k_tiles_m1,
    output logic [3:0]  client_cfg_n_tiles_m1,
    output logic client_input_valid,
    output logic client_weight_valid,
    output logic signed [8:0] client_input_vector [0:31],
    output logic signed [8:0] client_weight_row_values [0:31],

    input  logic svc_stream_valid,
    input  logic [11:0] svc_stream_token_id,
    input  logic [3:0]  svc_active_ci_tile,
    input  logic [3:0]  svc_active_co_tile,
    input  logic svc_weight_row_load,
    input  logic [4:0] svc_weight_row_index,
    input  logic svc_done,
    input  logic svc_raw_valid,
    input  logic [11:0] svc_raw_token_id,
    input  logic [3:0]  svc_raw_co_tile,
    input  logic signed [63:0] svc_raw_acc [0:31]
);
    import fixedpoint_pkg::*;

    localparam int PE_K = 32;
    localparam int PE_N = 32;
    localparam int QK_CIN_PAD   = ((HEAD_DIM + PE_K - 1) / PE_K) * PE_K;
    localparam int QK_COUT_PAD  = ((TOKENS   + PE_N - 1) / PE_N) * PE_N;
    localparam int PV_CIN_PAD   = ((TOKENS   + PE_K - 1) / PE_K) * PE_K;
    localparam int PV_COUT_PAD  = ((HEAD_DIM + PE_N - 1) / PE_N) * PE_N;
    localparam int QK_CI_TILES = QK_CIN_PAD / PE_K;
    localparam int QK_CO_TILES = QK_COUT_PAD / PE_N;
    localparam int PV_CI_TILES = PV_CIN_PAD / PE_K;
    localparam int PV_CO_TILES = PV_COUT_PAD / PE_N;
    localparam int HEAD_W  = (HEADS <= 1) ? 1 : $clog2(HEADS);
    localparam int RLEN    = HEADS * TOKENS * TOKENS;
    localparam logic [11:0] TOKENS_M1_C = TOKENS - 1;
    localparam logic [3:0] QK_CI_TILES_M1_C = QK_CI_TILES - 1;
    localparam logic [3:0] QK_CO_TILES_M1_C = QK_CO_TILES - 1;
    localparam logic [3:0] PV_CI_TILES_M1_C = PV_CI_TILES - 1;
    localparam logic [3:0] PV_CO_TILES_M1_C = PV_CO_TILES - 1;

    logic signed [15:0] relpos [0:RLEN-1];
    logic        [15:0] exp_lut [0:255];
    logic signed [7:0] logits [0:HEADS-1][0:TOKENS-1][0:TOKENS-1];
    logic        [7:0] probs  [0:HEADS-1][0:TOKENS-1][0:TOKENS-1];
    logic signed [LANES*8-1:0] ctx  [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];

    logic [HEAD_W-1:0] head_q;
    logic [HEAD_W-1:0] sm_head;
    logic [TOK_W-1:0]  sm_query;
    logic [TOK_W-1:0]  sm_key;
    logic signed [7:0] soft_max_q;
    logic [31:0] soft_denom_q;
    logic [TOK_W-1:0]  emit_query;
    logic [CO_W-1:0]   emit_co;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_QK_LAUNCH,
        ST_QK_RUN,
        ST_SM_MAX_INIT,
        ST_SM_MAX,
        ST_SM_SUM,
        ST_SM_DIV,
        ST_PV_LAUNCH,
        ST_PV_RUN,
        ST_EMIT,
        ST_FINISH
    } state_t;
    state_t st_q;

    logic mode_pv;
    assign mode_pv = (st_q == ST_PV_LAUNCH) || (st_q == ST_PV_RUN);

    assign client_req = (st_q == ST_QK_LAUNCH) || (st_q == ST_PV_LAUNCH);
    assign client_cfg_tokens_m1  = TOKENS_M1_C;
    assign client_cfg_k_tiles_m1 = mode_pv ? PV_CI_TILES_M1_C : QK_CI_TILES_M1_C;
    assign client_cfg_n_tiles_m1 = mode_pv ? PV_CO_TILES_M1_C : QK_CO_TILES_M1_C;
    assign client_input_valid = 1'b1;
    assign client_weight_valid = 1'b1;

    function automatic logic signed [7:0] clamp_s8(input longint signed x);
        begin clamp_s8 = sat_s8(x); end
    endfunction

    function automatic logic [7:0] div_round_uq08(input logic [31:0] numer,input logic [31:0] denom);
        logic [63:0] work;
        logic [7:0] quotient;

        begin
            if (denom == 0) div_round_uq08 = 8'd0;
            else begin
                work = numer + (denom >> 1);
                quotient = 8'd0;
                for (int bit_i =7; bit_i>=0; bit_i=bit_i-1) begin
                    if (work >= ({32'd0, denom} << bit_i)) begin
                        work = work - ({32'd0, denom} << bit_i);
                        quotient = quotient | (8'd1 << bit_i);
                    end
                end
                div_round_uq08 = quotient;
            end
        end
    endfunction

    always_comb begin : build_mac_vectors
        // Defaults.
        for (int l =0; l<PE_K; l=l+1) client_input_vector[l] = '0;
        for (int l =0; l<PE_N; l=l+1) client_weight_row_values[l] = '0;

        if (!mode_pv) begin
            // QK: input row = Q[query, dim], weight columns = K[key, dim].
            for (int l =0; l<PE_K; l=l+1) begin
                int dim_idx;
                dim_idx = svc_active_ci_tile * PE_K + l;
                if (dim_idx < HEAD_DIM)
                    client_input_vector[l] = {q_mem[head_q][svc_stream_token_id[TOK_W-1:0]][dim_idx/LANES][(dim_idx%LANES)*8+7],
                                              q_mem[head_q][svc_stream_token_id[TOK_W-1:0]][dim_idx/LANES][(dim_idx%LANES)*8 +: 8]};
            end
            for (int l =0; l<PE_N; l=l+1) begin
                int dim_idx;
                int key_idx;
                dim_idx = svc_active_ci_tile * PE_K + svc_weight_row_index;
                key_idx = svc_active_co_tile * PE_N + l;
                if ((dim_idx < HEAD_DIM) && (key_idx < TOKENS))
                    client_weight_row_values[l] = {k_mem[head_q][key_idx][dim_idx/LANES][(dim_idx%LANES)*8+7],
                                                   k_mem[head_q][key_idx][dim_idx/LANES][(dim_idx%LANES)*8 +: 8]};
            end
        end else begin
            // PV: input row = prob[query,key] as positive U8, weight columns = V[key,dim].
            for (int l =0; l<PE_K; l=l+1) begin
                int key_idx;
                key_idx = svc_active_ci_tile * PE_K + l;
                if (key_idx < TOKENS)
                    client_input_vector[l] = {1'b0, probs[head_q][svc_stream_token_id[TOK_W-1:0]][key_idx]};
            end
            for (int l =0; l<PE_N; l=l+1) begin
                int key_idx;
                int dim_idx;
                key_idx = svc_active_ci_tile * PE_K + svc_weight_row_index;
                dim_idx = svc_active_co_tile * PE_N + l;
                if ((key_idx < TOKENS) && (dim_idx < HEAD_DIM))
                    client_weight_row_values[l] = {v_mem[head_q][key_idx][dim_idx/LANES][(dim_idx%LANES)*8+7],
                                                   v_mem[head_q][key_idx][dim_idx/LANES][(dim_idx%LANES)*8 +: 8]};
            end
        end
    end

    always_comb begin
        out_valid = (st_q == ST_EMIT);
        out_token = emit_query;
        out_co_tile = emit_co;
        out_data = ctx[emit_co / CHUNKS][emit_query][emit_co % CHUNKS];
        busy = (st_q != ST_IDLE) && (st_q != ST_FINISH);
    end

    initial begin
        for (int init_i =0; init_i<RLEN; init_i=init_i+1) relpos[init_i] = '0;
        for (int init_i =0; init_i<256; init_i=init_i+1) exp_lut[init_i] = '0;
        $readmemh(RELPOS_EXPANDED_MEM, relpos);
        $readmemh(EXP_LUT_MEM, exp_lut);
    end

    longint signed qk_scaled;
    longint signed pv_scaled;
    logic signed [7:0] sm_max_chunk;
    logic [31:0] sm_sum_chunk;

    always_comb begin : softmax_chunk_comb
        sm_max_chunk = soft_max_q;
        sm_sum_chunk = 32'd0;
        for (int sm_lane = 0; sm_lane < SOFTMAX_LANES; sm_lane = sm_lane + 1) begin
            int sm_idx;
            sm_idx = $unsigned(sm_key) + sm_lane;
            if (sm_idx < TOKENS) begin
                if (logits[sm_head][sm_query][sm_idx] > sm_max_chunk)
                    sm_max_chunk = logits[sm_head][sm_query][sm_idx];
                sm_sum_chunk = sm_sum_chunk +
                    {16'd0, exp_lut[$unsigned(soft_max_q - logits[sm_head][sm_query][sm_idx])]};
            end
        end
    end

    function automatic logic [7:0] soft_prob_at(input int key_idx);
        logic [31:0] exp_wide;
        logic [31:0] numer;
        begin
            exp_wide = {16'd0, exp_lut[$unsigned(soft_max_q - logits[sm_head][sm_query][key_idx])]};
            numer = (exp_wide << 8) - exp_wide;
            soft_prob_at = div_round_uq08(numer, soft_denom_q);
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q <= ST_IDLE;
            done <= 1'b0;
            head_q <= '0;
            sm_head <= '0;
            sm_query <= '0;
            sm_key <= '0;
            soft_max_q <= '0;
            soft_denom_q <= '0;
            emit_query <= '0;
            emit_co <= '0;
        end else begin
            done <= 1'b0;

            if (svc_raw_valid && client_grant && !mode_pv) begin
                for (int lane_i =0; lane_i<PE_N; lane_i=lane_i+1) begin
                    int key_idx;
                    int rel_idx;
                    key_idx = svc_raw_co_tile * PE_N + lane_i;
                    if (key_idx < TOKENS) begin
                        rel_idx = head_q*TOKENS*TOKENS + svc_raw_token_id[TOK_W-1:0]*TOKENS + key_idx;
                        qk_scaled = apply_mshift(svc_raw_acc[lane_i], QK_M, QK_SHIFT);
                        logits[head_q][svc_raw_token_id[TOK_W-1:0]][key_idx] <= clamp_s8(qk_scaled + relpos[rel_idx]);
                    end
                end
            end

            if (svc_raw_valid && client_grant && mode_pv) begin
                for (int lane_i =0; lane_i<PE_N; lane_i=lane_i+1) begin
                    int dim_idx;
                    dim_idx = svc_raw_co_tile * PE_N + lane_i;
                    if (dim_idx < HEAD_DIM) begin
                        pv_scaled = apply_mshift(svc_raw_acc[lane_i], CTX_M, CTX_SHIFT);
                        ctx[head_q][svc_raw_token_id[TOK_W-1:0]][dim_idx / LANES][(dim_idx % LANES)*8 +: 8] <= clamp_s8(pv_scaled);
                    end
                end
            end

            case (st_q)
                ST_IDLE: begin
                    if (start) begin head_q <= '0; st_q <= ST_QK_LAUNCH; end
                end
                ST_QK_LAUNCH: begin
                    if (client_grant) st_q <= ST_QK_RUN;
                end
                ST_QK_RUN: begin
                    if (svc_done && client_grant) begin
                        if (head_q == HEADS-1) begin sm_head <= '0; sm_query <= '0; sm_key <= '0; st_q <= ST_SM_MAX_INIT; end
                        else begin head_q <= head_q + 1'b1; st_q <= ST_QK_LAUNCH; end
                    end
                end
                ST_SM_MAX_INIT: begin
                    soft_max_q <= logits[sm_head][sm_query][0];
                    sm_key <= '0;
                    st_q <= ST_SM_MAX;
                end
                ST_SM_MAX: begin
                    soft_max_q <= sm_max_chunk;
                    if (($unsigned(sm_key) + SOFTMAX_LANES) >= TOKENS) begin
                        sm_key <= '0;
                        soft_denom_q <= '0;
                        st_q <= ST_SM_SUM;
                    end else begin
                        sm_key <= sm_key + TOK_W'(SOFTMAX_LANES);
                    end
                end
                ST_SM_SUM: begin
                    soft_denom_q <= soft_denom_q + sm_sum_chunk;
                    if (($unsigned(sm_key) + SOFTMAX_LANES) >= TOKENS) begin
                        sm_key <= '0;
                        st_q <= ST_SM_DIV;
                    end else begin
                        sm_key <= sm_key + TOK_W'(SOFTMAX_LANES);
                    end
                end
                ST_SM_DIV: begin
                    // V6.2: use one exact divider datapath by default.  The
                    // max and denominator scans remain four-lane; probability
                    // normalization is serialized to avoid four replicated
                    // restoring-divider networks.
                    for (int sm_lane = 0; sm_lane < SOFTMAX_DIV_LANES; sm_lane = sm_lane + 1) begin
                        int sm_idx;
                        sm_idx = $unsigned(sm_key) + sm_lane;
                        if (sm_idx < TOKENS)
                            probs[sm_head][sm_query][sm_idx] <= soft_prob_at(sm_idx);
                    end
                    if (($unsigned(sm_key) + SOFTMAX_DIV_LANES) >= TOKENS) begin
                        sm_key <= '0;
                        if (sm_query == TOKENS-1) begin
                            sm_query <= '0;
                            if (sm_head == HEADS-1) begin
                                head_q <= '0;
                                st_q <= ST_PV_LAUNCH;
                            end else begin
                                sm_head <= sm_head + 1'b1;
                                st_q <= ST_SM_MAX_INIT;
                            end
                        end else begin
                            sm_query <= sm_query + 1'b1;
                            st_q <= ST_SM_MAX_INIT;
                        end
                    end else begin
                        sm_key <= sm_key + TOK_W'(SOFTMAX_DIV_LANES);
                    end
                end
                ST_PV_LAUNCH: begin
                    if (client_grant) st_q <= ST_PV_RUN;
                end
                ST_PV_RUN: begin
                    if (svc_done && client_grant) begin
                        if (head_q == HEADS-1) begin emit_query <= '0; emit_co <= '0; st_q <= ST_EMIT; end
                        else begin head_q <= head_q + 1'b1; st_q <= ST_PV_LAUNCH; end
                    end
                end
                ST_EMIT: begin
                    if (out_ready) begin
                        if (emit_co == HEADS*CHUNKS-1) begin
                            emit_co <= '0;
                            if (emit_query == TOKENS-1) st_q <= ST_FINISH;
                            else emit_query <= emit_query + 1'b1;
                        end else emit_co <= emit_co + 1'b1;
                    end
                end
                ST_FINISH: begin done <= 1'b1; st_q <= ST_IDLE; end
                default: st_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((HEAD_DIM % LANES) != 0) $fatal(1,"attention shared32: HEAD_DIM must be multiple of LANES");
        if ((HEADS * HEAD_DIM) % LANES != 0) $fatal(1,"attention shared32: output channel count must fit lanes");
        if ((SOFTMAX_LANES < 1) || (SOFTMAX_LANES > TOKENS))
            $fatal(1,"attention shared32: invalid SOFTMAX_LANES=%0d TOKENS=%0d", SOFTMAX_LANES, TOKENS);
        if ((SOFTMAX_DIV_LANES < 1) || (SOFTMAX_DIV_LANES > TOKENS))
            $fatal(1,"attention shared32: invalid SOFTMAX_DIV_LANES=%0d TOKENS=%0d", SOFTMAX_DIV_LANES, TOKENS);
    end
`endif
endmodule
