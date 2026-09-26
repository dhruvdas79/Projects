`timescale 1ns/1ps
// ============================================================================
// swin_shared32_mac_service.sv
//
// ONE physical 32x32 weight-stationary MAC service for Swin dense/attention.
// This is the resource-sharing boundary: instantiate this module exactly once
// in the Swin subsystem and connect all QKV/PROJ/FC1/FC2/QK/PV clients to it
// through an arbiter/mux.
//
// Universal runtime shape:
//   tokens  = cfg_tokens_m1  + 1
//   k_tiles = cfg_k_tiles_m1 + 1     // CIN_PAD / 32
//   n_tiles = cfg_n_tiles_m1 + 1     // COUT_PAD / 32
//
// DATA_W=9 is used intentionally. Normal S8 x S8 dense/QK values are sign-
// extended to 9-bit by the client and remain numerically identical. PV uses
// U8 probability codes (0..255) x S8 V values, which requires a positive 9-bit
// activation lane; this avoids needing a second physical MAC engine.
//
// Internal accumulator remains ACC_W=48 for 1-DSP-per-PE behavior. External
// raw_acc is 64-bit sign-extended for the existing strict INT8 postprocess.
// ============================================================================
module swin_shared32_mac_service #(
    parameter int PE_K       = 32,
    parameter int PE_N       = 32,
    parameter int PE_LATENCY = 1,
    parameter int DATA_W     = 9,
    parameter int ACC_W      = 48,
    parameter int RAW_W      = 64,
    parameter int TOKEN_W    = 12,   // max 4096 tokens, enough for P3 2704
    parameter int TILE_W     = 4,    // max 16 tiles, enough for 512/32
    parameter int WROW_W     = 5,
    parameter int PSUM_DEPTH = 2704,
    parameter int DRAIN_CYCLES = PE_LATENCY * (PE_K + PE_N),
    parameter int MEM_DRAIN_CYCLES = 5
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic busy,
    output logic done,

    input  logic [TOKEN_W-1:0] cfg_tokens_m1,
    input  logic [TILE_W-1:0]  cfg_k_tiles_m1,
    input  logic [TILE_W-1:0]  cfg_n_tiles_m1,

    // Timing/address signals consumed by the currently granted client.
    output logic                         stream_valid,
    output logic [TOKEN_W-1:0]           stream_token_id,
    output logic [TILE_W-1:0]            active_ci_tile,
    output logic [TILE_W-1:0]            active_co_tile,
    output logic                         weight_row_load,
    output logic [WROW_W-1:0]            weight_row_index,

    // Runtime vectors supplied by the currently granted client.
    input  logic                         input_vector_valid,
    input  logic                         weight_row_valid,
    input  logic signed [DATA_W-1:0]     input_vector [0:PE_K-1],
    input  logic signed [DATA_W-1:0]     weight_row_values [0:PE_N-1],

    // Raw MAC stream returned to the currently granted client.
    output logic                         raw_valid,
    output logic [TOKEN_W-1:0]           raw_token_id,
    output logic [TILE_W-1:0]            raw_co_tile,
    output logic signed [RAW_W-1:0]      raw_acc [0:PE_N-1]
);
    localparam int DRAIN_W  = (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES);
    localparam int MDRAIN_W = (MEM_DRAIN_CYCLES <= 1) ? 1 : $clog2(MEM_DRAIN_CYCLES);

    typedef enum logic [2:0] {S_IDLE,S_FLUSH,S_LOAD,S_STREAM,S_DRAIN,S_MEM_DRAIN,S_DONE} state_t;
    state_t state_q;

    logic [TILE_W-1:0]  ci_tile_q;
    logic [TILE_W-1:0]  co_tile_q;
    logic [WROW_W-1:0]  weight_row_q;
    logic [TOKEN_W-1:0] token_q;
    logic [DRAIN_W-1:0] drain_q;
    logic [MDRAIN_W-1:0] mem_drain_q;
    logic pipe_flush;
    logic core_weight_row_load;
    logic core_input_valid;

    logic core_out_valid [0:PE_N-1];
    logic [TOKEN_W-1:0] core_out_token_id [0:PE_N-1];
    logic signed [ACC_W-1:0] core_out_psum [0:PE_N-1];
    logic core_vec_valid;

    logic stage_valid_q, stage_first_ci_q, stage_final_ci_q;
    logic [TOKEN_W-1:0] stage_token_q;
    logic [TILE_W-1:0]  stage_co_tile_q;
    logic signed [ACC_W-1:0] stage_sum_q [0:PE_N-1];

    // Match the optional PSUM BRAM output stage. Data and metadata advance
    // together, so the extra FF cycle cannot mix tokens or CI tiles.
    logic stage2_valid_q, stage2_first_ci_q, stage2_final_ci_q;
    logic [TOKEN_W-1:0] stage2_token_q;
    logic [TILE_W-1:0]  stage2_co_tile_q;
    logic signed [ACC_W-1:0] stage2_sum_q [0:PE_N-1];

    logic psum_rd_en;
    logic [TOKEN_W-1:0] psum_rd_addr;
    logic signed [ACC_W-1:0] psum_rd_data [0:PE_N-1];
    logic psum_wr_en;
    logic [TOKEN_W-1:0] psum_wr_addr;
    logic signed [ACC_W-1:0] psum_wr_data [0:PE_N-1];

    always_comb begin
        core_vec_valid = 1'b1;
        for (int lane_valid =0; lane_valid<PE_N; lane_valid=lane_valid+1)
            core_vec_valid = core_vec_valid & core_out_valid[lane_valid];
    end

    always_comb begin
        stream_valid     = (state_q == S_STREAM);
        stream_token_id  = token_q;
        active_ci_tile   = ci_tile_q;
        active_co_tile   = co_tile_q;
        weight_row_load  = (state_q == S_LOAD);
        weight_row_index = weight_row_q;
        pipe_flush       = (state_q == S_FLUSH);
        core_weight_row_load = (state_q == S_LOAD) && weight_row_valid;
        core_input_valid = (state_q == S_STREAM) && input_vector_valid;

        psum_rd_en   = core_vec_valid && (ci_tile_q != '0);
        psum_rd_addr = core_out_token_id[0];
        psum_wr_en   = stage2_valid_q;
        psum_wr_addr = stage2_token_q;
        for (int lane_comb =0; lane_comb<PE_N; lane_comb=lane_comb+1) begin
            if (stage2_first_ci_q)
                psum_wr_data[lane_comb] = stage2_sum_q[lane_comb];
            else
                psum_wr_data[lane_comb] = $signed(psum_rd_data[lane_comb]) + $signed(stage2_sum_q[lane_comb]);
        end
    end

    ws32x32_weight_stationary_core #(
      .DATA_W(DATA_W), .ACC_W(ACC_W), .PE_K(PE_K), .PE_N(PE_N), .PIX_ID_W(TOKEN_W),
      .PE_LATENCY(PE_LATENCY)
    ) u_only_ws32_core (
      .clk(clk), .rst_n(rst_n), .pipe_flush(pipe_flush),
      .weight_row_load(core_weight_row_load), .weight_row_index(weight_row_index), .weight_row_values(weight_row_values),
      .input_valid(core_input_valid), .input_pixel_id(stream_token_id), .input_vector(input_vector),
      .out_valid(core_out_valid), .out_pixel_id(core_out_token_id), .out_psum(core_out_psum)
    );

    psum_banked_mem #(
      .DEPTH(PSUM_DEPTH), .PE_N(PE_N), .ACC_W(ACC_W), .ADDR_W(TOKEN_W),
      .OUTPUT_REG(1)
    ) u_shared_psum (
      .clk(clk), .rd_en(psum_rd_en), .rd_addr(psum_rd_addr), .rd_data(psum_rd_data),
      .wr_en(psum_wr_en), .wr_addr(psum_wr_addr), .wr_data(psum_wr_data)
    );

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        stage_valid_q <= 1'b0; stage_first_ci_q <= 1'b0; stage_final_ci_q <= 1'b0;
        stage_token_q <= '0; stage_co_tile_q <= '0;
        stage2_valid_q <= 1'b0; stage2_first_ci_q <= 1'b0; stage2_final_ci_q <= 1'b0;
        stage2_token_q <= '0; stage2_co_tile_q <= '0;
        raw_valid <= 1'b0; raw_token_id <= '0; raw_co_tile <= '0;
        for (int lane_seq =0; lane_seq<PE_N; lane_seq=lane_seq+1) begin
          stage_sum_q[lane_seq] <= '0;
          stage2_sum_q[lane_seq] <= '0;
          raw_acc[lane_seq] <= '0;
        end
      end else begin
        raw_valid <= 1'b0;
        if (stage2_valid_q && stage2_final_ci_q) begin
          raw_valid <= 1'b1;
          raw_token_id <= stage2_token_q;
          raw_co_tile <= stage2_co_tile_q;
          for (int lane_seq =0; lane_seq<PE_N; lane_seq=lane_seq+1)
            raw_acc[lane_seq] <= {{(RAW_W-ACC_W){psum_wr_data[lane_seq][ACC_W-1]}}, psum_wr_data[lane_seq]};
        end
        if (state_q == S_FLUSH) begin
          stage_valid_q <= 1'b0; stage_first_ci_q <= 1'b0; stage_final_ci_q <= 1'b0;
          stage2_valid_q <= 1'b0; stage2_first_ci_q <= 1'b0; stage2_final_ci_q <= 1'b0;
        end else begin
          stage2_valid_q <= stage_valid_q;
          if (stage_valid_q) begin
            stage2_first_ci_q <= stage_first_ci_q;
            stage2_final_ci_q <= stage_final_ci_q;
            stage2_token_q <= stage_token_q;
            stage2_co_tile_q <= stage_co_tile_q;
            for (int lane_seq =0; lane_seq<PE_N; lane_seq=lane_seq+1)
              stage2_sum_q[lane_seq] <= stage_sum_q[lane_seq];
          end

          stage_valid_q <= core_vec_valid;
          if (core_vec_valid) begin
            stage_first_ci_q <= (ci_tile_q == '0);
            stage_final_ci_q <= (ci_tile_q == cfg_k_tiles_m1);
            stage_token_q <= core_out_token_id[0];
            stage_co_tile_q <= co_tile_q;
            for (int lane_seq =0; lane_seq<PE_N; lane_seq=lane_seq+1)
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
        done <= 1'b0;
        case (state_q)
          S_IDLE: begin
            busy<=1'b0;
            if (start) begin
              ci_tile_q<='0; co_tile_q<='0; weight_row_q<='0; token_q<='0;
              drain_q<='0; mem_drain_q<='0; busy<=1'b1; state_q<=S_FLUSH;
            end
          end
          S_FLUSH: begin weight_row_q<='0; state_q<=S_LOAD; end
          S_LOAD: begin
            if (weight_row_valid) begin
              if (weight_row_q == PE_K-1) begin token_q<='0; state_q<=S_STREAM; end
              else weight_row_q <= weight_row_q + 1'b1;
            end
          end
          S_STREAM: begin
            if (input_vector_valid) begin
              if (token_q == cfg_tokens_m1) begin drain_q<='0; state_q<=S_DRAIN; end
              else token_q <= token_q + 1'b1;
            end
          end
          S_DRAIN: begin
            if (drain_q == DRAIN_CYCLES-1) begin mem_drain_q<='0; state_q<=S_MEM_DRAIN; end
            else drain_q <= drain_q + 1'b1;
          end
          S_MEM_DRAIN: begin
            if (mem_drain_q == MEM_DRAIN_CYCLES-1) begin
              if (ci_tile_q == cfg_k_tiles_m1) begin
                ci_tile_q <= '0;
                if (co_tile_q == cfg_n_tiles_m1) state_q <= S_DONE;
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
    initial begin
      if ((PE_LATENCY != 1) && (PE_LATENCY != 2))
        $fatal(1,"swin_shared32_mac_service: PE_LATENCY must be 1 or 2");
      if (DRAIN_CYCLES < PE_LATENCY * (PE_K + PE_N - 1))
        $fatal(1,"swin_shared32_mac_service: DRAIN_CYCLES too short for PE latency");
    end

    always_ff @(posedge clk) begin
      if (rst_n && core_vec_valid) begin
        for (int lane_assert =1; lane_assert<PE_N; lane_assert=lane_assert+1) begin
          if (!core_out_valid[lane_assert]) $fatal(1,"swin_shared32_mac_service: non-vector core valid");
          if (core_out_token_id[lane_assert] != core_out_token_id[0])
            $fatal(1,"swin_shared32_mac_service: lane token tag mismatch");
        end
      end
    end
`endif
endmodule
