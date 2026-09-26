`timescale 1ns/1ps
// ============================================================================
// swin_residual_live_stage.sv -- V6.2 pipelined synchronous-RAM residual
//
// A and B addresses advance every clock.  Their one-cycle RAM responses are
// aligned by one metadata register and immediately pass through the exact
// narrow INT8 residual arithmetic.  This removes the request/wait bubble of
// the V6.1 controller while preserving synchronous BRAM inference.
//
// Throughput: one 16-lane vector / clock after pipeline fill
// DSP usage : zero
// ============================================================================
(* use_dsp = "no" *)
module swin_residual_live_stage #(
  parameter int PIXELS=900,
  parameter int CHANNELS=128,
  parameter int LANES=16,
  parameter int PIX_W=(PIXELS<=1)?1:$clog2(PIXELS),
  parameter int CO_W=((CHANNELS/LANES)<=1)?1:$clog2(CHANNELS/LANES),
  parameter [8*256-1:0] A_M_FILE = "a_M_i32.mem",
  parameter [8*256-1:0] A_SHIFT_FILE = "a_shift_i16.mem",
  parameter [8*256-1:0] B_M_FILE = "b_M_i32.mem",
  parameter [8*256-1:0] B_SHIFT_FILE = "b_shift_i16.mem"
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  output logic done,

  output logic a_rd_en,
  output logic [PIX_W-1:0] a_rd_pixel,
  output logic [CO_W-1:0] a_rd_co,
  input  logic a_rd_valid,
  input  logic signed [127:0] a_rd_data,

  output logic b_rd_en,
  output logic [PIX_W-1:0] b_rd_pixel,
  output logic [CO_W-1:0] b_rd_co,
  input  logic b_rd_valid,
  input  logic signed [127:0] b_rd_data,

  output logic y_wr_valid,
  output logic [PIX_W-1:0] y_wr_pixel,
  output logic [CO_W-1:0] y_wr_co,
  output logic signed [127:0] y_wr_data
);
  localparam int CO_TILES = CHANNELS/LANES;
  localparam int TOTAL_VECTORS = PIXELS*CO_TILES;

  logic [31:0] am[0:0], bm[0:0];
  logic signed [15:0] as[0:0], bs[0:0];

  logic signed [7:0] a[0:LANES-1];
  logic signed [7:0] b[0:LANES-1];
  logic signed [7:0] y[0:LANES-1];
  logic signed [63:0] aa[0:LANES-1];
  logic signed [63:0] bb[0:LANES-1];

  // Retained names for existing hierarchical debug probes.
  logic [PIX_W-1:0] p;
  logic [CO_W-1:0] c;

  logic req_meta_valid_q;
  logic [PIX_W-1:0] req_p_q;
  logic [CO_W-1:0] req_c_q;
  logic issue_fire;
  logic response_valid;
  logic last_issue;
  logic last_response;

  typedef enum logic [1:0] {
    I = 2'd0,
    R = 2'd1,
    D = 2'd2,
    F = 2'd3
  } st_t;
  st_t st;

  initial begin
    $readmemh(A_M_FILE, am);
    $readmemh(A_SHIFT_FILE, as);
    $readmemh(B_M_FILE, bm);
    $readmemh(B_SHIFT_FILE, bs);
  end

  always_comb begin
    issue_fire = (st == R);
    last_issue = (p == PIXELS-1) && (c == CO_TILES-1);

    a_rd_en = issue_fire;
    b_rd_en = issue_fire;
    a_rd_pixel = p;
    b_rd_pixel = p;
    a_rd_co = c;
    b_rd_co = c;

    response_valid = req_meta_valid_q && a_rd_valid && b_rd_valid;
    last_response = response_valid &&
                    (req_p_q == PIXELS-1) &&
                    (req_c_q == CO_TILES-1);

    for (int l = 0; l < LANES; l++) begin
      a[l] = a_rd_data[l*8 +: 8];
      b[l] = b_rd_data[l*8 +: 8];
      y_wr_data[l*8 +: 8] = y[l];
    end

    y_wr_valid = response_valid;
    y_wr_pixel = req_p_q;
    y_wr_co = req_c_q;
    done = (st == F);
  end

  requant_add_16lane #(.LANES(LANES)) u_requant_add(
    .a_code(a),
    .b_code(b),
    .a_mult(am[0]),
    .a_shift(as[0]),
    .b_mult(bm[0]),
    .b_shift(bs[0]),
    .a_aligned(aa),
    .b_aligned(bb),
    .y_code(y)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= I;
      p <= '0;
      c <= '0;
      req_meta_valid_q <= 1'b0;
      req_p_q <= '0;
      req_c_q <= '0;
    end else begin
      req_meta_valid_q <= issue_fire;
      if (issue_fire) begin
        req_p_q <= p;
        req_c_q <= c;
      end

      case (st)
        I: begin
          req_meta_valid_q <= 1'b0;
          if (start) begin
            p <= '0;
            c <= '0;
            st <= R;
          end
        end

        R: begin
          if (last_issue) begin
            st <= D;
          end else if (c == CO_TILES-1) begin
            c <= '0;
            p <= p + 1'b1;
          end else begin
            c <= c + 1'b1;
          end
        end

        D: begin
          if (last_response) st <= F;
        end

        F: st <= I;
        default: st <= I;
      endcase
    end
  end

`ifndef SYNTHESIS
  localparam int COUNT_W = (TOTAL_VECTORS <= 1) ? 1 : $clog2(TOTAL_VECTORS+1);
  logic [COUNT_W-1:0] request_count;
  logic [COUNT_W-1:0] write_count;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      request_count <= '0;
      write_count <= '0;
    end else begin
      if (start) begin
        request_count <= '0;
        write_count <= '0;
      end else begin
        if (issue_fire) request_count <= request_count + 1'b1;
        if (response_valid) write_count <= write_count + 1'b1;
      end

      if (rst_n && (a_rd_valid !== b_rd_valid))
        $fatal(1, "residual RAM A/B response-valid mismatch");
      if (rst_n && (a_rd_valid !== req_meta_valid_q))
        $fatal(1, "residual RAM violated fixed one-cycle read contract");

      if (done) begin
        if ((request_count != TOTAL_VECTORS) || (write_count != TOTAL_VECTORS))
          $fatal(1, "residual count failure request=%0d/%0d write=%0d/%0d",
                 request_count, TOTAL_VECTORS, write_count, TOTAL_VECTORS);
      end
    end
  end
`endif
endmodule
