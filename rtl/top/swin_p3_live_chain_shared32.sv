`timescale 1ns/1ps
// ============================================================================
// swin_p3_live_chain_shared32.sv
//
// P3 two-block Swin chain using shared32 client blocks only.  No physical MAC
// engine is instantiated here; the two block clients are collapsed into one
// aggregate chain-client port for the global shared32 service.
// ============================================================================
module swin_p3_live_chain_shared32(
  input logic clk,input logic rst_n,input logic start,
  output logic busy,output logic done,

  // Legacy 16-lane input write port.
  input logic in_wr_valid,input logic [11:0] in_wr_pixel,
  input logic [2:0] in_wr_co_tile,input logic signed [127:0] in_wr_data,

  // New 32-lane projection write port.
  input logic in_wr32_valid,input logic [11:0] in_wr32_pixel,
  input logic [1:0] in_wr32_co_tile,input logic signed [255:0] in_wr32_data,

  input logic out_rd_en,input logic [11:0] out_rd_pixel,
  input logic [2:0] out_rd_co_tile,output logic out_rd_valid,
  output logic signed [127:0] out_rd_data,

  output logic client_req,
  input  logic client_grant,
  output logic [11:0] client_cfg_tokens_m1,
  output logic [3:0]  client_cfg_k_tiles_m1,
  output logic [3:0]  client_cfg_n_tiles_m1,
  output logic client_input_valid,
  output logic client_weight_valid,
  output logic signed [8:0] client_input_vector [0:31],
  output logic signed [8:0] client_weight_row_values [0:31],

  input  logic svc_stream_valid,
  input  logic [11:0] svc_stream_token_id,
  input  logic [3:0]  svc_active_ci_tile,
  input  logic [3:0]  svc_active_co_tile,
  input  logic svc_weight_row_load,
  input  logic [4:0] svc_weight_row_index,
  input  logic svc_done,
  input  logic svc_raw_valid,
  input  logic [11:0] svc_raw_token_id,
  input  logic [3:0]  svc_raw_co_tile,
  input  logic signed [63:0] svc_raw_acc [0:31],

  // Aggregate client port to the one global shared requant service.
  output logic post_in_valid,
  output logic [5:0] post_in_route,
  output logic [1:0] post_in_op,
  output logic [1:0] post_in_layer,
  output logic [11:0] post_in_token,
  output logic [6:0] post_in_co,
  output logic signed [63:0] post_in_value [0:31],
  output logic signed [31:0] post_in_multiplier [0:31],
  output logic signed [15:0] post_in_shift [0:31],
  input logic post_out_valid,
  input logic [5:0] post_out_route,
  input logic [1:0] post_out_op,
  input logic [1:0] post_out_layer,
  input logic [11:0] post_out_token,
  input logic [6:0] post_out_co,
  input logic signed [7:0] post_out_code [0:31]
);
  // P3 input/output memories.  P3_1 final output is read directly by caller.
  logic p3in_rd_en,p3in_rd_valid; logic [11:0] p3in_rd_pix; logic [2:0] p3in_rd_co; logic signed [127:0] p3in_rd_data;

  swin_tensor_mem16x32_bridge #(.TOKENS(2704),.CHANNELS(128)) P3IN(
    .clk(clk),
    .wr16_valid(in_wr_valid),.wr16_token_id(in_wr_pixel),.wr16_co_tile(in_wr_co_tile),.wr16_data(in_wr_data),
    .rd16_en(p3in_rd_en),.rd16_token_id(p3in_rd_pix),.rd16_co_tile(p3in_rd_co),.rd16_valid(p3in_rd_valid),.rd16_data(p3in_rd_data),
    .wr32_valid(in_wr32_valid),.wr32_token_id(in_wr32_pixel),.wr32_co_tile(in_wr32_co_tile),.wr32_data(in_wr32_data),
    .rd32_en(1'b0),.rd32_token_id('0),.rd32_co_tile('0),.rd32_valid(),.rd32_data()
  );

  localparam int NUM_BLK_CLIENTS = 2;
  logic [NUM_BLK_CLIENTS-1:0] blk_req, blk_grant;
  logic [11:0] blk_cfg_tokens_m1 [0:NUM_BLK_CLIENTS-1];
  logic [3:0]  blk_cfg_k_tiles_m1 [0:NUM_BLK_CLIENTS-1];
  logic [3:0]  blk_cfg_n_tiles_m1 [0:NUM_BLK_CLIENTS-1];
  logic blk_input_valid [0:NUM_BLK_CLIENTS-1];
  logic blk_weight_valid [0:NUM_BLK_CLIENTS-1];
  logic signed [8:0] blk_input_vector [0:NUM_BLK_CLIENTS-1][0:31];
  logic signed [8:0] blk_weight_row_values [0:NUM_BLK_CLIENTS-1][0:31];

  logic [NUM_BLK_CLIENTS-1:0] blk_post_valid;
  logic [5:0] blk_post_route [0:NUM_BLK_CLIENTS-1];
  logic [1:0] blk_post_op [0:NUM_BLK_CLIENTS-1];
  logic [1:0] blk_post_layer [0:NUM_BLK_CLIENTS-1];
  logic [11:0] blk_post_token [0:NUM_BLK_CLIENTS-1];
  logic [6:0] blk_post_co [0:NUM_BLK_CLIENTS-1];
  logic signed [63:0] blk_post_value [0:NUM_BLK_CLIENTS-1][0:31];
  logic signed [31:0] blk_post_multiplier [0:NUM_BLK_CLIENTS-1][0:31];
  logic signed [15:0] blk_post_shift [0:NUM_BLK_CLIENTS-1][0:31];


  always_comb begin
    post_in_valid = 1'b0;
    post_in_route = '0;
    post_in_op = '0;
    post_in_layer = '0;
    post_in_token = '0;
    post_in_co = '0;
    for (int post_lane =0; post_lane<32; post_lane=post_lane+1) begin
      post_in_value[post_lane] = '0;
      post_in_multiplier[post_lane] = '0;
      post_in_shift[post_lane] = '0;
    end
    for (int post_sel =0; post_sel<NUM_BLK_CLIENTS; post_sel=post_sel+1) begin
      if (blk_post_valid[post_sel]) begin
        post_in_valid = 1'b1;
        post_in_route = blk_post_route[post_sel];
        post_in_op = blk_post_op[post_sel];
        post_in_layer = blk_post_layer[post_sel];
        post_in_token = blk_post_token[post_sel];
        post_in_co = blk_post_co[post_sel];
        for (int post_lane =0; post_lane<32; post_lane=post_lane+1) begin
          post_in_value[post_lane] = blk_post_value[post_sel][post_lane];
          post_in_multiplier[post_lane] = blk_post_multiplier[post_sel][post_lane];
          post_in_shift[post_lane] = blk_post_shift[post_sel][post_lane];
        end
      end
    end
  end

  swin_block_shared32_local_arbiter5 #(.NUM_CLIENTS(NUM_BLK_CLIENTS)) u_chain_arb (
    .clk(clk),.rst_n(rst_n),
    .client_req_i(blk_req),.client_grant_o(blk_grant),
    .client_cfg_tokens_m1_i(blk_cfg_tokens_m1),
    .client_cfg_k_tiles_m1_i(blk_cfg_k_tiles_m1),
    .client_cfg_n_tiles_m1_i(blk_cfg_n_tiles_m1),
    .client_input_valid_i(blk_input_valid),.client_weight_valid_i(blk_weight_valid),
    .client_input_vector_i(blk_input_vector),
    .client_weight_row_values_i(blk_weight_row_values),
    .block_req_o(client_req),.block_grant_i(client_grant),.svc_done_i(svc_done),
    .block_cfg_tokens_m1_o(client_cfg_tokens_m1),
    .block_cfg_k_tiles_m1_o(client_cfg_k_tiles_m1),
    .block_cfg_n_tiles_m1_o(client_cfg_n_tiles_m1),
    .block_input_valid_o(client_input_valid),.block_weight_valid_o(client_weight_valid),
    .block_input_vector_o(client_input_vector),
    .block_weight_row_values_o(client_weight_row_values)
  );

  logic b0_start,b0_busy,b0_done,b1_start,b1_busy,b1_done;
  logic b0y_re; logic [11:0] b0y_pix; logic [2:0] b0y_co; logic b0y_rv; logic signed [127:0] b0y_data;
  logic b1x_wv; logic [11:0] b1x_pix; logic [2:0] b1x_co; logic signed [127:0] b1x_data;
  logic br_start,br_busy,br_done;

  swin_p3_0_live_block_shared32 b0(
    .clk,.rst_n,.start(b0_start),.busy(b0_busy),.done(b0_done),
    .x_wr_valid(p3in_rd_valid),.x_wr_pixel(p3in_rd_pix),.x_wr_co_tile(p3in_rd_co),.x_wr_data(p3in_rd_data),
    .y_rd_en(b0y_re),.y_rd_pixel(b0y_pix),.y_rd_co_tile(b0y_co),.y_rd_valid(b0y_rv),.y_rd_data(b0y_data),
    .client_req(blk_req[0]),.client_grant(blk_grant[0]),.client_cfg_tokens_m1(blk_cfg_tokens_m1[0]),.client_cfg_k_tiles_m1(blk_cfg_k_tiles_m1[0]),.client_cfg_n_tiles_m1(blk_cfg_n_tiles_m1[0]),.client_input_valid(blk_input_valid[0]),.client_weight_valid(blk_weight_valid[0]),.client_input_vector(blk_input_vector[0]),.client_weight_row_values(blk_weight_row_values[0]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(blk_post_valid[0]),.post_in_route(blk_post_route[0]),.post_in_op(blk_post_op[0]),.post_in_layer(blk_post_layer[0]),.post_in_token(blk_post_token[0]),.post_in_co(blk_post_co[0]),
    .post_in_value(blk_post_value[0]),.post_in_multiplier(blk_post_multiplier[0]),.post_in_shift(blk_post_shift[0]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );

  // Stream P3IN memory into b0 X memory before launching b0.
  // Reuse existing bridge controller style: p3in_rd_en is driven by this loader.
  typedef enum logic[4:0]{I,LOAD,LWAIT,B0L,B0W,BRL,BRW,B1L,B1W,F} st_t;
  st_t st;
  logic [11:0] load_pix_q; logic [2:0] load_co_q;
  assign p3in_rd_en  = (st == LOAD);
  assign p3in_rd_pix = load_pix_q;
  assign p3in_rd_co  = load_co_q;

  swin_tensor_bridge16 #(.TOKENS(2704),.CHANNELS(128)) bridge0(
    .clk,.rst_n,.start(br_start),.busy(br_busy),.done(br_done),
    .src_rd_en(b0y_re),.src_rd_token(b0y_pix),.src_rd_co(b0y_co),.src_rd_valid(b0y_rv),.src_rd_data(b0y_data),
    .dst_wr_valid(b1x_wv),.dst_wr_token(b1x_pix),.dst_wr_co(b1x_co),.dst_wr_data(b1x_data)
  );

  swin_p3_1_live_block_shared32 b1(
    .clk,.rst_n,.start(b1_start),.busy(b1_busy),.done(b1_done),
    .x_wr_valid(b1x_wv),.x_wr_pixel(b1x_pix),.x_wr_co_tile(b1x_co),.x_wr_data(b1x_data),
    .y_rd_en(out_rd_en),.y_rd_pixel(out_rd_pixel),.y_rd_co_tile(out_rd_co_tile),.y_rd_valid(out_rd_valid),.y_rd_data(out_rd_data),
    .client_req(blk_req[1]),.client_grant(blk_grant[1]),.client_cfg_tokens_m1(blk_cfg_tokens_m1[1]),.client_cfg_k_tiles_m1(blk_cfg_k_tiles_m1[1]),.client_cfg_n_tiles_m1(blk_cfg_n_tiles_m1[1]),.client_input_valid(blk_input_valid[1]),.client_weight_valid(blk_weight_valid[1]),.client_input_vector(blk_input_vector[1]),.client_weight_row_values(blk_weight_row_values[1]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(blk_post_valid[1]),.post_in_route(blk_post_route[1]),.post_in_op(blk_post_op[1]),.post_in_layer(blk_post_layer[1]),.post_in_token(blk_post_token[1]),.post_in_co(blk_post_co[1]),
    .post_in_value(blk_post_value[1]),.post_in_multiplier(blk_post_multiplier[1]),.post_in_shift(blk_post_shift[1]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );

  always_comb begin
    b0_start=1'b0; br_start=1'b0; b1_start=1'b0;
    busy=(st!=I && st!=F); done=(st==F);
    case(st)
      B0L: b0_start=1'b1;
      BRL: br_start=1'b1;
      B1L: b1_start=1'b1;
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin st<=I; load_pix_q<='0; load_co_q<='0; end
    else case(st)
      I: if(start) begin load_pix_q<='0; load_co_q<='0; st<=LOAD; end
      LOAD: st<=LWAIT;
      LWAIT: begin
        if (load_co_q == 3'd7) begin
          load_co_q <= '0;
          if (load_pix_q == 12'd2703) st<=B0L;
          else begin load_pix_q <= load_pix_q + 1'b1; st<=LOAD; end
        end else begin load_co_q <= load_co_q + 1'b1; st<=LOAD; end
      end
      B0L: st<=B0W;
      B0W: if(b0_done) st<=BRL;
      BRL: st<=BRW;
      BRW: if(br_done) st<=B1L;
      B1L: st<=B1W;
      B1W: if(b1_done) st<=F;
      F: if(!start) st<=I;
      default: st<=I;
    endcase
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && !$onehot0(blk_post_valid))
      $fatal(1,"P3 chain: simultaneous block requant producers");
  end
`endif
endmodule
