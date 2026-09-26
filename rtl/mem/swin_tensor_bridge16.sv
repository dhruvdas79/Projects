`timescale 1ns/1ps
// Copies one complete tensor using explicit read/write interfaces. This is a
// real activation-memory bridge used only between completed Swin blocks; it
// does not alter the INT8 codes.
module swin_tensor_bridge16 #(
  parameter int TOKENS=900,
  parameter int CHANNELS=128,
  parameter int LANES=16,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CO_W=((CHANNELS/LANES)<=1)?1:$clog2(CHANNELS/LANES)
)(
  input  logic clk,input logic rst_n,input logic start,
  output logic busy,output logic done,
  output logic src_rd_en,output logic [TOKEN_W-1:0] src_rd_token,
  output logic [CO_W-1:0] src_rd_co,input logic src_rd_valid,
  input logic signed [LANES*8-1:0] src_rd_data,
  output logic dst_wr_valid,output logic [TOKEN_W-1:0] dst_wr_token,
  output logic [CO_W-1:0] dst_wr_co,output logic signed [LANES*8-1:0] dst_wr_data
);
  localparam int CO_TILES=CHANNELS/LANES;
  typedef enum logic[1:0] {IDLE,RUN,FINISH} st_t;
  st_t st;
  logic [TOKEN_W-1:0] token;
  logic [CO_W-1:0] co;

  always_comb begin
    busy        = (st == RUN);
    src_rd_en   = (st == RUN);
    src_rd_token= token;
    src_rd_co   = co;
    dst_wr_valid= (st == RUN) && src_rd_valid;
    dst_wr_token= token;
    dst_wr_co   = co;
    dst_wr_data = src_rd_data;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; done <= 1'b0; token <= '0; co <= '0;
    end else begin
      done <= 1'b0;
      case (st)
        IDLE: if (start) begin token <= '0; co <= '0; st <= RUN; end
        RUN: if (src_rd_valid) begin
          if (co == CO_TILES-1) begin
            co <= '0;
            if (token == TOKENS-1) st <= FINISH;
            else token <= token + 1'b1;
          end else co <= co + 1'b1;
        end
        FINISH: begin done <= 1'b1; st <= IDLE; end
        default: st <= IDLE;
      endcase
    end
  end
endmodule
