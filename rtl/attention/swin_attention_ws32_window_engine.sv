`timescale 1ns/1ps
// ============================================================================
// swin_attention_ws32_window_engine.sv
//
// Exact-order, local-window attention engine using the SAME verified
// ws_systolic_pe + ws32x32_weight_stationary_core datapath as Q/K/V, output
// projection, FC1 and FC2.
//
// QK mapping for one head:
//   activation row = Q[query, d]
//   weight column  = K[key, d]      (K is loaded transposed as weights)
//   output lane    = key
//
// PV mapping for one head:
//   activation row = P_u8[query, key], zero-extended to signed 9-bit
//   weight column  = V[key, d]
//   output lane    = d
//
// The dense controller is used with padded 16-lane tiles:
//   * P4 QK key outputs: 25 -> 32 lanes, lanes 25..31 are zero/discarded.
//   * P3 QK key outputs: 16 -> 32 lanes, second tile is zero/discarded.
//   * P4/P3 PV key inputs are padded to 32 lanes when needed.
// This preserves arithmetic for the valid tokens while allowing one common
// 32x32 weight-stationary PE array for dense, QK, and PV.
// ============================================================================
module swin_attention_ws32_window_engine #(
    parameter int HEADS    = 4,
    parameter int TOKENS   = 25,
    parameter int HEAD_DIM = 32,
    parameter int LANES    = 32,

    parameter int CHUNKS   = HEAD_DIM / LANES,
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

    // Local one-window Q/K/V scratch memories. Each entry is 16 INT8 codes.
    input logic signed [LANES*8-1:0] q_mem [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
    input logic signed [LANES*8-1:0] k_mem [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
    input logic signed [LANES*8-1:0] v_mem [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],

    // Context stream. co_tile is in whole-128-channel output tile numbering:
    // [head][chunk] => co_tile = head*CHUNKS + chunk.
    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [TOK_W-1:0]       out_token,
    output logic [CO_W-1:0]        out_co_tile,
    output logic signed [LANES*8-1:0]    out_data
);
    import fixedpoint_pkg::*;

    localparam int PE_K = 32;
    localparam int PE_N = 32;

    // All controller dimensions are padded to multiples of 16. This avoids
    // zero-width $clog2(1) ports in the retained verified dense controller.
    localparam int QK_CIN_PAD   = ((HEAD_DIM + PE_K - 1) / PE_K) * PE_K;
    localparam int QK_COUT_PAD  = ((TOKENS   + PE_N - 1) / PE_N) * PE_N;
    localparam int PV_CIN_PAD   = ((TOKENS   + PE_K - 1) / PE_K) * PE_K;
    localparam int PV_COUT_PAD  = ((HEAD_DIM + PE_N - 1) / PE_N) * PE_N;

    localparam int QK_CI_TILES = QK_CIN_PAD / PE_K;
    localparam int QK_CO_TILES = QK_COUT_PAD / PE_N;
    localparam int PV_CI_TILES = PV_CIN_PAD / PE_K;
    localparam int PV_CO_TILES = PV_COUT_PAD / PE_N;

    localparam int QK_CI_W = (QK_CI_TILES <= 1) ? 1 : $clog2(QK_CI_TILES);
    localparam int QK_CO_W = (QK_CO_TILES <= 1) ? 1 : $clog2(QK_CO_TILES);
    localparam int PV_CI_W = (PV_CI_TILES <= 1) ? 1 : $clog2(PV_CI_TILES);
    localparam int PV_CO_W = (PV_CO_TILES <= 1) ? 1 : $clog2(PV_CO_TILES);
    localparam int HEAD_W  = (HEADS <= 1) ? 1 : $clog2(HEADS);
    localparam int CHUNK_W = (CHUNKS <= 1) ? 1 : $clog2(CHUNKS);
    localparam int RLEN    = HEADS * TOKENS * TOKENS;

    // Model memories: expanded relpos is indexed [head][query][key].
    logic signed [15:0] relpos [0:RLEN-1];
    logic        [15:0] exp_lut [0:255];

    // Local computed state. These remain local-window scratch only.
    logic signed [7:0] logits [0:HEADS-1][0:TOKENS-1][0:TOKENS-1];
    logic        [7:0] probs  [0:HEADS-1][0:TOKENS-1][0:TOKENS-1];
    logic signed [LANES*8-1:0] ctx  [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];

    // Current head for QK/PV computation.
    logic [HEAD_W-1:0] head_q;

    // QK controller wiring. Q/K are signed INT8.
    logic signed [7:0] qk_input_vector [0:PE_K-1];
    logic signed [7:0] qk_weight_row   [0:PE_N-1];
    logic qk_stream_valid;
    logic [TOK_W-1:0] qk_stream_token;
    logic [QK_CI_W-1:0] qk_active_ci;
    logic [QK_CO_W-1:0] qk_active_co;
    logic qk_weight_row_load;
    logic [$clog2(PE_K)-1:0] qk_weight_row_index;
    logic qk_raw_valid;
    logic [TOK_W-1:0] qk_raw_token;
    logic [QK_CO_W-1:0] qk_raw_co;
    logic signed [63:0] qk_raw_acc [0:PE_N-1];
    logic qk_busy, qk_done;

    // PV controller wiring. P_u8 is zero-extended to signed 9-bit and V is
    // sign-extended to 9-bit; that lets the same PE execute U8 x S8 exactly.
    logic signed [8:0] pv_input_vector [0:PE_K-1];
    logic signed [8:0] pv_weight_row   [0:PE_N-1];
    logic pv_stream_valid;
    logic [TOK_W-1:0] pv_stream_token;
    logic [PV_CI_W-1:0] pv_active_ci;
    logic [PV_CO_W-1:0] pv_active_co;
    logic pv_weight_row_load;
    logic [$clog2(PE_K)-1:0] pv_weight_row_index;
    logic pv_raw_valid;
    logic [TOK_W-1:0] pv_raw_token;
    logic [PV_CO_W-1:0] pv_raw_co;
    logic signed [63:0] pv_raw_acc [0:PE_N-1];
    logic pv_busy, pv_done;

    logic qk_start, pv_start;

    // Softmax iteration and final context output iteration.
    logic [HEAD_W-1:0] sm_head;
    logic [TOK_W-1:0]  sm_query;
    logic [TOK_W-1:0]  emit_query;
    logic [CO_W-1:0]   emit_co;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_QK_LAUNCH,
        ST_QK_RUN,
        ST_SOFTMAX,
        ST_PV_LAUNCH,
        ST_PV_RUN,
        ST_EMIT,
        ST_FINISH
    } state_t;
    state_t st_q;

    // ------------------------------------------------------------------------
    // Small helper functions. They match the strict use of signed ties-away
    // rounding and UQ0.8 softmax codes (probability code/255).
    // ------------------------------------------------------------------------
    function automatic logic signed [7:0] clamp_s8(input longint signed x);
        begin
            clamp_s8 = sat_s8(x);
        end
    endfunction

    function automatic logic [7:0] div_round_uq08(
        input logic [31:0] numer,
        input logic [31:0] denom
    );
        logic [63:0] work;
        logic [7:0] quotient;
        integer bit_i;
        begin
            if (denom == 0) begin
                div_round_uq08 = 8'd0;
            end else begin
                // round(numer/denom), where numer = exp * 255.
                work = numer + (denom >> 1);
                quotient = 8'd0;
                for (bit_i=7; bit_i>=0; bit_i=bit_i-1) begin
                    if (work >= ({32'd0, denom} << bit_i)) begin
                        work = work - ({32'd0, denom} << bit_i);
                        quotient = quotient | (8'd1 << bit_i);
                    end
                end
                div_round_uq08 = quotient;
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // Dynamic QK and PV adapters. The dense controller keeps its verified
    // weight-load/stream/psum/deskew sequence. These adapters merely map the
    // local attention scratch into its activation and weight ports.
    // ------------------------------------------------------------------------
    integer qk_l;
    integer qk_dim;
    integer qk_key;
    always_comb begin
        for (qk_l=0; qk_l<PE_K; qk_l=qk_l+1) begin
            qk_dim = qk_active_ci * PE_K + qk_l;
            if (qk_dim < HEAD_DIM)
                qk_input_vector[qk_l] = q_mem[head_q][qk_stream_token]
                                                   [qk_dim / LANES]
                                                   [(qk_dim % LANES)*8 +: 8];
            else
                qk_input_vector[qk_l] = '0;
        end

        for (qk_l=0; qk_l<PE_N; qk_l=qk_l+1) begin
            qk_dim = qk_active_ci * PE_K + qk_weight_row_index;
            qk_key = qk_active_co * PE_N + qk_l;
            if ((qk_dim < HEAD_DIM) && (qk_key < TOKENS))
                qk_weight_row[qk_l] = k_mem[head_q][qk_key]
                                                   [qk_dim / LANES]
                                                   [(qk_dim % LANES)*8 +: 8];
            else
                qk_weight_row[qk_l] = '0;
        end
    end

    integer pv_l;
    integer pv_key;
    integer pv_dim;
    always_comb begin
        for (pv_l=0; pv_l<PE_K; pv_l=pv_l+1) begin
            pv_key = pv_active_ci * PE_K + pv_l;
            if (pv_key < TOKENS)
                pv_input_vector[pv_l] = $signed({1'b0, probs[head_q][pv_stream_token][pv_key]});
            else
                pv_input_vector[pv_l] = '0;
        end

        for (pv_l=0; pv_l<PE_N; pv_l=pv_l+1) begin
            pv_key = pv_active_ci * PE_K + pv_weight_row_index;
            pv_dim = pv_active_co * PE_N + pv_l;
            if ((pv_key < TOKENS) && (pv_dim < HEAD_DIM))
                pv_weight_row[pv_l] = $signed({v_mem[head_q][pv_key]
                                                       [pv_dim / LANES]
                                                       [(pv_dim % LANES)*8 + 7],
                                                v_mem[head_q][pv_key]
                                                       [pv_dim / LANES]
                                                       [(pv_dim % LANES)*8 +: 8]});
            else
                pv_weight_row[pv_l] = '0;
        end
    end

    dense_ws32x32_controller #(
        .TOKENS(TOKENS), .CIN(QK_CIN_PAD), .COUT(QK_COUT_PAD),
        .PE_K(PE_K), .PE_N(PE_N), .DATA_W(8), .ACC_W(48),
        .TOKEN_ID_W(TOK_W)
    ) u_qk_ws32 (
        .clk(clk), .rst_n(rst_n), .start(qk_start), .busy(qk_busy), .done(qk_done),
        .input_vector(qk_input_vector), .weight_row_values(qk_weight_row),
        .stream_valid(qk_stream_valid), .stream_token_id(qk_stream_token),
        .active_ci_tile(qk_active_ci), .active_co_tile(qk_active_co),
        .weight_row_load(qk_weight_row_load), .weight_row_index(qk_weight_row_index),
        .raw_valid(qk_raw_valid), .raw_token_id(qk_raw_token), .raw_co_tile(qk_raw_co),
        .raw_acc(qk_raw_acc)
    );

    dense_ws32x32_controller #(
        .TOKENS(TOKENS), .CIN(PV_CIN_PAD), .COUT(PV_COUT_PAD),
        .PE_K(PE_K), .PE_N(PE_N), .DATA_W(9), .ACC_W(48),
        .TOKEN_ID_W(TOK_W)
    ) u_pv_ws32 (
        .clk(clk), .rst_n(rst_n), .start(pv_start), .busy(pv_busy), .done(pv_done),
        .input_vector(pv_input_vector), .weight_row_values(pv_weight_row),
        .stream_valid(pv_stream_valid), .stream_token_id(pv_stream_token),
        .active_ci_tile(pv_active_ci), .active_co_tile(pv_active_co),
        .weight_row_load(pv_weight_row_load), .weight_row_index(pv_weight_row_index),
        .raw_valid(pv_raw_valid), .raw_token_id(pv_raw_token), .raw_co_tile(pv_raw_co),
        .raw_acc(pv_raw_acc)
    );

    // Control starts are exactly one clock long.
    always_comb begin
        qk_start  = (st_q == ST_QK_LAUNCH);
        pv_start  = (st_q == ST_PV_LAUNCH);

        out_valid = (st_q == ST_EMIT);
        out_token = emit_query;
        out_co_tile = emit_co;
        out_data = ctx[emit_co / CHUNKS][emit_query][emit_co % CHUNKS];

        busy = (st_q != ST_IDLE) && (st_q != ST_FINISH);
    end

    integer init_i;
    integer init_h;
    integer init_q;
    integer init_k;
    integer init_c;
    initial begin
        for (init_i=0; init_i<RLEN; init_i=init_i+1)
            relpos[init_i] = '0;
        for (init_i=0; init_i<256; init_i=init_i+1)
            exp_lut[init_i] = '0;
        $readmemh(RELPOS_EXPANDED_MEM, relpos);
        $readmemh(EXP_LUT_MEM, exp_lut);
    end

    integer lane_i;
    integer key_i;
    integer dim_i;
    integer rel_i;
    integer soft_k;
    integer soft_i;
    longint signed qk_scaled;
    longint signed pv_scaled;
    logic signed [7:0] soft_max;
    logic [31:0] soft_denom;
    logic [31:0] soft_numer;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q       <= ST_IDLE;
            done       <= 1'b0;
            head_q     <= '0;
            sm_head    <= '0;
            sm_query   <= '0;
            emit_query <= '0;
            emit_co    <= '0;
        end else begin
            done <= 1'b0;

            // QK result capture: output lanes are key columns.
            if (qk_raw_valid) begin
                for (lane_i=0; lane_i<PE_N; lane_i=lane_i+1) begin
                    key_i = qk_raw_co * PE_N + lane_i;
                    if (key_i < TOKENS) begin
                        rel_i = head_q*TOKENS*TOKENS + qk_raw_token*TOKENS + key_i;
                        qk_scaled = apply_mshift(qk_raw_acc[lane_i], QK_M, QK_SHIFT);
                        logits[head_q][qk_raw_token][key_i] <= clamp_s8(qk_scaled + relpos[rel_i]);
                    end
                end
            end

            // PV result capture: output lanes are head-dimension channels.
            if (pv_raw_valid) begin
                for (lane_i=0; lane_i<PE_N; lane_i=lane_i+1) begin
                    dim_i = pv_raw_co * PE_N + lane_i;
                    if (dim_i < HEAD_DIM) begin
                        pv_scaled = apply_mshift(pv_raw_acc[lane_i], CTX_M, CTX_SHIFT);
                        ctx[head_q][pv_raw_token][dim_i / LANES]
                           [(dim_i % LANES)*8 +: 8] <= clamp_s8(pv_scaled);
                    end
                end
            end

            case (st_q)
                ST_IDLE: begin
                    if (start) begin
                        head_q <= '0;
                        st_q <= ST_QK_LAUNCH;
                    end
                end

                ST_QK_LAUNCH: begin
                    st_q <= ST_QK_RUN;
                end

                ST_QK_RUN: begin
                    if (qk_done) begin
                        if (head_q == HEADS-1) begin
                            sm_head <= '0;
                            sm_query <= '0;
                            st_q <= ST_SOFTMAX;
                        end else begin
                            head_q <= head_q + 1'b1;
                            st_q <= ST_QK_LAUNCH;
                        end
                    end
                end

                ST_SOFTMAX: begin
                    // One [head, query] row per clock. The row itself is a
                    // fixed TOKENS-sized hardware loop, matching the frozen
                    // LUT arithmetic and UQ0.8 /255 convention.
                    soft_max = logits[sm_head][sm_query][0];
                    for (soft_k=1; soft_k<TOKENS; soft_k=soft_k+1) begin
                        if (logits[sm_head][sm_query][soft_k] > soft_max)
                            soft_max = logits[sm_head][sm_query][soft_k];
                    end

                    soft_denom = 0;
                    for (soft_k=0; soft_k<TOKENS; soft_k=soft_k+1)
                        soft_denom = soft_denom + exp_lut[$unsigned(soft_max - logits[sm_head][sm_query][soft_k])];

                    for (soft_i=0; soft_i<TOKENS; soft_i=soft_i+1) begin
                        // Widen before multiplying by 255.  A 16-bit left shift
                        // would truncate exp*255 before assignment to soft_numer.
                        soft_numer = {16'd0, exp_lut[$unsigned(soft_max - logits[sm_head][sm_query][soft_i])]} * 32'd255;
                        probs[sm_head][sm_query][soft_i] <= div_round_uq08(soft_numer, soft_denom);
                    end

                    if (sm_query == TOKENS-1) begin
                        sm_query <= '0;
                        if (sm_head == HEADS-1) begin
                            head_q <= '0;
                            st_q <= ST_PV_LAUNCH;
                        end else begin
                            sm_head <= sm_head + 1'b1;
                        end
                    end else begin
                        sm_query <= sm_query + 1'b1;
                    end
                end

                ST_PV_LAUNCH: begin
                    st_q <= ST_PV_RUN;
                end

                ST_PV_RUN: begin
                    if (pv_done) begin
                        if (head_q == HEADS-1) begin
                            emit_query <= '0;
                            emit_co <= '0;
                            st_q <= ST_EMIT;
                        end else begin
                            head_q <= head_q + 1'b1;
                            st_q <= ST_PV_LAUNCH;
                        end
                    end
                end

                ST_EMIT: begin
                    if (out_ready) begin
                        if (emit_co == HEADS*CHUNKS-1) begin
                            emit_co <= '0;
                            if (emit_query == TOKENS-1) begin
                                st_q <= ST_FINISH;
                            end else begin
                                emit_query <= emit_query + 1'b1;
                            end
                        end else begin
                            emit_co <= emit_co + 1'b1;
                        end
                    end
                end

                ST_FINISH: begin
                    done <= 1'b1;
                    st_q <= ST_IDLE;
                end

                default: st_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    // Guard against configuration errors which would silently change ordering.
    initial begin
        if ((HEAD_DIM % LANES) != 0)
            $fatal(1, "attention WS32: HEAD_DIM must be an integer number of 16-lane chunks");
        if ((HEADS * HEAD_DIM) % LANES != 0)
            $fatal(1, "attention WS32: output channel count must fit 16-lane tiles");
    end
`endif
endmodule
