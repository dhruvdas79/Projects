`timescale 1ns/1ps
// Every stage start is a one-clock pulse. This fixes the level-high re-launch bug.
module swin_block_pulse_sequencer(input logic clk,rst_n,start,output logic busy,done,
 output logic norm1_start,input logic norm1_done,output logic part_start,input logic part_done,
 output logic qkv_start,input logic qkv_done,output logic attn_start,input logic attn_done,
 output logic proj_start,input logic proj_done,output logic rev_start,input logic rev_done,
 output logic res1_start,input logic res1_done,output logic norm2_start,input logic norm2_done,
 output logic fc1_start,input logic fc1_done,output logic poly_start,input logic poly_done,
 output logic fc2_start,input logic fc2_done,output logic res2_start,input logic res2_done);
 typedef enum logic[4:0]{I,N1L,N1W,PL,PW,QL,QW,AL,AW,OL,OW,RL,RW,R1L,R1W,N2L,N2W,F1L,F1W,XYL,XYW,F2L,F2W,R2L,R2W,F}st_t;st_t st;
 always_comb begin norm1_start=0;part_start=0;qkv_start=0;attn_start=0;proj_start=0;rev_start=0;res1_start=0;norm2_start=0;fc1_start=0;poly_start=0;fc2_start=0;res2_start=0;busy=(st!=I&&st!=F);done=(st==F);case(st)N1L:norm1_start=1;PL:part_start=1;QL:qkv_start=1;AL:attn_start=1;OL:proj_start=1;RL:rev_start=1;R1L:res1_start=1;N2L:norm2_start=1;F1L:fc1_start=1;XYL:poly_start=1;F2L:fc2_start=1;R2L:res2_start=1;endcase end
 always_ff @(posedge clk or negedge rst_n)if(!rst_n)st<=I;else case(st)
 I:if(start)st<=N1L;N1L:st<=N1W;N1W:if(norm1_done)st<=PL;PL:st<=PW;PW:if(part_done)st<=QL;QL:st<=QW;QW:if(qkv_done)st<=AL;AL:st<=AW;AW:if(attn_done)st<=OL;OL:st<=OW;OW:if(proj_done)st<=RL;RL:st<=RW;RW:if(rev_done)st<=R1L;R1L:st<=R1W;R1W:if(res1_done)st<=N2L;N2L:st<=N2W;N2W:if(norm2_done)st<=F1L;F1L:st<=F1W;F1W:if(fc1_done)st<=XYL;XYL:st<=XYW;XYW:if(poly_done)st<=F2L;F2L:st<=F2W;F2W:if(fc2_done)st<=R2L;R2L:st<=R2W;R2W:if(res2_done)st<=F;F:if(!start)st<=I;default:st<=I;endcase
endmodule
