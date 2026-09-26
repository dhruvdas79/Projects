`timescale 1ns/1ps
// ============================================================================
// swin_shared32_arbiter8.sv
//
// Priority arbiter/mux for up to 8 MAC clients sharing one physical
// swin_shared32_mac_service. Client 0 has highest priority. A grant is held
// until the service asserts done; then the next pending client may start.
//
// The service timing outputs are broadcast to all clients. Only the granted
// client should drive meaningful vector values; the arbiter muxes that client's
// vectors into the shared service. Raw service outputs may be broadcast to all
// clients; only the granted/active client should consume them.
// ============================================================================
module swin_shared32_arbiter8 #(
    parameter int NUM_CLIENTS = 8,
    parameter int PE_K = 32,
    parameter int PE_N = 32,
    parameter int DATA_W = 9,
    parameter int TOKEN_W = 12,
    parameter int TILE_W = 4
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [NUM_CLIENTS-1:0] client_req,
    output logic [NUM_CLIENTS-1:0] client_grant,

    input  logic [TOKEN_W-1:0] client_cfg_tokens_m1 [0:NUM_CLIENTS-1],
    input  logic [TILE_W-1:0]  client_cfg_k_tiles_m1 [0:NUM_CLIENTS-1],
    input  logic [TILE_W-1:0]  client_cfg_n_tiles_m1 [0:NUM_CLIENTS-1],

    input  logic client_input_valid [0:NUM_CLIENTS-1],
    input  logic client_weight_valid [0:NUM_CLIENTS-1],
    input  logic signed [DATA_W-1:0] client_input_vector [0:NUM_CLIENTS-1][0:PE_K-1],
    input  logic signed [DATA_W-1:0] client_weight_row_values [0:NUM_CLIENTS-1][0:PE_N-1],

    output logic svc_start,
    input  logic svc_busy,
    input  logic svc_done,
    output logic [TOKEN_W-1:0] svc_cfg_tokens_m1,
    output logic [TILE_W-1:0]  svc_cfg_k_tiles_m1,
    output logic [TILE_W-1:0]  svc_cfg_n_tiles_m1,
    output logic svc_input_valid,
    output logic svc_weight_valid,
    output logic signed [DATA_W-1:0] svc_input_vector [0:PE_K-1],
    output logic signed [DATA_W-1:0] svc_weight_row_values [0:PE_N-1]
);
    localparam int SEL_W = (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS);
    typedef enum logic [1:0] {A_IDLE,A_START,A_RUN} state_t;
    state_t st_q;
    logic [SEL_W-1:0] active_sel;
    logic [SEL_W-1:0] next_sel;
    logic any_req;

    always_comb begin
        any_req = 1'b0;
        next_sel = '0;
        for (int i =NUM_CLIENTS-1; i>=0; i=i-1) begin
            if (client_req[i]) begin
                any_req = 1'b1;
                next_sel = i[SEL_W-1:0];
            end
        end
    end

    always_comb begin
        client_grant = '0;
        if (st_q != A_IDLE) client_grant[active_sel] = 1'b1;
        svc_start = (st_q == A_START);

        svc_cfg_tokens_m1  = client_cfg_tokens_m1[active_sel];
        svc_cfg_k_tiles_m1 = client_cfg_k_tiles_m1[active_sel];
        svc_cfg_n_tiles_m1 = client_cfg_n_tiles_m1[active_sel];
        svc_input_valid = client_input_valid[active_sel];
        svc_weight_valid = client_weight_valid[active_sel];

        for (int j =0; j<PE_K; j=j+1)
            svc_input_vector[j] = client_input_vector[active_sel][j];
        for (int j =0; j<PE_N; j=j+1)
            svc_weight_row_values[j] = client_weight_row_values[active_sel][j];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q <= A_IDLE;
            active_sel <= '0;
        end else begin
            case (st_q)
                A_IDLE: begin
                    if (any_req) begin
                        active_sel <= next_sel;
                        st_q <= A_START;
                    end
                end
                A_START: begin
                    st_q <= A_RUN;
                end
                A_RUN: begin
                    if (svc_done) st_q <= A_IDLE;
                end
                default: st_q <= A_IDLE;
            endcase
        end
    end
endmodule
