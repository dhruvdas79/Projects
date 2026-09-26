`timescale 1ns/1ps
// ============================================================================
// Fused attention-projection output -> inverse shift -> residual-1.
//
// Each 32-lane projection beat requests the matching original X vector.  On
// the following clock the exact residual alignment/add writes RES1 directly.
// H/APWIN frame memories and the standalone reverse/residual traversal vanish.
// ============================================================================
(* use_dsp="no" *)
module swin_proj_inverse_residual_fused32 #(
  parameter int H=30,parameter int W=30,parameter int CHANNELS=128,
  parameter int WS=5,parameter int SHIFT=0,parameter int PIXELS=H*W,
  parameter int TOKEN_W=(PIXELS<=1)?1:$clog2(PIXELS),
  parameter int CO32_W=((CHANNELS/32)<=1)?1:$clog2(CHANNELS/32),
  parameter [8*256-1:0] A_M_FILE="a_M_i32.mem",
  parameter [8*256-1:0] A_SHIFT_FILE="a_shift_i16.mem",
  parameter [8*256-1:0] B_M_FILE="b_M_i32.mem",
  parameter [8*256-1:0] B_SHIFT_FILE="b_shift_i16.mem"
)(
  input logic clk,input logic rst_n,
  input logic in_valid,input logic [TOKEN_W-1:0] in_flat_token,
  input logic [CO32_W-1:0] in_co_tile,input logic signed [255:0] in_data,
  output logic x_rd_en,output logic [TOKEN_W-1:0] x_rd_pixel,
  output logic [CO32_W-1:0] x_rd_co_tile,input logic x_rd_valid,input logic signed [255:0] x_rd_data,
  output logic out_valid,output logic [TOKEN_W-1:0] out_pixel,
  output logic [CO32_W-1:0] out_co_tile,output logic signed [255:0] out_data
);
  logic [31:0] am[0:0],bm[0:0];logic signed [15:0] as[0:0],bs[0:0];
  logic pipe_valid_q;logic [TOKEN_W-1:0] pipe_pixel_q;logic [CO32_W-1:0] pipe_co_q;
  logic signed [255:0] pipe_proj_q;
  logic signed [7:0] xlo[0:15],xhi[0:15],plo[0:15],phi[0:15],ylo[0:15],yhi[0:15];
  logic signed [63:0] aa0[0:15],bb0[0:15],aa1[0:15],bb1[0:15];
  integer flat_i,win_i,tok_i,win_row_i,win_col_i,tok_row_i,tok_col_i;
  integer fy_i,fx_i,pixel_i;

  initial begin $readmemh(A_M_FILE,am);$readmemh(A_SHIFT_FILE,as);$readmemh(B_M_FILE,bm);$readmemh(B_SHIFT_FILE,bs);end

  always_comb begin
    flat_i=$unsigned(in_flat_token);
    if(WS==5) begin
      win_i=(((flat_i<<5)+(flat_i<<3)+flat_i))>>10;
      tok_i=flat_i-((win_i<<4)+(win_i<<3)+win_i);
      win_row_i=(((win_i<<5)+(win_i<<3)+(win_i<<1)+win_i))>>8;
      win_col_i=win_i-((win_row_i<<2)+(win_row_i<<1));
      tok_row_i=(((tok_i<<3)+(tok_i<<2)+tok_i))>>6;
      tok_col_i=tok_i-((tok_row_i<<2)+tok_row_i);
    end else begin
      win_i=flat_i>>4;tok_i=flat_i&15;
      win_row_i=(((win_i<<11)+(win_i<<8)+(win_i<<7)+(win_i<<6)+(win_i<<4)+(win_i<<3)+win_i))>>15;
      win_col_i=win_i-((win_row_i<<3)+(win_row_i<<2)+win_row_i);
      tok_row_i=tok_i>>2;tok_col_i=tok_i&3;
    end
    fy_i=((WS==5)?((win_row_i<<2)+win_row_i):(win_row_i<<2))+tok_row_i+SHIFT;if(fy_i>=H)fy_i=fy_i-H;
    fx_i=((WS==5)?((win_col_i<<2)+win_col_i):(win_col_i<<2))+tok_col_i+SHIFT;if(fx_i>=W)fx_i=fx_i-W;
    if(W==52) pixel_i=((fy_i<<5)+(fy_i<<4)+(fy_i<<2))+fx_i;
    else      pixel_i=((fy_i<<4)+(fy_i<<3)+(fy_i<<2)+(fy_i<<1))+fx_i;
    x_rd_en=in_valid;x_rd_pixel=TOKEN_W'(pixel_i);x_rd_co_tile=in_co_tile;
    out_valid=pipe_valid_q&&x_rd_valid;out_pixel=pipe_pixel_q;out_co_tile=pipe_co_q;
    for(int lane=0;lane<16;lane=lane+1) begin
      xlo[lane]=x_rd_data[lane*8+:8];xhi[lane]=x_rd_data[(lane+16)*8+:8];
      plo[lane]=pipe_proj_q[lane*8+:8];phi[lane]=pipe_proj_q[(lane+16)*8+:8];
      out_data[lane*8+:8]=ylo[lane];out_data[(lane+16)*8+:8]=yhi[lane];
    end
  end

  requant_add_16lane u_lo(.a_code(xlo),.b_code(plo),.a_mult(am[0]),.a_shift(as[0]),.b_mult(bm[0]),.b_shift(bs[0]),.a_aligned(aa0),.b_aligned(bb0),.y_code(ylo));
  requant_add_16lane u_hi(.a_code(xhi),.b_code(phi),.a_mult(am[0]),.a_shift(as[0]),.b_mult(bm[0]),.b_shift(bs[0]),.a_aligned(aa1),.b_aligned(bb1),.y_code(yhi));

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin pipe_valid_q<=1'b0;pipe_pixel_q<='0;pipe_co_q<='0;pipe_proj_q<='0;end
    else begin
      pipe_valid_q<=in_valid;
      if(in_valid) begin pipe_pixel_q<=TOKEN_W'(pixel_i);pipe_co_q<=in_co_tile;pipe_proj_q<=in_data;end
    end
  end
`ifndef SYNTHESIS
  initial if(!((H==30&&W==30&&WS==5)||(H==52&&W==52&&WS==4)))
    $fatal(1,"fused projection residual supports active P4/P3 geometries only");
  always_ff @(posedge clk) if(rst_n && (x_rd_valid!==pipe_valid_q))
    $fatal(1,"fused projection residual X RAM violated one-cycle read contract");
`endif
endmodule
