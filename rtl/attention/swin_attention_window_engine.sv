`timescale 1ns/1ps
// Real integer window attention. It implements QK, strict M/shift, expanded
// relative-position bias, exact LUT softmax (UQ0.8 code/255), and P*V.
// It is a correctness-first one-window engine; scheduling/parallelization can be improved without changing math.
module swin_attention_window_engine #(
 parameter int HEADS=4,parameter int TOKENS=25,parameter int HEAD_DIM=32,parameter int LANES=16,
 parameter int CHUNKS=HEAD_DIM/LANES,
 parameter int TOK_W=(TOKENS<=1)?1:$clog2(TOKENS),parameter int CO_W=((HEADS*CHUNKS)<=1)?1:$clog2(HEADS*CHUNKS),
 parameter logic signed[31:0] QK_M=32'sd1,parameter int QK_SHIFT=31,
 parameter logic signed[31:0] CTX_M=32'sd1,parameter int CTX_SHIFT=31,
 parameter [8*256-1:0] RELPOS_EXPANDED_MEM = "relpos_expanded_i16.mem",parameter [8*256-1:0] EXP_LUT_MEM = "softmax_exp_lut_u16.mem"
)(input logic clk,rst_n,start,output logic busy,done,
 input logic signed[127:0] q_mem[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
 input logic signed[127:0] k_mem[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
 input logic signed[127:0] v_mem[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1],
 output logic out_valid,input logic out_ready,output logic[TOK_W-1:0] out_token,
 output logic[CO_W-1:0] out_co_tile,output logic signed[127:0] out_data);
 import fixedpoint_pkg::*;
 localparam int RLEN=HEADS*TOKENS*TOKENS;
 logic signed[15:0] relpos[0:RLEN-1]; logic[15:0] exp_lut[0:255];
 logic signed[7:0] logits[0:HEADS-1][0:TOKENS-1][0:TOKENS-1];
 logic[7:0] probs[0:HEADS-1][0:TOKENS-1][0:TOKENS-1];
 logic signed[127:0] ctx[0:HEADS-1][0:TOKENS-1][0:CHUNKS-1];
 typedef enum logic[2:0]{I,L,P,C,E,F} st_t;st_t st; integer h,q,k,d,c,l; logic[$clog2(HEADS)-1:0] hh; logic[TOK_W-1:0] qq; logic[$clog2(CHUNKS)-1:0] cc; logic[TOK_W-1:0] emitq; logic[CO_W-1:0] emitc;
 function automatic logic signed[31:0] rqs(input logic signed[63:0] x,input logic signed[31:0] m,input integer s);logic signed[63:0] p,half;begin p=x*m;half=64'sd1<<<(s-1);if(p>=0)rqs=(p+half)>>>s;else rqs=-(((-p)+half)>>>s);end endfunction
 function automatic logic[7:0] divround255(input logic[31:0] numer,input logic[31:0] den);logic[63:0] rem;logic[7:0] quo;integer b;begin rem=numer+(den>>1);quo=0;for(b=7;b>=0;b=b-1)if(rem >= ({32'd0,den}<<b))begin rem=rem-({32'd0,den}<<b);quo=quo|(8'd1<<b);end divround255=quo;end endfunction
 initial begin for(h=0;h<RLEN;h=h+1)relpos[h]='0;for(h=0;h<256;h=h+1)exp_lut[h]=0;$readmemh(RELPOS_EXPANDED_MEM,relpos);$readmemh(EXP_LUT_MEM,exp_lut);end
 always_ff @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin st<=I;busy<=0;done<=0;out_valid<=0;hh<=0;qq<=0;cc<=0;emitq<=0;emitc<=0;end else begin done<=0; case(st)
 I:begin busy<=0;out_valid<=0;if(start)begin busy<=1;hh<=0;qq<=0;st<=L;end end
 L:begin // full QK row for one head/query
   for(k=0;k<TOKENS;k=k+1) begin logic signed[63:0] sum;logic signed[31:0] sc;logic signed[32:0] bi;sum=0;for(d=0;d<HEAD_DIM;d=d+1) sum=sum+$signed(q_mem[hh][qq][d/LANES][(d%LANES)*8+:8])*$signed(k_mem[hh][k][d/LANES][(d%LANES)*8+:8]);sc=rqs(sum,QK_M,QK_SHIFT);bi=sc+relpos[hh*TOKENS*TOKENS+qq*TOKENS+k];if(bi>127)logits[hh][qq][k]<=8'sd127;else if(bi < -128)logits[hh][qq][k]<=-8'sd128;else logits[hh][qq][k]<=bi[7:0];end
   if(qq==TOKENS-1)begin qq<=0;if(hh==HEADS-1)begin hh<=0;st<=P;end else hh<=hh+1'b1;end else qq<=qq+1'b1;
 end
 P:begin // probability row for one head/query
   logic signed[7:0] mx;logic[31:0] den;mx=logits[hh][qq][0];for(k=1;k<TOKENS;k=k+1)if(logits[hh][qq][k]>mx)mx=logits[hh][qq][k];den=0;for(k=0;k<TOKENS;k=k+1)den=den+exp_lut[$unsigned(mx-logits[hh][qq][k])];for(k=0;k<TOKENS;k=k+1)probs[hh][qq][k]<=divround255((exp_lut[$unsigned(mx-logits[hh][qq][k])]<<8)-exp_lut[$unsigned(mx-logits[hh][qq][k])],den);
   if(qq==TOKENS-1)begin qq<=0;if(hh==HEADS-1)begin hh<=0;cc<=0;st<=C;end else hh<=hh+1'b1;end else qq<=qq+1'b1;
 end
 C:begin // 16 channels of context for one head/query/chunk
   for(l=0;l<LANES;l=l+1)begin logic signed[63:0] s;logic signed[31:0] rq;s=0;for(k=0;k<TOKENS;k=k+1)s=s+$signed({1'b0,probs[hh][qq][k]})*$signed(v_mem[hh][k][cc][l*8+:8]);rq=rqs(s,CTX_M,CTX_SHIFT);if(rq>127)ctx[hh][qq][cc][l*8+:8]<=8'sd127;else if(rq<-128)ctx[hh][qq][cc][l*8+:8]<=-8'sd128;else ctx[hh][qq][cc][l*8+:8]<=rq[7:0];end
   if(cc==CHUNKS-1)begin cc<=0;if(qq==TOKENS-1)begin qq<=0;if(hh==HEADS-1)begin emitq<=0;emitc<=0;st<=E;end else hh<=hh+1'b1;end else qq<=qq+1'b1;end else cc<=cc+1'b1;
 end
 E:begin out_valid<=1;out_token<=emitq;out_co_tile<=emitc;out_data<=ctx[emitc/CHUNKS][emitq][emitc%CHUNKS];if(out_ready)begin if(emitc==HEADS*CHUNKS-1)begin emitc<=0;if(emitq==TOKENS-1)begin out_valid<=0;st<=F;end else emitq<=emitq+1'b1;end else emitc<=emitc+1'b1;end end
 F:begin busy<=0;done<=1;st<=I;end
 endcase end end
endmodule
