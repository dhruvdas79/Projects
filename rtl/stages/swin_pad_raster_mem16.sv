`timescale 1ns/1ps
// ============================================================================
// V6.2 padding raster with II=1 synchronous-RAM pipeline.
// Every output beat is delayed one clock. In-bounds beats use the registered
// source response; padding beats inject zero without allocating extra memory.
// ============================================================================
module swin_pad_raster_mem16 #(
 parameter int IN_H=26,IN_W=26,OUT_H=30,OUT_W=30,CHANNELS=128,LANES=16,DATA_W=8,
 parameter int CO_TILES=CHANNELS/LANES,
 parameter int IN_PIX_W=$clog2(IN_H*IN_W),parameter int OUT_PIX_W=$clog2(OUT_H*OUT_W),parameter int CO_W=$clog2(CO_TILES),
 parameter int X_W=(OUT_W<=1)?1:$clog2(OUT_W),parameter int Y_W=(OUT_H<=1)?1:$clog2(OUT_H)
)(
 input logic clk,input logic rst_n,input logic start,output logic busy,output logic done,
 output logic src_rd_en,output logic [IN_PIX_W-1:0] src_rd_pixel_id,output logic [CO_W-1:0] src_rd_co_tile,input logic src_rd_valid,input logic signed [LANES*DATA_W-1:0] src_rd_data,
 output logic dst_wr_valid,output logic [OUT_PIX_W-1:0] dst_wr_pixel_id,output logic [CO_W-1:0] dst_wr_co_tile,output logic signed [LANES*DATA_W-1:0] dst_wr_data
);
 typedef enum logic [1:0] {S_IDLE,S_ISSUE,S_DRAIN,S_DONE} st_t;
 st_t st_q;
 logic [OUT_PIX_W-1:0] outpix_q;
 logic [CO_W-1:0] co_q;
 logic [X_W-1:0] x_q;
 logic [Y_W-1:0] y_q;
 logic meta_valid_q;
 logic meta_in_bounds_q;
 logic [OUT_PIX_W-1:0] meta_outpix_q;
 logic [CO_W-1:0] meta_co_q;
 logic issue_fire;
 logic in_bounds;
 logic last_issue;
 logic last_output;

 always_comb begin
   issue_fire = (st_q == S_ISSUE);
   in_bounds = ($unsigned(y_q)<IN_H) && ($unsigned(x_q)<IN_W);
   last_issue = (outpix_q==OUT_H*OUT_W-1) && (co_q==CO_TILES-1);
   last_output = meta_valid_q &&
                 (meta_outpix_q==OUT_H*OUT_W-1) &&
                 (meta_co_q==CO_TILES-1);

   busy = (st_q != S_IDLE) && (st_q != S_DONE);
   done = (st_q == S_DONE);
   src_rd_en = issue_fire && in_bounds;
   src_rd_pixel_id = IN_PIX_W'($unsigned(y_q)*IN_W+$unsigned(x_q));
   src_rd_co_tile = co_q;

   dst_wr_valid = meta_valid_q && (!meta_in_bounds_q || src_rd_valid);
   dst_wr_pixel_id = meta_outpix_q;
   dst_wr_co_tile = meta_co_q;
   dst_wr_data = meta_in_bounds_q ? src_rd_data : '0;
 end

 always_ff @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     st_q<=S_IDLE;outpix_q<='0;co_q<='0;x_q<='0;y_q<='0;
     meta_valid_q<=1'b0;meta_in_bounds_q<=1'b0;meta_outpix_q<='0;meta_co_q<='0;
   end else begin
     meta_valid_q <= issue_fire;
     if (issue_fire) begin
       meta_in_bounds_q <= in_bounds;
       meta_outpix_q <= outpix_q;
       meta_co_q <= co_q;
     end

     case(st_q)
       S_IDLE: begin
         meta_valid_q<=1'b0;
         if(start) begin st_q<=S_ISSUE;outpix_q<='0;co_q<='0;x_q<='0;y_q<='0;end
       end
       S_ISSUE: begin
         if(last_issue) st_q<=S_DRAIN;
         else if(co_q==CO_TILES-1) begin
           co_q<='0;outpix_q<=outpix_q+1'b1;
           if(x_q==OUT_W-1) begin x_q<='0;y_q<=y_q+1'b1;end
           else x_q<=x_q+1'b1;
         end else co_q<=co_q+1'b1;
       end
       S_DRAIN: if(last_output) st_q<=S_DONE;
       S_DONE: st_q<=S_IDLE;
       default: st_q<=S_IDLE;
     endcase
   end
 end

`ifndef SYNTHESIS
 always_ff @(posedge clk) begin
   if (rst_n && meta_valid_q && meta_in_bounds_q && !src_rd_valid)
     $fatal(1,"pad source RAM violated one-cycle read contract");
 end
`endif
endmodule
