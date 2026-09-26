`timescale 1ns/1ps
// ============================================================================
// swin_attention_scheduler.sv
//
// Window scheduler for the common-PE WS16 attention engine.
// It carries window_id through the entire QKV -> context path and reloads all
// Q/K/V local scratch for every window, eliminating the stale-row problem in
// the old partner P-memory flow.
// ============================================================================
module swin_attention_scheduler #(
    parameter int NUM_WINDOWS = 36,
    parameter int TOKENS      = 25,
    parameter int HEADS       = 4,
    parameter int HEAD_DIM    = 32,
    parameter int LANES       = 16,
    parameter int CHUNKS      = HEAD_DIM/LANES,
    parameter int COUT        = HEADS*HEAD_DIM,
    parameter int WIN_W       = (NUM_WINDOWS <= 1) ? 1 : $clog2(NUM_WINDOWS),
    parameter int TOK_W       = (TOKENS <= 1) ? 1 : $clog2(TOKENS),
    parameter int TOKEN_W     = $clog2(NUM_WINDOWS*TOKENS),
    parameter int CO_W        = ((COUT/LANES) <= 1) ? 1 : $clog2(COUT/LANES),
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

    // Flat Q/K/V banked read interface. Token is global window-major token.
    output logic qkv_rd_en,
    output logic [1:0] qkv_rd_op,
    output logic [TOKEN_W-1:0] qkv_rd_token,
    output logic [CO_W-1:0] qkv_rd_co_tile,
    input  logic qkv_rd_valid,
    input  logic signed [127:0] qkv_rd_data,

    // Context write interface retains window identity.
    output logic ctx_wr_valid,
    output logic [WIN_W-1:0] ctx_wr_window,
    output logic [TOK_W-1:0] ctx_wr_token,
    output logic [CO_W-1:0] ctx_wr_co_tile,
    output logic signed [127:0] ctx_wr_data
);
    localparam logic [1:0] OP_Q = 2'd0;
    localparam logic [1:0] OP_K = 2'd1;
    localparam logic [1:0] OP_V = 2'd2;
    localparam int CTILES = COUT/LANES;

    logic signed [127:0] q_local [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];
    logic signed [127:0] k_local [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];
    logic signed [127:0] v_local [0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_LOAD_Q,
        ST_LOAD_K,
        ST_LOAD_V,
        ST_ENGINE_LAUNCH,
        ST_ENGINE_RUN,
        ST_FINISH
    } state_t;
    state_t st_q;

    logic [WIN_W-1:0] active_window;
    logic [TOK_W-1:0] load_token;
    logic [CO_W-1:0]  load_co;

    logic engine_start;
    logic engine_busy;
    logic engine_done;
    logic engine_out_valid;
    logic [TOK_W-1:0] engine_out_token;
    logic [CO_W-1:0] engine_out_co;
    logic signed [127:0] engine_out_data;

    swin_attention_ws16_window_engine #(
        .HEADS(HEADS), .TOKENS(TOKENS), .HEAD_DIM(HEAD_DIM), .LANES(LANES),
        .CHUNKS(CHUNKS), .TOK_W(TOK_W), .CO_W(CO_W),
        .QK_M(QK_M), .QK_SHIFT(QK_SHIFT),
        .CTX_M(CTX_M), .CTX_SHIFT(CTX_SHIFT),
        .RELPOS_EXPANDED_MEM(RELPOS_EXPANDED_MEM),
        .EXP_LUT_MEM(EXP_LUT_MEM)
    ) u_engine (
        .clk(clk), .rst_n(rst_n), .start(engine_start),
        .busy(engine_busy), .done(engine_done),
        .q_mem(q_local), .k_mem(k_local), .v_mem(v_local),
        .out_valid(engine_out_valid), .out_ready(1'b1),
        .out_token(engine_out_token), .out_co_tile(engine_out_co),
        .out_data(engine_out_data)
    );

    always_comb begin
        qkv_rd_en = (st_q == ST_LOAD_Q) || (st_q == ST_LOAD_K) || (st_q == ST_LOAD_V);
        qkv_rd_op = (st_q == ST_LOAD_Q) ? OP_Q :
                    (st_q == ST_LOAD_K) ? OP_K : OP_V;
        qkv_rd_token = active_window*TOKENS + load_token;
        qkv_rd_co_tile = load_co;

        engine_start = (st_q == ST_ENGINE_LAUNCH);

        ctx_wr_valid   = (st_q == ST_ENGINE_RUN) && engine_out_valid;
        ctx_wr_window  = active_window;
        ctx_wr_token   = engine_out_token;
        ctx_wr_co_tile = engine_out_co;
        ctx_wr_data    = engine_out_data;

        busy = (st_q != ST_IDLE) && (st_q != ST_FINISH);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q <= ST_IDLE;
            done <= 1'b0;
            active_window <= '0;
            load_token <= '0;
            load_co <= '0;
        end else begin
            done <= 1'b0;
            case (st_q)
                ST_IDLE: begin
                    if (start) begin
                        active_window <= '0;
                        load_token <= '0;
                        load_co <= '0;
                        st_q <= ST_LOAD_Q;
                    end
                end

                ST_LOAD_Q: begin
                    if (qkv_rd_valid) begin
                        q_local[load_co/CHUNKS][load_token][load_co%CHUNKS] <= qkv_rd_data;
                        if (load_co == CTILES-1) begin
                            load_co <= '0;
                            if (load_token == TOKENS-1) begin
                                load_token <= '0;
                                st_q <= ST_LOAD_K;
                            end else begin
                                load_token <= load_token + 1'b1;
                            end
                        end else begin
                            load_co <= load_co + 1'b1;
                        end
                    end
                end

                ST_LOAD_K: begin
                    if (qkv_rd_valid) begin
                        k_local[load_co/CHUNKS][load_token][load_co%CHUNKS] <= qkv_rd_data;
                        if (load_co == CTILES-1) begin
                            load_co <= '0;
                            if (load_token == TOKENS-1) begin
                                load_token <= '0;
                                st_q <= ST_LOAD_V;
                            end else begin
                                load_token <= load_token + 1'b1;
                            end
                        end else begin
                            load_co <= load_co + 1'b1;
                        end
                    end
                end

                ST_LOAD_V: begin
                    if (qkv_rd_valid) begin
                        v_local[load_co/CHUNKS][load_token][load_co%CHUNKS] <= qkv_rd_data;
                        if (load_co == CTILES-1) begin
                            load_co <= '0;
                            if (load_token == TOKENS-1) begin
                                load_token <= '0;
                                st_q <= ST_ENGINE_LAUNCH;
                            end else begin
                                load_token <= load_token + 1'b1;
                            end
                        end else begin
                            load_co <= load_co + 1'b1;
                        end
                    end
                end

                ST_ENGINE_LAUNCH: begin
                    st_q <= ST_ENGINE_RUN;
                end

                ST_ENGINE_RUN: begin
                    if (engine_done) begin
                        if (active_window == NUM_WINDOWS-1) begin
                            st_q <= ST_FINISH;
                        end else begin
                            active_window <= active_window + 1'b1;
                            load_token <= '0;
                            load_co <= '0;
                            st_q <= ST_LOAD_Q;
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
endmodule
