// ============================================================================
// dense_ws16x16_controller.sv
// Reusable 16x16 weight-stationary dense controller.
//
// One invocation computes: TOKENS x CIN  times  CIN x COUT  -> TOKENS x COUT.
// It reuses the validated ws_systolic_pe, ws16x16_weight_stationary_core
// (including V3 reverse deskew), and psum_banked_mem.
//
// For P4_0 Q/K/V: TOKENS=900, CIN=128, COUT=128, K/N tiles=8/8.
// ============================================================================
module dense_ws16x16_controller #(
    parameter int TOKENS           = 900,
    parameter int CIN              = 128,
    parameter int COUT             = 128,
    parameter int PE_K             = 16,
    parameter int PE_N             = 16,
    parameter int DATA_W           = 8,
    parameter int ACC_W            = 64,
    parameter int DRAIN_CYCLES     = PE_K + PE_N,
    parameter int MEM_DRAIN_CYCLES = 4,
    parameter int TOKEN_ID_W       = (TOKENS <= 1) ? 1 : $clog2(TOKENS)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    output logic                         busy,
    output logic                         done,

    input  logic signed [DATA_W-1:0]     input_vector [0:PE_K-1],
    input  logic signed [DATA_W-1:0]     weight_row_values [0:PE_N-1],

    output logic                         stream_valid,
    output logic [TOKEN_ID_W-1:0]        stream_token_id,
    output logic [$clog2(CIN/PE_K)-1:0]  active_ci_tile,
    output logic [$clog2(COUT/PE_N)-1:0] active_co_tile,
    output logic                         weight_row_load,
    output logic [$clog2(PE_K)-1:0]      weight_row_index,

    output logic                         raw_valid,
    output logic [TOKEN_ID_W-1:0]        raw_token_id,
    output logic [$clog2(COUT/PE_N)-1:0] raw_co_tile,
    output logic signed [ACC_W-1:0]      raw_acc [0:PE_N-1]
);
    localparam int K_TILES = CIN/PE_K;
    localparam int N_TILES = COUT/PE_N;
    localparam int CI_TILE_W = (K_TILES <= 1) ? 1 : $clog2(K_TILES);
    localparam int CO_TILE_W = (N_TILES <= 1) ? 1 : $clog2(N_TILES);
    localparam int WROW_W = (PE_K <= 1) ? 1 : $clog2(PE_K);
    localparam int DRAIN_W = (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);
    localparam int MDRAIN_W = (MEM_DRAIN_CYCLES <= 1) ? 1 : $clog2(MEM_DRAIN_CYCLES);

    typedef enum logic [2:0] {S_IDLE,S_FLUSH,S_LOAD,S_STREAM,S_DRAIN,S_MEM_DRAIN,S_DONE} state_t;
    state_t state_q;

    logic [CI_TILE_W-1:0] ci_tile_q;
    logic [CO_TILE_W-1:0] co_tile_q;
    logic [WROW_W-1:0] weight_row_q;
    logic [TOKEN_ID_W-1:0] token_q;
    logic [DRAIN_W-1:0] drain_q;
    logic [MDRAIN_W-1:0] mem_drain_q;
    logic pipe_flush;

    logic core_out_valid [0:PE_N-1];
    logic [TOKEN_ID_W-1:0] core_out_token_id [0:PE_N-1];
    logic signed [ACC_W-1:0] core_out_psum [0:PE_N-1];
    logic core_vec_valid;

    logic stage_valid_q, stage_first_ci_q, stage_final_ci_q;
    logic [TOKEN_ID_W-1:0] stage_token_q;
    logic [CO_TILE_W-1:0] stage_co_tile_q;
    logic signed [ACC_W-1:0] stage_sum_q [0:PE_N-1];

    logic psum_rd_en;
    logic [TOKEN_ID_W-1:0] psum_rd_addr;
    logic signed [ACC_W-1:0] psum_rd_data [0:PE_N-1];
    logic psum_wr_en;
    logic [TOKEN_ID_W-1:0] psum_wr_addr;
    logic signed [ACC_W-1:0] psum_wr_data [0:PE_N-1];

    integer lane_valid, lane_comb, lane_seq, lane_assert;

    always_comb begin
        core_vec_valid = 1'b1;
        for (lane_valid=0; lane_valid<PE_N; lane_valid=lane_valid+1)
            core_vec_valid = core_vec_valid & core_out_valid[lane_valid];
    end

    always_comb begin
        stream_valid = (state_q == S_STREAM);
        stream_token_id = token_q;
        active_ci_tile = ci_tile_q;
        active_co_tile = co_tile_q;
        weight_row_load = (state_q == S_LOAD);
        weight_row_index = weight_row_q;
        pipe_flush = (state_q == S_FLUSH);

        psum_rd_en = core_vec_valid && (ci_tile_q != '0);
        psum_rd_addr = core_out_token_id[0];
        psum_wr_en = stage_valid_q;
        psum_wr_addr = stage_token_q;
        for (lane_comb=0; lane_comb<PE_N; lane_comb=lane_comb+1) begin
            if (stage_first_ci_q)
                psum_wr_data[lane_comb] = stage_sum_q[lane_comb];
            else
                psum_wr_data[lane_comb] = $signed(psum_rd_data[lane_comb]) + $signed(stage_sum_q[lane_comb]);
        end
    end

    ws16x16_weight_stationary_core #(
      .DATA_W(DATA_W), .ACC_W(ACC_W), .PE_K(PE_K), .PE_N(PE_N), .PIX_ID_W(TOKEN_ID_W)
    ) u_ws_core (
      .clk(clk), .rst_n(rst_n), .pipe_flush(pipe_flush),
      .weight_row_load(weight_row_load), .weight_row_index(weight_row_index), .weight_row_values(weight_row_values),
      .input_valid(stream_valid), .input_pixel_id(stream_token_id), .input_vector(input_vector),
      .out_valid(core_out_valid), .out_pixel_id(core_out_token_id), .out_psum(core_out_psum)
    );

    psum_banked_mem #(
      .DEPTH(TOKENS), .PE_N(PE_N), .ACC_W(ACC_W), .ADDR_W(TOKEN_ID_W)
    ) u_psum (
      .clk(clk), .rd_en(psum_rd_en), .rd_addr(psum_rd_addr), .rd_data(psum_rd_data),
      .wr_en(psum_wr_en), .wr_addr(psum_wr_addr), .wr_data(psum_wr_data)
    );

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        stage_valid_q <= 1'b0; stage_first_ci_q <= 1'b0; stage_final_ci_q <= 1'b0;
        stage_token_q <= '0; stage_co_tile_q <= '0;
        raw_valid <= 1'b0; raw_token_id <= '0; raw_co_tile <= '0;
        for (lane_seq=0; lane_seq<PE_N; lane_seq=lane_seq+1) begin
          stage_sum_q[lane_seq] <= '0; raw_acc[lane_seq] <= '0;
        end
      end else begin
        raw_valid <= 1'b0;
        if (stage_valid_q && stage_final_ci_q) begin
          raw_valid <= 1'b1;
          raw_token_id <= stage_token_q;
          raw_co_tile <= stage_co_tile_q;
          for (lane_seq=0; lane_seq<PE_N; lane_seq=lane_seq+1)
            raw_acc[lane_seq] <= psum_wr_data[lane_seq];
        end
        if (state_q == S_FLUSH) begin
          stage_valid_q <= 1'b0; stage_first_ci_q <= 1'b0; stage_final_ci_q <= 1'b0;
        end else begin
          stage_valid_q <= core_vec_valid;
          if (core_vec_valid) begin
            stage_first_ci_q <= (ci_tile_q == '0);
            stage_final_ci_q <= (ci_tile_q == K_TILES-1);
            stage_token_q <= core_out_token_id[0];
            stage_co_tile_q <= co_tile_q;
            for (lane_seq=0; lane_seq<PE_N; lane_seq=lane_seq+1)
              stage_sum_q[lane_seq] <= core_out_psum[lane_seq];
          end
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        state_q<=S_IDLE; ci_tile_q<='0; co_tile_q<='0; weight_row_q<='0; token_q<='0;
        drain_q<='0; mem_drain_q<='0; busy<=1'b0; done<=1'b0;
      end else begin
        case (state_q)
          S_IDLE: begin
            busy<=1'b0; done<=1'b0;
            if (start) begin
              ci_tile_q<='0; co_tile_q<='0; weight_row_q<='0; token_q<='0;
              drain_q<='0; mem_drain_q<='0; busy<=1'b1; state_q<=S_FLUSH;
            end
          end
          S_FLUSH: begin weight_row_q<='0; state_q<=S_LOAD; end
          S_LOAD: begin
            if (weight_row_q == PE_K-1) begin token_q<='0; state_q<=S_STREAM; end
            else weight_row_q <= weight_row_q + 1'b1;
          end
          S_STREAM: begin
            if (token_q == TOKENS-1) begin drain_q<='0; state_q<=S_DRAIN; end
            else token_q <= token_q + 1'b1;
          end
          S_DRAIN: begin
            if (drain_q == DRAIN_CYCLES-1) begin mem_drain_q<='0; state_q<=S_MEM_DRAIN; end
            else drain_q <= drain_q + 1'b1;
          end
          S_MEM_DRAIN: begin
            if (mem_drain_q == MEM_DRAIN_CYCLES-1) begin
              if (ci_tile_q == K_TILES-1) begin
                ci_tile_q <= '0;
                if (co_tile_q == N_TILES-1) state_q <= S_DONE;
                else begin co_tile_q <= co_tile_q + 1'b1; state_q <= S_FLUSH; end
              end else begin ci_tile_q <= ci_tile_q + 1'b1; state_q <= S_FLUSH; end
            end else mem_drain_q <= mem_drain_q + 1'b1;
          end
          S_DONE: begin busy<=1'b0; done<=1'b1; if (!start) state_q<=S_IDLE; end
          default: state_q<=S_IDLE;
        endcase
      end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n && core_vec_valid) begin
        for (lane_assert=1; lane_assert<PE_N; lane_assert=lane_assert+1) begin
          if (!core_out_valid[lane_assert]) $fatal(1,"dense_ws16x16_controller: non-vector core valid");
          if (core_out_token_id[lane_assert] != core_out_token_id[0])
            $fatal(1,"dense_ws16x16_controller: lane token tag mismatch");
        end
      end
    end
`endif
endmodule
