`timescale 1ns/1ps
// ============================================================================
// swin_poly_silu_live_stage.sv -- V6.2 pipelined exact INT8 LUT PolySiLU
//
// The signed INT8 domain is represented exactly by a 256-entry output LUT.
// Source RAM requests advance every clock and one-cycle request metadata aligns
// the registered RAM response with the LUT pipeline.
//
// Throughput: one 16-lane vector / clock (II=1)
// Latency   : source RAM 1 clock + LUT 1 clock
// DSP usage : zero
// ============================================================================
(* use_dsp = "no" *)
module swin_poly_silu_live_stage #(
 parameter int PIXELS=900,parameter int COUT=512,parameter int LANES=16,
 parameter int PIX_W=(PIXELS<=1)?1:$clog2(PIXELS),parameter int CO_W=((COUT/LANES)<=1)?1:$clog2(COUT/LANES),
 parameter logic[31:0] PRE_SCALE_Q=1,parameter int PRE_SCALE_SHIFT=0,
 parameter logic[31:0] CLAMP_Q=32'h0008_0000,parameter int CLAMP_SHIFT=16,
 parameter logic [31:0] H_TO_OUT_M=1,parameter int H_TO_OUT_SHIFT=0,
 parameter logic [31:0] U_TO_Q20_M=1,parameter int U_TO_Q20_SHIFT=0,
 parameter logic [31:0] X_TO_OUT_M=1,parameter int X_TO_OUT_SHIFT=0,
 parameter string COEFF_MEM = "silu_coeff_q20_i32.mem",
 parameter string SILU_LUT_MEM = "silu_lut_i8.mem"
)(
 input logic clk,rst_n,start,output logic done,
 output logic src_rd_en,output logic[PIX_W-1:0]src_rd_pixel,output logic[CO_W-1:0]src_rd_co,
 input logic src_rd_valid,input logic signed[127:0]src_rd_data,
 output logic dst_wr_valid,output logic[PIX_W-1:0]dst_wr_pixel,output logic[CO_W-1:0]dst_wr_co,
 output logic signed[127:0]dst_wr_data
);
 typedef enum logic[1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_FINISH} st_t;
 st_t st_q;
 logic[PIX_W-1:0] p_q;
 logic[CO_W-1:0] c_q;
 logic req_meta_valid_q;
 logic[PIX_W-1:0] req_pixel_q;
 logic[CO_W-1:0] req_co_q;
 logic lut_valid_q;
 logic[PIX_W-1:0] lut_pixel_q;
 logic[CO_W-1:0] lut_co_q;
 logic signed[LANES*8-1:0] lut_data_q;
 logic issue_fire;
 logic lut_accept;
 logic last_issue;
 logic last_output;

 assign issue_fire = (st_q==S_ISSUE);
 assign src_rd_en = issue_fire;
 assign src_rd_pixel = p_q;
 assign src_rd_co = c_q;
 assign lut_accept = req_meta_valid_q && src_rd_valid;
 assign last_issue = (p_q==PIXELS-1) && (c_q==COUT/LANES-1);
 assign last_output = lut_valid_q &&
                      (lut_pixel_q==PIXELS-1) &&
                      (lut_co_q==COUT/LANES-1);
 assign dst_wr_valid = lut_valid_q;
 assign dst_wr_pixel = lut_pixel_q;
 assign dst_wr_co = lut_co_q;
 assign dst_wr_data = lut_data_q;
 assign done = (st_q==S_FINISH);

 // One logical LUT image. Vivado replicates read logic as needed for 16 lanes.
 (* rom_style = "distributed" *) logic signed [7:0] silu_lut [0:255];
 initial $readmemh(SILU_LUT_MEM, silu_lut);

 always_ff @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     lut_data_q <= '0;
     lut_valid_q <= 1'b0;
     lut_pixel_q <= '0;
     lut_co_q <= '0;
   end else begin
     lut_valid_q <= lut_accept;
     if (lut_accept) begin
       lut_pixel_q <= req_pixel_q;
       lut_co_q <= req_co_q;
       for (int lane = 0; lane < LANES; lane = lane + 1)
         lut_data_q[lane*8 +: 8] <= silu_lut[$unsigned(src_rd_data[lane*8 +: 8])];
     end
   end
 end

 always_ff @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     st_q<=S_IDLE; p_q<='0; c_q<='0;
     req_meta_valid_q<=1'b0; req_pixel_q<='0; req_co_q<='0;
   end else begin
     req_meta_valid_q <= issue_fire;
     if (issue_fire) begin
       req_pixel_q <= p_q;
       req_co_q <= c_q;
     end

     case(st_q)
       S_IDLE: begin
         req_meta_valid_q <= 1'b0;
         if(start) begin p_q<='0; c_q<='0; st_q<=S_ISSUE; end
       end
       S_ISSUE: begin
         if(last_issue)
           st_q <= S_DRAIN;
         else if(c_q==COUT/LANES-1) begin
           c_q <= '0; p_q <= p_q + 1'b1;
         end else begin
           c_q <= c_q + 1'b1;
         end
       end
       S_DRAIN: if(last_output) st_q <= S_FINISH;
       S_FINISH: st_q <= S_IDLE;
       default: st_q <= S_IDLE;
     endcase
   end
 end

`ifndef SYNTHESIS
 initial begin : validate_poly_lut_file
   int lut_fd;
   lut_fd = $fopen(SILU_LUT_MEM, "r");
   if (lut_fd == 0) $fatal(1, "POLY_LUT_FILE_OPEN_FAIL: %s", SILU_LUT_MEM);
   $fclose(lut_fd);
 end
 initial begin
   if (LANES != 16) $fatal(1,"V6.2 PolySiLU stage requires LANES=16");
   if (PRE_SCALE_Q === 32'bx || PRE_SCALE_SHIFT < 0 || CLAMP_Q === 32'bx ||
       H_TO_OUT_M === 32'bx || U_TO_Q20_M === 32'bx || X_TO_OUT_M === 32'bx ||
       COEFF_MEM == "")
     $fatal(1,"Invalid retained PolySiLU descriptor");
 end
 always_ff @(posedge clk) begin
   if (rst_n && (src_rd_valid !== req_meta_valid_q))
     $fatal(1, "PolySiLU source RAM violated fixed one-cycle read contract");
 end
`endif
endmodule
