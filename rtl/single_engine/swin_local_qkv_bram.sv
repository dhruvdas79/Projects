`timescale 1ns/1ps
// ============================================================================
// Window-local Q/K/V storage for the reusable Swin engine.
//
// Q is kept token-major.  K is initially written token-major, transposed once
// after the K dense pass, and then read row-major by the weight-stationary MAC.
// The token-major K store is reused for V after transpose.  This organization
// gives every physical array one synchronous read port and one write port, so
// Vivado can infer BRAM instead of flattening 3-D arrays into registers.
// ============================================================================
module swin_local_qkv_bram #(
  parameter int MAX_TOKENS = 25,
  parameter int CO_TILES   = 4
)(
  input  logic clk,
  input  logic rst_n,

  input  logic q_wr_en,
  input  logic [4:0] q_wr_token,
  input  logic [1:0] q_wr_co,
  input  logic signed [255:0] q_wr_data,

  // K and V are phase-exclusive and share this token-major write port.
  input  logic kv_wr_en,
  input  logic [4:0] kv_wr_token,
  input  logic [1:0] kv_wr_co,
  input  logic signed [255:0] kv_wr_data,

  input  logic transpose_start,
  input  logic [5:0] transpose_tokens,
  output logic transpose_busy,
  output logic transpose_done,

  input  logic q_rd_en,
  input  logic [4:0] q_rd_token,
  input  logic [1:0] q_rd_co,
  output logic q_rd_valid,
  output logic signed [255:0] q_rd_data,

  // One K row contains the selected feature byte for all window tokens.
  input  logic k_rd_en,
  input  logic [1:0] k_rd_co,
  input  logic [4:0] k_rd_row,
  output logic k_rd_valid,
  output logic signed [255:0] k_rd_data,

  input  logic v_rd_en,
  input  logic [4:0] v_rd_token,
  input  logic [1:0] v_rd_co,
  output logic v_rd_valid,
  output logic signed [255:0] v_rd_data
);
  localparam int TV_DEPTH = MAX_TOKENS*CO_TILES;
  localparam int KT_DEPTH = 32*CO_TILES;
  localparam int TV_AW = (TV_DEPTH <= 2) ? 1 : $clog2(TV_DEPTH);
  localparam int KT_AW = (KT_DEPTH <= 2) ? 1 : $clog2(KT_DEPTH);

  (* ram_style="distributed", rw_addr_collision="no" *)
  logic signed [255:0] q_mem [0:TV_DEPTH-1];
  (* ram_style="distributed", rw_addr_collision="no" *)
  logic signed [255:0] kv_mem [0:TV_DEPTH-1];
  (* ram_style="distributed", rw_addr_collision="no" *)
  logic signed [255:0] kt_mem [0:KT_DEPTH-1];

  function automatic logic [TV_AW-1:0] tv_addr(
    input logic [4:0] token,
    input logic [1:0] co
  );
    int unsigned a;
    begin
      a = $unsigned(co)*MAX_TOKENS + $unsigned(token);
      tv_addr = a[TV_AW-1:0];
    end
  endfunction

  function automatic logic [KT_AW-1:0] kt_addr(
    input logic [1:0] co,
    input logic [4:0] row
  );
    int unsigned a;
    begin
      a = ($unsigned(co)<<5) + $unsigned(row);
      kt_addr = a[KT_AW-1:0];
    end
  endfunction

  typedef enum logic [1:0] {X_IDLE,X_FILL,X_WRITE,X_DONE} xstate_t;
  xstate_t xstate_q;
  logic [5:0] x_tokens_q;
  logic [1:0] x_co_q;
  logic [4:0] x_row_q;
  logic [5:0] x_issue_token_q;
  logic [255:0] x_pack_q;
  logic x_rd_issue;
  logic kv_mem_rd_en,kv_mem_rd_is_xpose;
  logic [TV_AW-1:0] kv_mem_rd_addr;
  logic kv_mem_rd_valid_q,kv_mem_rd_is_xpose_q;
  logic [4:0] kv_mem_rd_token_q;
  logic signed [255:0] kv_mem_rd_data_q;

  assign x_rd_issue = (xstate_q==X_FILL) &&
                      ($unsigned(x_issue_token_q)<$unsigned(x_tokens_q));
  assign transpose_busy = (xstate_q!=X_IDLE) && (xstate_q!=X_DONE);
  assign v_rd_valid=kv_mem_rd_valid_q&&!kv_mem_rd_is_xpose_q;
  assign v_rd_data=kv_mem_rd_data_q;

  // Transpose and V phases share exactly one physical kv_mem read tuple.
  always_comb begin
    kv_mem_rd_en=1'b0;
    kv_mem_rd_is_xpose=1'b0;
    kv_mem_rd_addr='0;
    if(x_rd_issue) begin
      kv_mem_rd_en=1'b1;
      kv_mem_rd_is_xpose=1'b1;
      kv_mem_rd_addr=tv_addr(x_issue_token_q[4:0],x_co_q);
    end else if(v_rd_en&&!transpose_busy) begin
      kv_mem_rd_en=1'b1;
      kv_mem_rd_addr=tv_addr(v_rd_token,v_rd_co);
    end
  end

  // The three arrays deliberately have no reset/clear loops.  Reset applies
  // only to control and valid registers, which preserves BRAM inference.
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      q_rd_valid <= 1'b0;
      k_rd_valid <= 1'b0;
      kv_mem_rd_valid_q <= 1'b0;
      kv_mem_rd_is_xpose_q <= 1'b0;
    end else begin
      if(q_wr_en)
        q_mem[tv_addr(q_wr_token,q_wr_co)] <= q_wr_data;
      q_rd_valid <= q_rd_en;
      if(q_rd_en)
        q_rd_data <= q_mem[tv_addr(q_rd_token,q_rd_co)];

      if(kv_wr_en)
        kv_mem[tv_addr(kv_wr_token,kv_wr_co)] <= kv_wr_data;

      kv_mem_rd_valid_q<=kv_mem_rd_en;
      if(kv_mem_rd_en) begin
        kv_mem_rd_is_xpose_q<=kv_mem_rd_is_xpose;
        kv_mem_rd_token_q<=x_issue_token_q[4:0];
        kv_mem_rd_data_q<=kv_mem[kv_mem_rd_addr];
      end

      if(xstate_q==X_WRITE)
        kt_mem[kt_addr(x_co_q,x_row_q)] <= x_pack_q;
      k_rd_valid <= k_rd_en;
      if(k_rd_en)
        k_rd_data <= kt_mem[kt_addr(k_rd_co,k_rd_row)];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      xstate_q <= X_IDLE;
      x_tokens_q <= '0;
      x_co_q <= '0;
      x_row_q <= '0;
      x_issue_token_q <= '0;
      x_pack_q <= '0;
      transpose_done <= 1'b0;
    end else begin
      transpose_done <= 1'b0;

      if(kv_mem_rd_valid_q&&kv_mem_rd_is_xpose_q)
        x_pack_q[kv_mem_rd_token_q*8 +: 8] <=
          kv_mem_rd_data_q[x_row_q*8 +: 8];

      case(xstate_q)
        X_IDLE: if(transpose_start) begin
          x_tokens_q <= transpose_tokens;
          x_co_q <= '0;
          x_row_q <= '0;
          x_issue_token_q <= '0;
          x_pack_q <= '0;
          xstate_q <= X_FILL;
        end

        X_FILL: begin
          if(x_rd_issue)
            x_issue_token_q <= x_issue_token_q + 1'b1;
          if(kv_mem_rd_valid_q&&kv_mem_rd_is_xpose_q&&
             (kv_mem_rd_token_q==$unsigned(x_tokens_q)-1'b1))
            xstate_q <= X_WRITE;
        end

        X_WRITE: begin
          x_issue_token_q <= '0;
          x_pack_q <= '0;
          if(x_row_q==5'd31) begin
            x_row_q <= '0;
            if(x_co_q==CO_TILES-1) begin
              x_co_q <= '0;
              xstate_q <= X_DONE;
            end else begin
              x_co_q <= x_co_q + 1'b1;
              xstate_q <= X_FILL;
            end
          end else begin
            x_row_q <= x_row_q + 1'b1;
            xstate_q <= X_FILL;
          end
        end

        X_DONE: begin
          transpose_done <= 1'b1;
          xstate_q <= X_IDLE;
        end

        default: xstate_q <= X_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(rst_n && kv_wr_en && transpose_busy)
      $fatal(1,"local QKV BRAM: K/V write during K transpose");
    if(rst_n && v_rd_en && transpose_busy)
      $fatal(1,"local QKV BRAM: V read during K transpose");
    if(rst_n && transpose_start && (transpose_tokens==0 || transpose_tokens>MAX_TOKENS))
      $fatal(1,"local QKV BRAM: illegal token count");
  end
`endif
endmodule
