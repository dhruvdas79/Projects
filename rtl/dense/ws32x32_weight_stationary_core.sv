`timescale 1ns/1ps
// ============================================================================
// ws32x32_weight_stationary_core.sv
//
// STRICT SRL-INFERENCE VERSION
//
// Functional timing is unchanged:
//   activation row r delay         = r cycles
//   top psum-token column c delay  = c cycles
//   output lane c reverse deskew   = PE_N-1-c cycles
//
// Wide DATA/TAG delay chains have NO reset/flush assignment and are marked for
// SRL extraction. Narrow VALID chains retain reset/flush semantics. Stale
// DATA/TAG contents are never consumed while VALID=0.
// ============================================================================
module ws32x32_weight_stationary_core #(
    parameter int DATA_W   = 8,
    parameter int ACC_W    = 48,
    parameter int PE_K     = 32,
    parameter int PE_N     = 32,
    parameter int PIX_ID_W = 12,
parameter int PE_LATENCY = 1
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         pipe_flush,

    input  logic                         weight_row_load,
    input  logic [$clog2(PE_K)-1:0]      weight_row_index,
    input  logic signed [DATA_W-1:0]     weight_row_values [0:PE_N-1],

    input  logic                         input_valid,
    input  logic [PIX_ID_W-1:0]          input_pixel_id,
    input  logic signed [DATA_W-1:0]     input_vector [0:PE_K-1],

    output logic                         out_valid [0:PE_N-1],
    output logic [PIX_ID_W-1:0]          out_pixel_id [0:PE_N-1],
    output logic signed [ACC_W-1:0]      out_psum [0:PE_N-1]
);

    logic                     act_valid_grid [0:PE_K-1][0:PE_N-1];
    logic [PIX_ID_W-1:0]      act_tag_grid   [0:PE_K-1][0:PE_N-1];
    logic signed [DATA_W-1:0] act_data_grid  [0:PE_K-1][0:PE_N-1];

    logic                     psum_valid_grid[0:PE_K-1][0:PE_N-1];
    logic [PIX_ID_W-1:0]      psum_tag_grid  [0:PE_K-1][0:PE_N-1];
    logic signed [ACC_W-1:0]  psum_data_grid [0:PE_K-1][0:PE_N-1];

    logic                     firstcol_act_valid [0:PE_K-1];
    logic [PIX_ID_W-1:0]      firstcol_act_tag   [0:PE_K-1];
    logic signed [DATA_W-1:0] firstcol_act_data  [0:PE_K-1];

    logic                     top_psum_valid [0:PE_N-1];
    logic [PIX_ID_W-1:0]      top_psum_tag   [0:PE_N-1];

    assign firstcol_act_valid[0] = input_valid;
    assign firstcol_act_tag[0]   = input_pixel_id;
    assign firstcol_act_data[0]  = input_vector[0];

    assign top_psum_valid[0] = input_valid;
    assign top_psum_tag[0]   = input_pixel_id;

    // ------------------------------------------------------------------------
    // Activation input skew.
    // Data/tag are reset-free SRL candidates. Valid remains resettable FFs.
    // ------------------------------------------------------------------------
    genvar gr;
    generate
      for (gr=1; gr<PE_K; gr=gr+1) begin : G_ACT_SKEW
        localparam int DELAY = gr;

        (* shreg_extract="yes", srl_style="srl" *)
        logic signed [DATA_W-1:0] data_pipe [0:DELAY-1];
        (* shreg_extract="yes", srl_style="srl" *)
        logic [PIX_ID_W-1:0] tag_pipe [0:DELAY-1];
        logic valid_pipe [0:DELAY-1];

        always_ff @(posedge clk) begin
          data_pipe[0] <= input_vector[gr];
          tag_pipe[0]  <= input_pixel_id;
          for (int d=1; d<DELAY; d=d+1) begin
            data_pipe[d] <= data_pipe[d-1];
            tag_pipe[d]  <= tag_pipe[d-1];
          end
        end

        always_ff @(posedge clk) begin
          if (!rst_n || pipe_flush) begin
            for (int d=0; d<DELAY; d=d+1)
              valid_pipe[d] <= 1'b0;
          end else begin
            valid_pipe[0] <= input_valid;
            for (int d=1; d<DELAY; d=d+1)
              valid_pipe[d] <= valid_pipe[d-1];
          end
        end

        assign firstcol_act_valid[gr] = valid_pipe[DELAY-1];
        assign firstcol_act_tag[gr]   = tag_pipe[DELAY-1];
        assign firstcol_act_data[gr]  = data_pipe[DELAY-1];
      end
    endgenerate

    // ------------------------------------------------------------------------
    // Top-edge psum-token skew.
    // Only the tag is wide; the valid chain alone needs reset/flush.
    // ------------------------------------------------------------------------
    genvar gc;
    generate
      for (gc=1; gc<PE_N; gc=gc+1) begin : G_TOP_SKEW
        localparam int DELAY = gc;

        (* shreg_extract="yes", srl_style="srl" *)
        logic [PIX_ID_W-1:0] tag_pipe [0:DELAY-1];
        logic valid_pipe [0:DELAY-1];

        always_ff @(posedge clk) begin
          tag_pipe[0] <= input_pixel_id;
          for (int d=1; d<DELAY; d=d+1)
            tag_pipe[d] <= tag_pipe[d-1];
        end

        always_ff @(posedge clk) begin
          if (!rst_n || pipe_flush) begin
            for (int d=0; d<DELAY; d=d+1)
              valid_pipe[d] <= 1'b0;
          end else begin
            valid_pipe[0] <= input_valid;
            for (int d=1; d<DELAY; d=d+1)
              valid_pipe[d] <= valid_pipe[d-1];
          end
        end

        assign top_psum_valid[gc] = valid_pipe[DELAY-1];
        assign top_psum_tag[gc]   = tag_pipe[DELAY-1];
      end
    endgenerate

    // ------------------------------------------------------------------------
    // 32x32 PE grid.
    // ------------------------------------------------------------------------
    genvar rk, cn;
    generate
      for (rk=0; rk<PE_K; rk=rk+1) begin : G_ROW
        for (cn=0; cn<PE_N; cn=cn+1) begin : G_COL
          if (rk==0 && cn==0) begin : G_00
            ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W),.PE_LATENCY(PE_LATENCY)) u_pe (
              .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
              .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
              .act_valid_in(firstcol_act_valid[rk]),.act_tag_in(firstcol_act_tag[rk]),.act_in(firstcol_act_data[rk]),
              .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
              .psum_valid_in(top_psum_valid[cn]),.psum_tag_in(top_psum_tag[cn]),.psum_in('0),
              .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
            );
          end else if (cn==0) begin : G_LEFT
            ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W),.PE_LATENCY(PE_LATENCY)) u_pe (
              .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
              .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
              .act_valid_in(firstcol_act_valid[rk]),.act_tag_in(firstcol_act_tag[rk]),.act_in(firstcol_act_data[rk]),
              .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
              .psum_valid_in(psum_valid_grid[rk-1][cn]),.psum_tag_in(psum_tag_grid[rk-1][cn]),.psum_in(psum_data_grid[rk-1][cn]),
              .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
            );
          end else if (rk==0) begin : G_TOP
            ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W),.PE_LATENCY(PE_LATENCY)) u_pe (
              .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
              .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
              .act_valid_in(act_valid_grid[rk][cn-1]),.act_tag_in(act_tag_grid[rk][cn-1]),.act_in(act_data_grid[rk][cn-1]),
              .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
              .psum_valid_in(top_psum_valid[cn]),.psum_tag_in(top_psum_tag[cn]),.psum_in('0),
              .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
            );
          end else begin : G_MID
            ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W),.PE_LATENCY(PE_LATENCY)) u_pe (
              .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
              .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
              .act_valid_in(act_valid_grid[rk][cn-1]),.act_tag_in(act_tag_grid[rk][cn-1]),.act_in(act_data_grid[rk][cn-1]),
              .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
              .psum_valid_in(psum_valid_grid[rk-1][cn]),.psum_tag_in(psum_tag_grid[rk-1][cn]),.psum_in(psum_data_grid[rk-1][cn]),
              .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
            );
          end
        end
      end
    endgenerate

    // ------------------------------------------------------------------------
    // Reverse output deskew.
    // Data/tag are reset-free SRL candidates; valid retains flush semantics.
    // ------------------------------------------------------------------------
    genvar oc;
    generate
      for (oc=0; oc<PE_N; oc=oc+1) begin : G_OUT
        if (oc == PE_N-1) begin : G_LAST_DIRECT
          assign out_valid[oc]    = psum_valid_grid[PE_K-1][oc];
          assign out_pixel_id[oc] = psum_tag_grid[PE_K-1][oc];
          assign out_psum[oc]     = psum_data_grid[PE_K-1][oc];
        end else begin : G_REVERSE_DESKEW
          localparam int DELAY = PE_N - 1 - oc;

          (* shreg_extract="yes", srl_style="srl" *)
          logic signed [ACC_W-1:0] data_pipe [0:DELAY-1];
          (* shreg_extract="yes", srl_style="srl" *)
          logic [PIX_ID_W-1:0] tag_pipe [0:DELAY-1];
          logic valid_pipe [0:DELAY-1];

          always_ff @(posedge clk) begin
            data_pipe[0] <= psum_data_grid[PE_K-1][oc];
            tag_pipe[0]  <= psum_tag_grid[PE_K-1][oc];
            for (int d=1; d<DELAY; d=d+1) begin
              data_pipe[d] <= data_pipe[d-1];
              tag_pipe[d]  <= tag_pipe[d-1];
            end
          end

          always_ff @(posedge clk) begin
            if (!rst_n || pipe_flush) begin
              for (int d=0; d<DELAY; d=d+1)
                valid_pipe[d] <= 1'b0;
            end else begin
              valid_pipe[0] <= psum_valid_grid[PE_K-1][oc];
              for (int d=1; d<DELAY; d=d+1)
                valid_pipe[d] <= valid_pipe[d-1];
            end
          end

          assign out_valid[oc]    = valid_pipe[DELAY-1];
          assign out_pixel_id[oc] = tag_pipe[DELAY-1];
          assign out_psum[oc]     = data_pipe[DELAY-1];
        end
      end
    endgenerate

endmodule
