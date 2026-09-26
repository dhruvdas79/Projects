`timescale 1ns/1ps
package swin_single_engine_cfg_pkg;
  localparam int NUM_BLOCKS = 6;
  localparam logic [2:0] BLK_P4_0 = 3'd0;
  localparam logic [2:0] BLK_P4_1 = 3'd1;
  localparam logic [2:0] BLK_P4_2 = 3'd2;
  localparam logic [2:0] BLK_P4_3 = 3'd3;
  localparam logic [2:0] BLK_P3_0 = 3'd4;
  localparam logic [2:0] BLK_P3_1 = 3'd5;

  localparam logic [2:0] DENSE_Q    = 3'd0;
  localparam logic [2:0] DENSE_K    = 3'd1;
  localparam logic [2:0] DENSE_V    = 3'd2;
  localparam logic [2:0] DENSE_PROJ = 3'd3;
  localparam logic [2:0] DENSE_FC1  = 3'd4;
  localparam logic [2:0] DENSE_FC2  = 3'd5;

  typedef struct packed {
    logic [6:0] h;
    logic [6:0] w;
    logic [2:0] ws;
    logic [2:0] shift;
    logic [2:0] heads;
    logic [6:0] head_dim;
    logic [11:0] pixels;
    logic [7:0] windows;
    logic [5:0] window_tokens;
    logic signed [31:0] qk_m;
    logic [5:0] qk_shift;
    logic signed [31:0] ctx_m;
    logic [5:0] ctx_shift;
  } block_cfg_t;

  function automatic block_cfg_t cfg_for(input logic [2:0] block_id);
    block_cfg_t c;
    begin
      c = '0;
      case (block_id)
        BLK_P4_0: begin
          c.h=7'd30; c.w=7'd30; c.ws=3'd5; c.shift=3'd0;
          c.heads=3'd4; c.head_dim=7'd32; c.pixels=12'd900;
          c.windows=8'd36; c.window_tokens=6'd25;
          c.qk_m=32'sd11909639; c.qk_shift=6'd31;
          c.ctx_m=32'sd11567812; c.ctx_shift=6'd31;
        end
        BLK_P4_1: begin
          c.h=7'd30; c.w=7'd30; c.ws=3'd5; c.shift=3'd2;
          c.heads=3'd4; c.head_dim=7'd32; c.pixels=12'd900;
          c.windows=8'd36; c.window_tokens=6'd25;
          c.qk_m=32'sd10292064; c.qk_shift=6'd31;
          c.ctx_m=32'sd8452003; c.ctx_shift=6'd31;
        end
        BLK_P4_2: begin
          c.h=7'd30; c.w=7'd30; c.ws=3'd5; c.shift=3'd0;
          c.heads=3'd4; c.head_dim=7'd32; c.pixels=12'd900;
          c.windows=8'd36; c.window_tokens=6'd25;
          c.qk_m=32'sd7809920; c.qk_shift=6'd31;
          c.ctx_m=32'sd8617319; c.ctx_shift=6'd31;
        end
        BLK_P4_3: begin
          c.h=7'd30; c.w=7'd30; c.ws=3'd5; c.shift=3'd2;
          c.heads=3'd4; c.head_dim=7'd32; c.pixels=12'd900;
          c.windows=8'd36; c.window_tokens=6'd25;
          c.qk_m=32'sd6836562; c.qk_shift=6'd31;
          c.ctx_m=32'sd8901910; c.ctx_shift=6'd31;
        end
        BLK_P3_0: begin
          c.h=7'd52; c.w=7'd52; c.ws=3'd4; c.shift=3'd0;
          c.heads=3'd2; c.head_dim=7'd64; c.pixels=12'd2704;
          c.windows=8'd169; c.window_tokens=6'd16;
          c.qk_m=32'sd6881664; c.qk_shift=6'd31;
          c.ctx_m=32'sd13203973; c.ctx_shift=6'd31;
        end
        default: begin
          c.h=7'd52; c.w=7'd52; c.ws=3'd4; c.shift=3'd2;
          c.heads=3'd2; c.head_dim=7'd64; c.pixels=12'd2704;
          c.windows=8'd169; c.window_tokens=6'd16;
          c.qk_m=32'sd5018753; c.qk_shift=6'd31;
          c.ctx_m=32'sd14820574; c.ctx_shift=6'd31;
        end
      endcase
      cfg_for = c;
    end
  endfunction
endpackage
