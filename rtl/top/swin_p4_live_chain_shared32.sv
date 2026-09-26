`timescale 1ns/1ps
// ============================================================================
// swin_p4_live_chain_shared32.sv
//
// P4 Swin chain using shared32 client blocks only:
//   P4IN -> pad 26x26 to 30x30 -> P4_0 -> bridge -> P4_1 -> bridge
//        -> P4_2 -> bridge -> P4_3 -> crop 30x30 to 26x26 -> P4OUT
//
// This chain does NOT instantiate a 32x32 MAC engine.  The four Swin blocks are
// collapsed into one aggregate chain-client port using the existing local
// shared32 arbiter.  The parent top connects this port to the global arbiter and
// the single shared32 MAC service.
//
// The P4 input memory supports both the original 16-lane handoff and the new
// 32-lane projection handoff.  For projection->Swin integration, use wr32_*.
// ============================================================================
module swin_p4_live_chain_shared32(
  input logic clk,input logic rst_n,input logic start,
  output logic busy,output logic done,

  // Legacy 16-lane input write port.
  input logic in_wr_valid,input logic [9:0] in_wr_pixel,
  input logic [2:0] in_wr_co_tile,input logic signed [127:0] in_wr_data,

  // New 32-lane projection write port.
  input logic in_wr32_valid,input logic [9:0] in_wr32_pixel,
  input logic [1:0] in_wr32_co_tile,input logic signed [255:0] in_wr32_data,

  input logic out_rd_en,input logic [9:0] out_rd_pixel,
  input logic [2:0] out_rd_co_tile,output logic out_rd_valid,
  output logic signed [127:0] out_rd_data,

  // Aggregate client port to the one global shared32 MAC service.
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
  // Input P4 projection memory and final cropped P4 output memory.
  logic pin_re,pin_rv; logic[9:0]pin_pix; logic[2:0]pin_co; logic signed[127:0]pin_data;
  logic pout_wv,pout_rv; logic[9:0]pout_wp,pout_rp; logic[2:0]pout_wc,pout_rc; logic signed[127:0]pout_wd,pout_rd;

  swin_tensor_mem16x32_bridge #(.TOKENS(676),.CHANNELS(128)) P4IN(
    .clk(clk),
    .wr16_valid(in_wr_valid),.wr16_token_id(in_wr_pixel),.wr16_co_tile(in_wr_co_tile),.wr16_data(in_wr_data),
    .rd16_en(pin_re),.rd16_token_id(pin_pix),.rd16_co_tile(pin_co),.rd16_valid(pin_rv),.rd16_data(pin_data),
    .wr32_valid(in_wr32_valid),.wr32_token_id(in_wr32_pixel),.wr32_co_tile(in_wr32_co_tile),.wr32_data(in_wr32_data),
    .rd32_en(1'b0),.rd32_token_id('0),.rd32_co_tile('0),.rd32_valid(),.rd32_data()
  );

  swin_tensor_mem16 #(.TOKENS(676),.CHANNELS(128)) P4OUT(
    .clk,.wr_valid(pout_wv),.wr_token_id(pout_wp),.wr_co_tile(pout_wc),.wr_data(pout_wd),
    .rd_en(out_rd_en),.rd_token_id(out_rd_pixel),.rd_co_tile(out_rd_co_tile),.rd_valid(out_rd_valid),.rd_data(out_rd_data));

  logic pad_start,pad_done; logic p40x_wv;logic[9:0]p40x_pix;logic[2:0]p40x_co;logic signed[127:0]p40x_data;
  swin_pad_raster_mem16 #(.IN_H(26),.IN_W(26),.OUT_H(30),.OUT_W(30),.CHANNELS(128)) PAD(
    .clk,.rst_n,.start(pad_start),.busy(),.done(pad_done),
    .src_rd_en(pin_re),.src_rd_pixel_id(pin_pix),.src_rd_co_tile(pin_co),.src_rd_valid(pin_rv),.src_rd_data(pin_data),
    .dst_wr_valid(p40x_wv),.dst_wr_pixel_id(p40x_pix),.dst_wr_co_tile(p40x_co),.dst_wr_data(p40x_data));

  // Four block clients collapsed to one chain client.
  localparam int NUM_BLK_CLIENTS = 4;
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

  logic s0,s1,s2,s3,d0,d1,d2,d3;
  logic b01_start,b12_start,b23_start,b01_done,b12_done,b23_done;
  logic y0re,y1re,y2re,y3re; logic[9:0]y0pix,y1pix,y2pix,y3pix;logic[2:0]y0co,y1co,y2co,y3co; logic y0rv,y1rv,y2rv,y3rv;logic signed[127:0]y0data,y1data,y2data,y3data;
  logic x1wv,x2wv,x3wv;logic[9:0]x1pix,x2pix,x3pix;logic[2:0]x1co,x2co,x3co;logic signed[127:0]x1data,x2data,x3data;

  swin_p4_0_live_block_shared32 b0(.clk,.rst_n,.start(s0),.busy(),.done(d0),
    .x_wr_valid(p40x_wv),.x_wr_pixel(p40x_pix),.x_wr_co_tile(p40x_co),.x_wr_data(p40x_data),
    .y_rd_en(y0re),.y_rd_pixel(y0pix),.y_rd_co_tile(y0co),.y_rd_valid(y0rv),.y_rd_data(y0data),
    .client_req(blk_req[0]),.client_grant(blk_grant[0]),.client_cfg_tokens_m1(blk_cfg_tokens_m1[0]),.client_cfg_k_tiles_m1(blk_cfg_k_tiles_m1[0]),.client_cfg_n_tiles_m1(blk_cfg_n_tiles_m1[0]),.client_input_valid(blk_input_valid[0]),.client_weight_valid(blk_weight_valid[0]),.client_input_vector(blk_input_vector[0]),.client_weight_row_values(blk_weight_row_values[0]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(blk_post_valid[0]),.post_in_route(blk_post_route[0]),.post_in_op(blk_post_op[0]),.post_in_layer(blk_post_layer[0]),.post_in_token(blk_post_token[0]),.post_in_co(blk_post_co[0]),
    .post_in_value(blk_post_value[0]),.post_in_multiplier(blk_post_multiplier[0]),.post_in_shift(blk_post_shift[0]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code);

  swin_tensor_bridge16 #(.TOKENS(900),.CHANNELS(128)) B01(.clk,.rst_n,.start(b01_start),.busy(),.done(b01_done),.src_rd_en(y0re),.src_rd_token(y0pix),.src_rd_co(y0co),.src_rd_valid(y0rv),.src_rd_data(y0data),.dst_wr_valid(x1wv),.dst_wr_token(x1pix),.dst_wr_co(x1co),.dst_wr_data(x1data));

  swin_p4_1_live_block_shared32 b1(.clk,.rst_n,.start(s1),.busy(),.done(d1),
    .x_wr_valid(x1wv),.x_wr_pixel(x1pix),.x_wr_co_tile(x1co),.x_wr_data(x1data),
    .y_rd_en(y1re),.y_rd_pixel(y1pix),.y_rd_co_tile(y1co),.y_rd_valid(y1rv),.y_rd_data(y1data),
    .client_req(blk_req[1]),.client_grant(blk_grant[1]),.client_cfg_tokens_m1(blk_cfg_tokens_m1[1]),.client_cfg_k_tiles_m1(blk_cfg_k_tiles_m1[1]),.client_cfg_n_tiles_m1(blk_cfg_n_tiles_m1[1]),.client_input_valid(blk_input_valid[1]),.client_weight_valid(blk_weight_valid[1]),.client_input_vector(blk_input_vector[1]),.client_weight_row_values(blk_weight_row_values[1]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(blk_post_valid[1]),.post_in_route(blk_post_route[1]),.post_in_op(blk_post_op[1]),.post_in_layer(blk_post_layer[1]),.post_in_token(blk_post_token[1]),.post_in_co(blk_post_co[1]),
    .post_in_value(blk_post_value[1]),.post_in_multiplier(blk_post_multiplier[1]),.post_in_shift(blk_post_shift[1]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code);

  swin_tensor_bridge16 #(.TOKENS(900),.CHANNELS(128)) B12(.clk,.rst_n,.start(b12_start),.busy(),.done(b12_done),.src_rd_en(y1re),.src_rd_token(y1pix),.src_rd_co(y1co),.src_rd_valid(y1rv),.src_rd_data(y1data),.dst_wr_valid(x2wv),.dst_wr_token(x2pix),.dst_wr_co(x2co),.dst_wr_data(x2data));

  swin_p4_2_live_block_shared32 b2(.clk,.rst_n,.start(s2),.busy(),.done(d2),
    .x_wr_valid(x2wv),.x_wr_pixel(x2pix),.x_wr_co_tile(x2co),.x_wr_data(x2data),
    .y_rd_en(y2re),.y_rd_pixel(y2pix),.y_rd_co_tile(y2co),.y_rd_valid(y2rv),.y_rd_data(y2data),
    .client_req(blk_req[2]),.client_grant(blk_grant[2]),.client_cfg_tokens_m1(blk_cfg_tokens_m1[2]),.client_cfg_k_tiles_m1(blk_cfg_k_tiles_m1[2]),.client_cfg_n_tiles_m1(blk_cfg_n_tiles_m1[2]),.client_input_valid(blk_input_valid[2]),.client_weight_valid(blk_weight_valid[2]),.client_input_vector(blk_input_vector[2]),.client_weight_row_values(blk_weight_row_values[2]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(blk_post_valid[2]),.post_in_route(blk_post_route[2]),.post_in_op(blk_post_op[2]),.post_in_layer(blk_post_layer[2]),.post_in_token(blk_post_token[2]),.post_in_co(blk_post_co[2]),
    .post_in_value(blk_post_value[2]),.post_in_multiplier(blk_post_multiplier[2]),.post_in_shift(blk_post_shift[2]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code);

  swin_tensor_bridge16 #(.TOKENS(900),.CHANNELS(128)) B23(.clk,.rst_n,.start(b23_start),.busy(),.done(b23_done),.src_rd_en(y2re),.src_rd_token(y2pix),.src_rd_co(y2co),.src_rd_valid(y2rv),.src_rd_data(y2data),.dst_wr_valid(x3wv),.dst_wr_token(x3pix),.dst_wr_co(x3co),.dst_wr_data(x3data));

  swin_p4_3_live_block_shared32 b3(.clk,.rst_n,.start(s3),.busy(),.done(d3),
    .x_wr_valid(x3wv),.x_wr_pixel(x3pix),.x_wr_co_tile(x3co),.x_wr_data(x3data),
    .y_rd_en(y3re),.y_rd_pixel(y3pix),.y_rd_co_tile(y3co),.y_rd_valid(y3rv),.y_rd_data(y3data),
    .client_req(blk_req[3]),.client_grant(blk_grant[3]),.client_cfg_tokens_m1(blk_cfg_tokens_m1[3]),.client_cfg_k_tiles_m1(blk_cfg_k_tiles_m1[3]),.client_cfg_n_tiles_m1(blk_cfg_n_tiles_m1[3]),.client_input_valid(blk_input_valid[3]),.client_weight_valid(blk_weight_valid[3]),.client_input_vector(blk_input_vector[3]),.client_weight_row_values(blk_weight_row_values[3]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,.svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(blk_post_valid[3]),.post_in_route(blk_post_route[3]),.post_in_op(blk_post_op[3]),.post_in_layer(blk_post_layer[3]),.post_in_token(blk_post_token[3]),.post_in_co(blk_post_co[3]),
    .post_in_value(blk_post_value[3]),.post_in_multiplier(blk_post_multiplier[3]),.post_in_shift(blk_post_shift[3]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code);

  logic crop_start,crop_done;
  swin_crop_raster_mem16 #(.IN_H(30),.IN_W(30),.OUT_H(26),.OUT_W(26),.CHANNELS(128)) CROP(
    .clk,.rst_n,.start(crop_start),.busy(),.done(crop_done),
    .src_rd_en(y3re),.src_rd_pixel_id(y3pix),.src_rd_co_tile(y3co),.src_rd_valid(y3rv),.src_rd_data(y3data),
    .dst_wr_valid(pout_wv),.dst_wr_pixel_id(pout_wp),.dst_wr_co_tile(pout_wc),.dst_wr_data(pout_wd));

  typedef enum logic[4:0]{I,PL,PW,S0L,S0W,B01L,B01W,S1L,S1W,B12L,B12W,S2L,S2W,B23L,B23W,S3L,S3W,CL,CW,F} st_t;
  st_t st;
  always_comb begin
    pad_start=0;s0=0;b01_start=0;s1=0;b12_start=0;s2=0;b23_start=0;s3=0;crop_start=0;
    busy=(st!=I && st!=F);done=(st==F);
    case(st)
      PL:pad_start=1; S0L:s0=1; B01L:b01_start=1; S1L:s1=1; B12L:b12_start=1;
      S2L:s2=1; B23L:b23_start=1; S3L:s3=1; CL:crop_start=1;
      default:;
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) st<=I; else case(st)
      I:if(start)st<=PL; PL:st<=PW; PW:if(pad_done)st<=S0L; S0L:st<=S0W; S0W:if(d0)st<=B01L;
      B01L:st<=B01W;B01W:if(b01_done)st<=S1L; S1L:st<=S1W;S1W:if(d1)st<=B12L;
      B12L:st<=B12W;B12W:if(b12_done)st<=S2L; S2L:st<=S2W;S2W:if(d2)st<=B23L;
      B23L:st<=B23W;B23W:if(b23_done)st<=S3L; S3L:st<=S3W;S3W:if(d3)st<=CL;
      CL:st<=CW;CW:if(crop_done)st<=F;F:if(!start)st<=I;default:st<=I;
    endcase
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && !$onehot0(blk_post_valid))
      $fatal(1,"P4 chain: simultaneous block requant producers");
  end
`endif
endmodule
