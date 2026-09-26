`timescale 1ns/1ps
// ============================================================================
// swin_block_shared32_local_arbiter5.sv
//
// Local block-level mux for the five MAC clients inside one Swin block:
//   0 QKV, 1 Attention(QK/PV), 2 Attention projection, 3 FC1, 4 FC2.
//
// It does not instantiate a MAC engine. It collapses the five internal client
// request/vector buses into one aggregate block-client bus, which is then
// connected to the global shared32 arbiter/service.
// ============================================================================
module swin_block_shared32_local_arbiter5 #(
    parameter int NUM_CLIENTS = 5,
    parameter int PE_K = 32,
    parameter int PE_N = 32,
    parameter int DATA_W = 9,
    parameter int TOKEN_W = 12,
    parameter int TILE_W = 4
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [NUM_CLIENTS-1:0] client_req_i,
    output logic [NUM_CLIENTS-1:0] client_grant_o,

    input  logic [TOKEN_W-1:0] client_cfg_tokens_m1_i [0:NUM_CLIENTS-1],
    input  logic [TILE_W-1:0]  client_cfg_k_tiles_m1_i [0:NUM_CLIENTS-1],
    input  logic [TILE_W-1:0]  client_cfg_n_tiles_m1_i [0:NUM_CLIENTS-1],
    input  logic client_input_valid_i [0:NUM_CLIENTS-1],
    input  logic client_weight_valid_i [0:NUM_CLIENTS-1],
    input  logic signed [DATA_W-1:0] client_input_vector_i [0:NUM_CLIENTS-1][0:PE_K-1],
    input  logic signed [DATA_W-1:0] client_weight_row_values_i [0:NUM_CLIENTS-1][0:PE_N-1],

    output logic block_req_o,
    input  logic block_grant_i,
    input  logic svc_done_i,
    output logic [TOKEN_W-1:0] block_cfg_tokens_m1_o,
    output logic [TILE_W-1:0]  block_cfg_k_tiles_m1_o,
    output logic [TILE_W-1:0]  block_cfg_n_tiles_m1_o,
    output logic block_input_valid_o,
    output logic block_weight_valid_o,
    output logic signed [DATA_W-1:0] block_input_vector_o [0:PE_K-1],
    output logic signed [DATA_W-1:0] block_weight_row_values_o [0:PE_N-1]
);
    localparam int SEL_W = (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS);
    typedef enum logic [1:0] {L_IDLE,L_WAIT_GRANT,L_RUN} st_t;
    st_t st_q;
    logic [SEL_W-1:0] sel_q, next_sel;
    logic any_req;

    always_comb begin
        any_req = 1'b0;
        next_sel = '0;
        for (int i =NUM_CLIENTS-1; i>=0; i=i-1) begin
            if (client_req_i[i]) begin
                any_req = 1'b1;
                next_sel = i[SEL_W-1:0];
            end
        end
    end

    always_comb begin
        block_req_o = (st_q == L_WAIT_GRANT) || (st_q == L_RUN);
        client_grant_o = '0;
        if ((st_q == L_RUN) && block_grant_i)
            client_grant_o[sel_q] = 1'b1;

        block_cfg_tokens_m1_o  = client_cfg_tokens_m1_i[sel_q];
        block_cfg_k_tiles_m1_o = client_cfg_k_tiles_m1_i[sel_q];
        block_cfg_n_tiles_m1_o = client_cfg_n_tiles_m1_i[sel_q];
        block_input_valid_o = client_input_valid_i[sel_q];
        block_weight_valid_o = client_weight_valid_i[sel_q];
        for (int j =0; j<PE_K; j=j+1)
            block_input_vector_o[j] = client_input_vector_i[sel_q][j];
        for (int j =0; j<PE_N; j=j+1)
            block_weight_row_values_o[j] = client_weight_row_values_i[sel_q][j];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q <= L_IDLE;
            sel_q <= '0;
        end else begin
            case (st_q)
                L_IDLE: begin
                    if (any_req) begin
                        sel_q <= next_sel;
                        st_q <= L_WAIT_GRANT;
                    end
                end
                L_WAIT_GRANT: begin
                    if (block_grant_i) st_q <= L_RUN;
                end
                L_RUN: begin
                    if (block_grant_i && svc_done_i) st_q <= L_IDLE;
                end
                default: st_q <= L_IDLE;
            endcase
        end
    end
endmodule
