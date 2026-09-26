`timescale 1ns/1ps
// V6.1 synthesis-optimized Q/K/V 16/32-lane bridge. Q/K/V and 32-lane tile
// select are folded into the address; low/high 16-lane halves use separate RAMs.
module swin_qkv_banked_mem16x32_rw #(
  parameter int TOKENS=900,parameter int COUT=128,parameter int DATA_W=8,
  parameter int LANES16=16,parameter int LANES32=32,
  parameter int TILES16=COUT/LANES16,parameter int TILES32=COUT/LANES32,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CO16_W=(TILES16<=1)?1:$clog2(TILES16),
  parameter int CO32_W=(TILES32<=1)?1:$clog2(TILES32),
  parameter int DEPTH=3*TILES32*TOKENS,
  parameter int ADDR_W=(DEPTH<=1)?1:$clog2(DEPTH)
)(
  input logic clk,
  input logic wr16_valid,input logic [1:0] wr16_op,input logic [TOKEN_W-1:0] wr16_token,input logic [CO16_W-1:0] wr16_co_tile,input logic signed [LANES16*DATA_W-1:0] wr16_data,
  input logic rd16_en,input logic [1:0] rd16_op,input logic [TOKEN_W-1:0] rd16_token,input logic [CO16_W-1:0] rd16_co_tile,output logic rd16_valid,output logic signed [LANES16*DATA_W-1:0] rd16_data,
  input logic wr32_valid,input logic [1:0] wr32_op,input logic [TOKEN_W-1:0] wr32_token,input logic [CO32_W-1:0] wr32_co_tile,input logic signed [LANES32*DATA_W-1:0] wr32_data,
  input logic rd32_en,input logic [1:0] rd32_op,input logic [TOKEN_W-1:0] rd32_token,input logic [CO32_W-1:0] rd32_co_tile,output logic rd32_valid,output logic signed [LANES32*DATA_W-1:0] rd32_data
);
  localparam int W16=LANES16*DATA_W;
  (* ram_style="block" *) logic signed [W16-1:0] mem_lo [0:DEPTH-1];
  (* ram_style="block" *) logic signed [W16-1:0] mem_hi [0:DEPTH-1];

  function automatic logic [ADDR_W-1:0] addr32(
    input logic [1:0] op,
    input logic [CO32_W-1:0] co,
    input logic [TOKEN_W-1:0] tok
  );
    addr32=ADDR_W'((($unsigned(op)*TILES32+$unsigned(co))*TOKENS)+$unsigned(tok));
  endfunction

  wire [CO32_W-1:0] wr16_pair=CO32_W'($unsigned(wr16_co_tile)>>1);
  wire [CO32_W-1:0] rd16_pair=CO32_W'($unsigned(rd16_co_tile)>>1);
  wire [ADDR_W-1:0] wa16=addr32(wr16_op,wr16_pair,wr16_token);
  wire [ADDR_W-1:0] ra16=addr32(rd16_op,rd16_pair,rd16_token);
  wire [ADDR_W-1:0] wa32=addr32(wr32_op,wr32_co_tile,wr32_token);
  wire [ADDR_W-1:0] ra32=addr32(rd32_op,rd32_co_tile,rd32_token);

  logic rd_armed,last_rd_is32;
  logic [ADDR_W-1:0] last_rd_addr;
  wire req_is32=rd32_en;
  wire req_en=rd32_en||rd16_en;
  wire [ADDR_W-1:0] req_addr=req_is32?ra32:ra16;
  wire req_new=req_en&&(!rd_armed||(req_addr!=last_rd_addr)||(req_is32!=last_rd_is32));

  initial begin
    rd16_valid=1'b0;rd32_valid=1'b0;rd16_data='0;rd32_data='0;
    rd_armed=1'b0;last_rd_is32=1'b0;last_rd_addr='0;
  end

  always_ff @(posedge clk) begin
    rd16_valid<=req_new&&!req_is32;
    rd32_valid<=req_new&&req_is32;
    if(!req_en)rd_armed<=1'b0;
    else if(req_new) begin
      rd_armed<=1'b1;last_rd_addr<=req_addr;last_rd_is32<=req_is32;
      if(req_is32)rd32_data<={mem_hi[req_addr],mem_lo[req_addr]};
      else if(rd16_co_tile[0])rd16_data<=mem_hi[req_addr];
      else rd16_data<=mem_lo[req_addr];
    end

    if(wr32_valid) begin
      mem_lo[wa32]<=wr32_data[0 +: W16];
      mem_hi[wa32]<=wr32_data[W16 +: W16];
    end else if(wr16_valid) begin
      if(wr16_co_tile[0])mem_hi[wa16]<=wr16_data;
      else mem_lo[wa16]<=wr16_data;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(wr16_valid&&wr32_valid)$fatal(1,"qkv bridge: simultaneous writes");
    if(rd16_en&&rd32_en)$fatal(1,"qkv bridge: simultaneous reads");
    if((wr16_valid&&wr16_op>2)||(wr32_valid&&wr32_op>2)||
       (rd16_en&&rd16_op>2)||(rd32_en&&rd32_op>2))
      $fatal(1,"qkv bridge: invalid op");
  end
`endif
endmodule
