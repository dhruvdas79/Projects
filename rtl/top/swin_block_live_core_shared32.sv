`timescale 1ns/1ps
// ============================================================================
// Generic Alpha1 live-memory Swin block.
//
// This top contains no copy/expand/shrink stage. Every named stage invokes
// real dense, attention, affine, residual, or PolySiLU RTL.
//
// Activation input/output are 16 signed INT8 lanes per transaction.
// Supply ASSET_DIR after running tools/generate_alpha1_live_assets.py.
// ============================================================================
module swin_block_live_core_shared32 #(
  parameter int H=30,
  parameter int W=30,
  parameter int CHANNELS=128,
  parameter int WS=5,
  parameter int SHIFT=0,
  parameter int HEADS=4,
  parameter int HEAD_DIM=32,
  // Attention constants are generated from Alpha1 assets. QK parameters must
  // be strict-audited for each block before signoff.
  parameter logic signed [31:0] QK_M=32'sd1,
  parameter int QK_SHIFT=31,
  parameter logic signed [31:0] CTX_M=32'sd1,
  parameter int CTX_SHIFT=31,
  // PolySiLU parameters are model/block-specific. Multipliers are unsigned
  // positive scale factors; using unsigned avoids sign-wrap above 2^31.
  parameter logic [31:0] POLY_PRE_SCALE_Q=32'd1,
  parameter int POLY_PRE_SCALE_SHIFT=0,
  parameter logic [31:0] POLY_CLAMP_Q=32'h0008_0000,
  parameter int POLY_CLAMP_SHIFT=16,
  parameter logic [31:0] POLY_H_TO_OUT_M=32'd1,
  parameter int POLY_H_TO_OUT_SHIFT=0,
  parameter logic [31:0] POLY_U_TO_Q20_M=32'd1,
  parameter int POLY_U_TO_Q20_SHIFT=0,
  parameter logic [31:0] POLY_X_TO_OUT_M=32'd1,
  parameter int POLY_X_TO_OUT_SHIFT=0,
  parameter string POLY_COEFF_MEM = "silu_coeff_q20_i32.mem",
  parameter string POLY_LUT_MEM = "silu_lut_i8.mem",
  parameter [8*256-1:0] ASSET_DIR = "generated/swin_p4_0",
  parameter int POST_ROUTE_BASE = 1
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  output logic busy,
  output logic done,

  // External write interface for padded X input.
  input  logic x_wr_valid,
  input  logic [$clog2(H*W)-1:0] x_wr_pixel,
  input  logic [$clog2(CHANNELS/16)-1:0] x_wr_co_tile,
  input  logic signed [127:0] x_wr_data,

  // Final Y output read interface.
  input  logic y_rd_en,
  input  logic [$clog2(H*W)-1:0] y_rd_pixel,
  input  logic [$clog2(CHANNELS/16)-1:0] y_rd_co_tile,
  output logic y_rd_valid,
  output logic signed [127:0] y_rd_data,

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

  // Aggregate client port to the one global 32-lane requant service.
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
  localparam int LANES=16;
  localparam int PIXELS=H*W;
  localparam int CTILES=CHANNELS/LANES;
  localparam int NUM_WINDOWS=(H/WS)*(W/WS);
  localparam int WTOKENS=WS*WS;
  localparam int TOKEN_W=(PIXELS<=1)?1:$clog2(PIXELS);
  localparam int PIX_W=TOKEN_W;
  localparam int CO_W=(CTILES<=1)?1:$clog2(CTILES);
  localparam int WIN_W=(NUM_WINDOWS<=1)?1:$clog2(NUM_WINDOWS);
  localparam int TOK_W=(WTOKENS<=1)?1:$clog2(WTOKENS);
  localparam int FC1_C=CHANNELS*4;
  localparam int FC1_CO_W=$clog2(FC1_C/LANES);
  // 32-lane MAC datapath tiles. Legacy non-MAC stages remain 16-lane.
  localparam int LANES32=32;
  localparam int CO32_W=((CHANNELS/LANES32)<=1)?1:$clog2(CHANNELS/LANES32);
  localparam int FC1_CO32_W=((FC1_C/LANES32)<=1)?1:$clog2(FC1_C/LANES32);

  // V6.2 address decomposition for the only supported Alpha1 window sizes.
  // This removes synthesized constant divider/modulo networks from the hot
  // QKV/context/projection paths.  For 25 tokens, floor(n/25) is exact over
  // the active P4 flat-token range 0..899 with floor((n*41)/1024).
  function automatic logic [WIN_W-1:0] flat_window_id(input logic [11:0] flat_token);
    logic [17:0] product41;
    logic [11:0] quotient;
    begin
      if (WTOKENS == 16) begin
        quotient = flat_token >> 4;
      end else begin
        product41 = ({6'b0,flat_token} << 5) +
                    ({6'b0,flat_token} << 3) + {6'b0,flat_token};
        quotient = product41 >> 10;
      end
      flat_window_id = WIN_W'(quotient);
    end
  endfunction

  function automatic logic [TOK_W-1:0] flat_token_id(input logic [11:0] flat_token);
    logic [17:0] product41;
    logic [11:0] quotient;
    logic [11:0] q_times_25;
    logic [11:0] remainder;
    begin
      if (WTOKENS == 16) begin
        remainder = flat_token & 12'h00f;
      end else begin
        product41 = ({6'b0,flat_token} << 5) +
                    ({6'b0,flat_token} << 3) + {6'b0,flat_token};
        quotient = product41 >> 10;
        q_times_25 = (quotient << 4) + (quotient << 3) + quotient;
        remainder = flat_token - q_times_25;
      end
      flat_token_id = TOK_W'(remainder);
    end
  endfunction

  initial begin
    if ((WTOKENS != 16) && (WTOKENS != 25))
      $error("V6.2 flat-token decoder supports WTOKENS=16 or 25 only");
  end

  // Local five-client shared32 mux: QKV, ATTN, PROJ, FC1, FC2.
  localparam int MAC_CLIENTS = 5;
  logic [MAC_CLIENTS-1:0] mac_req;
  logic [MAC_CLIENTS-1:0] mac_grant;
  logic [11:0] mac_cfg_tokens_m1 [0:MAC_CLIENTS-1];
  logic [3:0]  mac_cfg_k_tiles_m1 [0:MAC_CLIENTS-1];
  logic [3:0]  mac_cfg_n_tiles_m1 [0:MAC_CLIENTS-1];
  logic mac_input_valid [0:MAC_CLIENTS-1];
  logic mac_weight_valid [0:MAC_CLIENTS-1];
  logic signed [8:0] mac_input_vector [0:MAC_CLIENTS-1][0:31];
  logic signed [8:0] mac_weight_row_values [0:MAC_CLIENTS-1][0:31];

  // QKV, attention projection, FC1 and FC2 share one global requant pipeline.
  localparam int POST_CLIENTS = 4;
  logic [POST_CLIENTS-1:0] post_valid_i;
  logic [5:0] post_route_i [0:POST_CLIENTS-1];
  logic [1:0] post_op_i [0:POST_CLIENTS-1];
  logic [1:0] post_layer_i [0:POST_CLIENTS-1];
  logic [11:0] post_token_i [0:POST_CLIENTS-1];
  logic [6:0] post_co_i [0:POST_CLIENTS-1];
  logic signed [63:0] post_value_i [0:POST_CLIENTS-1][0:31];
  logic signed [31:0] post_multiplier_i [0:POST_CLIENTS-1][0:31];
  logic signed [15:0] post_shift_i [0:POST_CLIENTS-1][0:31];


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
    for (int post_sel =0; post_sel<POST_CLIENTS; post_sel=post_sel+1) begin
      if (post_valid_i[post_sel]) begin
        post_in_valid = 1'b1;
        post_in_route = post_route_i[post_sel];
        post_in_op = post_op_i[post_sel];
        post_in_layer = post_layer_i[post_sel];
        post_in_token = post_token_i[post_sel];
        post_in_co = post_co_i[post_sel];
        for (int post_lane =0; post_lane<32; post_lane=post_lane+1) begin
          post_in_value[post_lane] = post_value_i[post_sel][post_lane];
          post_in_multiplier[post_lane] = post_multiplier_i[post_sel][post_lane];
          post_in_shift[post_lane] = post_shift_i[post_sel][post_lane];
        end
      end
    end
  end

  swin_block_shared32_local_arbiter5 #(.NUM_CLIENTS(MAC_CLIENTS)) u_block_mac_arb (
    .clk(clk), .rst_n(rst_n),
    .client_req_i(mac_req), .client_grant_o(mac_grant),
    .client_cfg_tokens_m1_i(mac_cfg_tokens_m1),
    .client_cfg_k_tiles_m1_i(mac_cfg_k_tiles_m1),
    .client_cfg_n_tiles_m1_i(mac_cfg_n_tiles_m1),
    .client_input_valid_i(mac_input_valid),.client_weight_valid_i(mac_weight_valid),
    .client_input_vector_i(mac_input_vector),
    .client_weight_row_values_i(mac_weight_row_values),
    .block_req_o(client_req), .block_grant_i(client_grant), .svc_done_i(svc_done),
    .block_cfg_tokens_m1_o(client_cfg_tokens_m1),
    .block_cfg_k_tiles_m1_o(client_cfg_k_tiles_m1),
    .block_cfg_n_tiles_m1_o(client_cfg_n_tiles_m1),
    .block_input_valid_o(client_input_valid),.block_weight_valid_o(client_weight_valid),
    .block_input_vector_o(client_input_vector),
    .block_weight_row_values_o(client_weight_row_values)
  );

  // ---- Stage starts/completions ------------------------------------------------
  logic n1_start,n1_done,part_start,part_done,qkv_start,qkv_done;
  logic attn_start,attn_done,proj_start,proj_done,rev_start,rev_done;
  logic r1_start,r1_done,n2_start,n2_done,f1_start,f1_done;
  logic poly_start,poly_done,f2_start,f2_done,r2_start,r2_done;

  swin_block_pulse_sequencer seq(
    .clk,.rst_n,.start,.busy,.done,
    .norm1_start(n1_start),.norm1_done(n1_done),
    .part_start(part_start),.part_done(part_done),
    .qkv_start(qkv_start),.qkv_done(qkv_done),
    .attn_start(attn_start),.attn_done(attn_done),
    .proj_start(proj_start),.proj_done(proj_done),
    .rev_start(rev_start),.rev_done(rev_done),
    .res1_start(r1_start),.res1_done(r1_done),
    .norm2_start(n2_start),.norm2_done(n2_done),
    .fc1_start(f1_start),.fc1_done(f1_done),
    .poly_start(poly_start),.poly_done(poly_done),
    .fc2_start(f2_start),.fc2_done(f2_done),
    .res2_start(r2_start),.res2_done(r2_done)
  );

  // ---- V6.2 block-local storage --------------------------------------------
  // Full-frame N1, WIN1, H, APWIN, N2 and FC2 memories are eliminated.
  // Remaining full-frame stores: X, RES1, FC1_ACT and Y; QKV/CTX are required
  // by the current whole-frame attention schedule.

  // X: external 16-lane writes, shared 32-lane reads for on-demand Norm1/QKV
  // and fused projection/inverse-shift/residual-1.
  logic n1x32_rd_en, prx32_rd_en, xmem_rd32_en;
  logic [PIX_W-1:0] n1x32_rd_pix,prx32_rd_pix,xmem_rd32_pix;
  logic [CO32_W-1:0] n1x32_rd_co,prx32_rd_co,xmem_rd32_co;
  logic xmem_rd32_valid,n1x32_rd_valid,prx32_rd_valid,x_owner_q;
  logic signed [255:0] xmem_rd32_data;

  assign xmem_rd32_en  = n1x32_rd_en | prx32_rd_en;
  assign xmem_rd32_pix = prx32_rd_en ? prx32_rd_pix : n1x32_rd_pix;
  assign xmem_rd32_co  = prx32_rd_en ? prx32_rd_co  : n1x32_rd_co;
  assign n1x32_rd_valid = xmem_rd32_valid && !x_owner_q;
  assign prx32_rd_valid = xmem_rd32_valid &&  x_owner_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) x_owner_q<=1'b0;
    else if(xmem_rd32_en) x_owner_q<=prx32_rd_en;
  end

  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) XMEM(
    .clk,
    .wr16_valid(x_wr_valid),.wr16_token_id(x_wr_pixel),.wr16_co_tile(x_wr_co_tile),.wr16_data(x_wr_data),
    .rd16_en(1'b0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(1'b0),.wr32_token_id('0),.wr32_co_tile('0),.wr32_data('0),
    .rd32_en(xmem_rd32_en),.rd32_token_id(xmem_rd32_pix),.rd32_co_tile(xmem_rd32_co),
    .rd32_valid(xmem_rd32_valid),.rd32_data(xmem_rd32_data)
  );

  // RES1: fused projection/residual writes; on-demand Norm2 and fused residual2
  // share its synchronous 32-lane read port in non-overlapping phases.
  logic res1_wr32_v;logic [PIX_W-1:0] res1_wr32_pix;
  logic [CO32_W-1:0] res1_wr32_co;logic signed [255:0] res1_wr32_data;
  logic n2res_rd32_en,r2res_rd32_en,res1mem_rd32_en;
  logic [PIX_W-1:0] n2res_rd32_pix,r2res_rd32_pix,res1mem_rd32_pix;
  logic [CO32_W-1:0] n2res_rd32_co,r2res_rd32_co,res1mem_rd32_co;
  logic res1mem_rd32_valid,n2res_rd32_valid,res1_rd32_valid,res1_owner_q;
  logic signed [255:0] res1mem_rd32_data;

  assign res1mem_rd32_en  = n2res_rd32_en | r2res_rd32_en;
  assign res1mem_rd32_pix = r2res_rd32_en ? r2res_rd32_pix : n2res_rd32_pix;
  assign res1mem_rd32_co  = r2res_rd32_en ? r2res_rd32_co  : n2res_rd32_co;
  assign n2res_rd32_valid = res1mem_rd32_valid && !res1_owner_q;
  assign res1_rd32_valid  = res1mem_rd32_valid &&  res1_owner_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) res1_owner_q<=1'b0;
    else if(res1mem_rd32_en) res1_owner_q<=r2res_rd32_en;
  end

  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) RES1MEM(
    .clk,
    .wr16_valid(1'b0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(1'b0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(res1_wr32_v),.wr32_token_id(res1_wr32_pix),.wr32_co_tile(res1_wr32_co),.wr32_data(res1_wr32_data),
    .rd32_en(res1mem_rd32_en),.rd32_token_id(res1mem_rd32_pix),.rd32_co_tile(res1mem_rd32_co),
    .rd32_valid(res1mem_rd32_valid),.rd32_data(res1mem_rd32_data)
  );

  // FC1 activation and final Y are retained as 16/32 bridge memories.
  logic f1_wr32_v;logic [PIX_W-1:0] f1_wr32_pix;
  logic [FC1_CO32_W-1:0] f1_wr32_co;logic signed [255:0] f1_wr32_data;
  logic f1_act32_v;logic [PIX_W-1:0] f1_act32_pix;
  logic [FC1_CO32_W-1:0] f1_act32_co;logic signed [255:0] f1_act32_data;
  logic f2_rd32_en;logic [PIX_W-1:0] f2_pix32;
  logic [FC1_CO32_W-1:0] f2_co32;logic f1a_rd32_valid;logic signed [255:0] f1a_rd32_data;
  logic f2_wr32_v;logic [PIX_W-1:0] f2_wr32_pix;
  logic [CO32_W-1:0] f2_wr32_co;logic signed [255:0] f2_wr32_data;
  logic y_wr32_v;logic [PIX_W-1:0] y_wr32_pix;
  logic [CO32_W-1:0] y_wr32_co;logic signed [255:0] y_wr32_data;

  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(FC1_C)) F1AMEM(
    .clk,
    .wr16_valid(1'b0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(1'b0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(f1_act32_v),.wr32_token_id(f1_act32_pix),.wr32_co_tile(f1_act32_co),.wr32_data(f1_act32_data),
    .rd32_en(f2_rd32_en),.rd32_token_id(f2_pix32),.rd32_co_tile(f2_co32),
    .rd32_valid(f1a_rd32_valid),.rd32_data(f1a_rd32_data)
  );

  swin_tensor_mem16x32_bridge #(.TOKENS(PIXELS),.CHANNELS(CHANNELS)) YMEM(
    .clk,
    .wr16_valid(1'b0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(y_rd_en),.rd16_token_id(y_rd_pixel),.rd16_co_tile(y_rd_co_tile),
    .rd16_valid(y_rd_valid),.rd16_data(y_rd_data),
    .wr32_valid(y_wr32_v),.wr32_token_id(y_wr32_pix),.wr32_co_tile(y_wr32_co),.wr32_data(y_wr32_data),
    .rd32_en(1'b0),.rd32_token_id('0),.rd32_co_tile('0),.rd32_valid(),.rd32_data()
  );

  // Norm1 and partition are now performed on demand while QKV requests X.
  // Keep the two legacy sequencer phases as one-cycle compatibility acks.
  logic n1_done_q,part_done_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin n1_done_q<=1'b0;part_done_q<=1'b0;end
    else begin n1_done_q<=n1_start;part_done_q<=part_start;end
  end
  assign n1_done=n1_done_q;
  assign part_done=part_done_q;

  // ---- Q/K/V dense with on-demand shifted Norm1 -----------------------------
  logic qsrc_en;logic [TOKEN_W-1:0] qsrc_tok;logic [CO32_W-1:0] qsrc_co;
  logic qsrc_valid;logic [TOKEN_W-1:0] qsrc_norm_tok;logic [CO32_W-1:0] qsrc_norm_co;
  logic signed [255:0] qsrc_data;

  swin_shifted_norm_read_adapter32 #(
    .H(H),.W(W),.CHANNELS(CHANNELS),.WS(WS),.SHIFT(SHIFT),
    .NORM_LUT00_MEM({ASSET_DIR,"/norm/norm1_lut_lane00_i8.mem"}),
    .NORM_LUT01_MEM({ASSET_DIR,"/norm/norm1_lut_lane01_i8.mem"}),
    .NORM_LUT02_MEM({ASSET_DIR,"/norm/norm1_lut_lane02_i8.mem"}),
    .NORM_LUT03_MEM({ASSET_DIR,"/norm/norm1_lut_lane03_i8.mem"}),
    .NORM_LUT04_MEM({ASSET_DIR,"/norm/norm1_lut_lane04_i8.mem"}),
    .NORM_LUT05_MEM({ASSET_DIR,"/norm/norm1_lut_lane05_i8.mem"}),
    .NORM_LUT06_MEM({ASSET_DIR,"/norm/norm1_lut_lane06_i8.mem"}),
    .NORM_LUT07_MEM({ASSET_DIR,"/norm/norm1_lut_lane07_i8.mem"}),
    .NORM_LUT08_MEM({ASSET_DIR,"/norm/norm1_lut_lane08_i8.mem"}),
    .NORM_LUT09_MEM({ASSET_DIR,"/norm/norm1_lut_lane09_i8.mem"}),
    .NORM_LUT10_MEM({ASSET_DIR,"/norm/norm1_lut_lane10_i8.mem"}),
    .NORM_LUT11_MEM({ASSET_DIR,"/norm/norm1_lut_lane11_i8.mem"}),
    .NORM_LUT12_MEM({ASSET_DIR,"/norm/norm1_lut_lane12_i8.mem"}),
    .NORM_LUT13_MEM({ASSET_DIR,"/norm/norm1_lut_lane13_i8.mem"}),
    .NORM_LUT14_MEM({ASSET_DIR,"/norm/norm1_lut_lane14_i8.mem"}),
    .NORM_LUT15_MEM({ASSET_DIR,"/norm/norm1_lut_lane15_i8.mem"})
  ) NORM1_ON_DEMAND(
    .clk,.rst_n,.req_en(qsrc_en),.req_flat_token(qsrc_tok),.req_co_tile(qsrc_co),
    .x_rd_en(n1x32_rd_en),.x_rd_pixel(n1x32_rd_pix),.x_rd_co_tile(n1x32_rd_co),
    .x_rd_valid(n1x32_rd_valid),.x_rd_data(xmem_rd32_data),
    .out_valid(qsrc_valid),.out_token(qsrc_norm_tok),.out_co_tile(qsrc_norm_co),.out_data(qsrc_data)
  );

  logic qwr_v;logic [1:0] qwr_op;logic [TOKEN_W-1:0] qwr_tok;
  logic [CO32_W-1:0] qwr_co;logic signed [255:0] qwr_data;
  swin_qkv_live_stage_shared32_client #(
    .TOKENS(PIXELS),.CIN(CHANNELS),.COUT(CHANNELS),
    .Q_WEIGHT({ASSET_DIR,"/dense/q_weight_i8_packed32.mem"}),
    .K_WEIGHT({ASSET_DIR,"/dense/k_weight_i8_packed32.mem"}),
    .V_WEIGHT({ASSET_DIR,"/dense/v_weight_i8_packed32.mem"}),
    .Q_BIAS({ASSET_DIR,"/dense/q_folded_bias_i32.mem"}),.Q_M({ASSET_DIR,"/dense/q_requant_M_i32.mem"}),.Q_SHIFT({ASSET_DIR,"/dense/q_requant_shift_i16.mem"}),
    .K_BIAS({ASSET_DIR,"/dense/k_folded_bias_i32.mem"}),.K_M({ASSET_DIR,"/dense/k_requant_M_i32.mem"}),.K_SHIFT({ASSET_DIR,"/dense/k_requant_shift_i16.mem"}),
    .V_BIAS({ASSET_DIR,"/dense/v_folded_bias_i32.mem"}),.V_M({ASSET_DIR,"/dense/v_requant_M_i32.mem"}),.V_SHIFT({ASSET_DIR,"/dense/v_requant_shift_i16.mem"}),
    .POST_ROUTE_ID(POST_ROUTE_BASE+0)
  ) QKV(
    .clk,.rst_n,.start(qkv_start),.busy(),.done(qkv_done),
    .src_rd_en(qsrc_en),.src_rd_token(qsrc_tok),.src_rd_co_tile(qsrc_co),
    .src_rd_valid(qsrc_valid),.src_rd_data(qsrc_data),
    .wr_valid(qwr_v),.wr_op(qwr_op),.wr_token(qwr_tok),.wr_co_tile(qwr_co),.wr_data(qwr_data),
    .client_req(mac_req[0]),.client_grant(mac_grant[0]),
    .client_cfg_tokens_m1(mac_cfg_tokens_m1[0]),.client_cfg_k_tiles_m1(mac_cfg_k_tiles_m1[0]),.client_cfg_n_tiles_m1(mac_cfg_n_tiles_m1[0]),
    .client_input_valid(mac_input_valid[0]),.client_weight_valid(mac_weight_valid[0]),
    .client_input_vector(mac_input_vector[0]),.client_weight_row_values(mac_weight_row_values[0]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(post_valid_i[0]),.post_in_route(post_route_i[0]),.post_in_op(post_op_i[0]),
    .post_in_layer(post_layer_i[0]),.post_in_token(post_token_i[0]),.post_in_co(post_co_i[0]),
    .post_in_value(post_value_i[0]),.post_in_multiplier(post_multiplier_i[0]),.post_in_shift(post_shift_i[0]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );

  logic qkv_rd_en;logic [1:0] qkv_rd_op;logic [TOKEN_W-1:0] qkv_rd_tok;
  logic [CO32_W-1:0] qkv_rd_co;logic qkv_rd_valid;logic signed [255:0] qkv_rd_data;
  swin_qkv_banked_mem16x32_rw #(.TOKENS(PIXELS),.COUT(CHANNELS)) QKVMEM(
    .clk,
    .wr16_valid(1'b0),.wr16_op('0),.wr16_token('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(1'b0),.rd16_op('0),.rd16_token('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(qwr_v),.wr32_op(qwr_op),.wr32_token(qwr_tok),.wr32_co_tile(qwr_co),.wr32_data(qwr_data),
    .rd32_en(qkv_rd_en),.rd32_op(qkv_rd_op),.rd32_token(qkv_rd_tok),.rd32_co_tile(qkv_rd_co),
    .rd32_valid(qkv_rd_valid),.rd32_data(qkv_rd_data)
  );

  // ---- Attention and context memory ----------------------------------------
  logic ctx_wr_v;logic [WIN_W-1:0] ctx_wr_win;logic [TOK_W-1:0] ctx_wr_tok;
  logic [CO32_W-1:0] ctx_wr_co;logic signed [255:0] ctx_wr_data;
  swin_attention_scheduler_shared32_client #(
    .NUM_WINDOWS(NUM_WINDOWS),.TOKENS(WTOKENS),.HEADS(HEADS),.HEAD_DIM(HEAD_DIM),
    .QK_M(QK_M),.QK_SHIFT(QK_SHIFT),.CTX_M(CTX_M),.CTX_SHIFT(CTX_SHIFT),
    .RELPOS_EXPANDED_MEM({ASSET_DIR,"/attention/relpos_expanded_logits_i16.mem"}),
    .EXP_LUT_MEM({ASSET_DIR,"/attention/softmax_exp_lut_u16.mem"})
  ) ATTN(
    .clk,.rst_n,.start(attn_start),.busy(),.done(attn_done),
    .qkv_rd_en,.qkv_rd_op,.qkv_rd_token(qkv_rd_tok),.qkv_rd_co_tile(qkv_rd_co),
    .qkv_rd_valid,.qkv_rd_data,
    .ctx_wr_valid(ctx_wr_v),.ctx_wr_window(ctx_wr_win),.ctx_wr_token(ctx_wr_tok),.ctx_wr_co_tile(ctx_wr_co),.ctx_wr_data(ctx_wr_data),
    .client_req(mac_req[1]),.client_grant(mac_grant[1]),
    .client_cfg_tokens_m1(mac_cfg_tokens_m1[1]),.client_cfg_k_tiles_m1(mac_cfg_k_tiles_m1[1]),.client_cfg_n_tiles_m1(mac_cfg_n_tiles_m1[1]),
    .client_input_valid(mac_input_valid[1]),.client_weight_valid(mac_weight_valid[1]),
    .client_input_vector(mac_input_vector[1]),.client_weight_row_values(mac_weight_row_values[1]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc
  );

  logic ctx_rd32_en;logic [WIN_W-1:0] ctx_rd32_win;logic [TOK_W-1:0] ctx_rd32_tok;
  logic [CO32_W-1:0] ctx_rd32_co;logic ctx_rd32_valid;logic signed [255:0] ctx_rd32_data;
  swin_window_mem16x32_bridge #(.NUM_WINDOWS(NUM_WINDOWS),.TOKENS_PER_WINDOW(WTOKENS),.CHANNELS(CHANNELS)) CTX(
    .clk,
    .wr16_valid(1'b0),.wr16_window_id('0),.wr16_token_id('0),.wr16_co_tile('0),.wr16_data('0),
    .rd16_en(1'b0),.rd16_window_id('0),.rd16_token_id('0),.rd16_co_tile('0),.rd16_valid(),.rd16_data(),
    .wr32_valid(ctx_wr_v),.wr32_window_id(ctx_wr_win),.wr32_token_id(ctx_wr_tok),.wr32_co_tile(ctx_wr_co),.wr32_data(ctx_wr_data),
    .rd32_en(ctx_rd32_en),.rd32_window_id(ctx_rd32_win),.rd32_token_id(ctx_rd32_tok),.rd32_co_tile(ctx_rd32_co),
    .rd32_valid(ctx_rd32_valid),.rd32_data(ctx_rd32_data)
  );

  // ---- Attention projection fused with inverse shift and residual-1 --------
  logic psrc_en;logic [TOKEN_W-1:0] psrc_tok;logic [CO32_W-1:0] psrc_co;
  logic pov;logic [TOKEN_W-1:0] ptok;logic [CO32_W-1:0] pco;logic signed [255:0] pdata;
  always_comb begin
    ctx_rd32_en=psrc_en;ctx_rd32_win=flat_window_id(psrc_tok);
    ctx_rd32_tok=flat_token_id(psrc_tok);ctx_rd32_co=psrc_co;
  end

  swin_dense_live_stage_shared32_client #(
    .TOKENS(PIXELS),.CIN(CHANNELS),.COUT(CHANNELS),
    .WEIGHT_MEM({ASSET_DIR,"/dense/proj_weight_i8_packed32.mem"}),
    .BIAS_MEM({ASSET_DIR,"/dense/proj_folded_bias_i32.mem"}),
    .M_MEM({ASSET_DIR,"/dense/proj_requant_M_i32.mem"}),
    .SHIFT_MEM({ASSET_DIR,"/dense/proj_requant_shift_i16.mem"}),.POST_ROUTE_ID(POST_ROUTE_BASE+1)
  ) PROJ(
    .clk,.rst_n,.start(proj_start),.busy(),.done(proj_done),
    .src_rd_en(psrc_en),.src_rd_token(psrc_tok),.src_rd_co_tile(psrc_co),
    .src_rd_valid(ctx_rd32_valid),.src_rd_data(ctx_rd32_data),
    .out_valid(pov),.out_token(ptok),.out_co_tile(pco),.out_data(pdata),
    .client_req(mac_req[2]),.client_grant(mac_grant[2]),
    .client_cfg_tokens_m1(mac_cfg_tokens_m1[2]),.client_cfg_k_tiles_m1(mac_cfg_k_tiles_m1[2]),.client_cfg_n_tiles_m1(mac_cfg_n_tiles_m1[2]),
    .client_input_valid(mac_input_valid[2]),.client_weight_valid(mac_weight_valid[2]),
    .client_input_vector(mac_input_vector[2]),.client_weight_row_values(mac_weight_row_values[2]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(post_valid_i[1]),.post_in_route(post_route_i[1]),.post_in_op(post_op_i[1]),
    .post_in_layer(post_layer_i[1]),.post_in_token(post_token_i[1]),.post_in_co(post_co_i[1]),
    .post_in_value(post_value_i[1]),.post_in_multiplier(post_multiplier_i[1]),.post_in_shift(post_shift_i[1]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );

  swin_proj_inverse_residual_fused32 #(
    .H(H),.W(W),.CHANNELS(CHANNELS),.WS(WS),.SHIFT(SHIFT),
    .A_M_FILE({ASSET_DIR,"/residual/res1_a_M_i32.mem"}),
    .A_SHIFT_FILE({ASSET_DIR,"/residual/res1_a_shift_i16.mem"}),
    .B_M_FILE({ASSET_DIR,"/residual/res1_b_M_i32.mem"}),
    .B_SHIFT_FILE({ASSET_DIR,"/residual/res1_b_shift_i16.mem"})
  ) FUSED_PROJ_R1(
    .clk,.rst_n,.in_valid(pov),.in_flat_token(ptok),.in_co_tile(pco),.in_data(pdata),
    .x_rd_en(prx32_rd_en),.x_rd_pixel(prx32_rd_pix),.x_rd_co_tile(prx32_rd_co),
    .x_rd_valid(prx32_rd_valid),.x_rd_data(xmem_rd32_data),
    .out_valid(res1_wr32_v),.out_pixel(res1_wr32_pix),.out_co_tile(res1_wr32_co),.out_data(res1_wr32_data)
  );

  // Reverse/residual1 are fused into PROJ. Norm2 is evaluated on demand by FC1.
  logic rev_done_q,r1_done_q,n2_done_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin rev_done_q<=1'b0;r1_done_q<=1'b0;n2_done_q<=1'b0;end
    else begin rev_done_q<=rev_start;r1_done_q<=r1_start;n2_done_q<=n2_start;end
  end
  assign rev_done=rev_done_q;assign r1_done=r1_done_q;assign n2_done=n2_done_q;

  // ---- FC1 with on-demand Norm2 ---------------------------------------------
  logic f1n2_rd32_en;logic [PIX_W-1:0] f1n2_pix32;
  logic [CO32_W-1:0] f1n2_co32;logic n2_norm_valid;
  logic [PIX_W-1:0] n2_norm_tok;logic [CO32_W-1:0] n2_norm_co;logic signed [255:0] n2_norm_data;

  swin_norm_read_adapter32 #(
    .TOKENS(PIXELS),.CHANNELS(CHANNELS),
    .NORM_LUT00_MEM({ASSET_DIR,"/norm/norm2_lut_lane00_i8.mem"}),
    .NORM_LUT01_MEM({ASSET_DIR,"/norm/norm2_lut_lane01_i8.mem"}),
    .NORM_LUT02_MEM({ASSET_DIR,"/norm/norm2_lut_lane02_i8.mem"}),
    .NORM_LUT03_MEM({ASSET_DIR,"/norm/norm2_lut_lane03_i8.mem"}),
    .NORM_LUT04_MEM({ASSET_DIR,"/norm/norm2_lut_lane04_i8.mem"}),
    .NORM_LUT05_MEM({ASSET_DIR,"/norm/norm2_lut_lane05_i8.mem"}),
    .NORM_LUT06_MEM({ASSET_DIR,"/norm/norm2_lut_lane06_i8.mem"}),
    .NORM_LUT07_MEM({ASSET_DIR,"/norm/norm2_lut_lane07_i8.mem"}),
    .NORM_LUT08_MEM({ASSET_DIR,"/norm/norm2_lut_lane08_i8.mem"}),
    .NORM_LUT09_MEM({ASSET_DIR,"/norm/norm2_lut_lane09_i8.mem"}),
    .NORM_LUT10_MEM({ASSET_DIR,"/norm/norm2_lut_lane10_i8.mem"}),
    .NORM_LUT11_MEM({ASSET_DIR,"/norm/norm2_lut_lane11_i8.mem"}),
    .NORM_LUT12_MEM({ASSET_DIR,"/norm/norm2_lut_lane12_i8.mem"}),
    .NORM_LUT13_MEM({ASSET_DIR,"/norm/norm2_lut_lane13_i8.mem"}),
    .NORM_LUT14_MEM({ASSET_DIR,"/norm/norm2_lut_lane14_i8.mem"}),
    .NORM_LUT15_MEM({ASSET_DIR,"/norm/norm2_lut_lane15_i8.mem"})
  ) NORM2_ON_DEMAND(
    .clk,.rst_n,.req_en(f1n2_rd32_en),.req_token(f1n2_pix32),.req_co_tile(f1n2_co32),
    .mem_rd_en(n2res_rd32_en),.mem_rd_token(n2res_rd32_pix),.mem_rd_co_tile(n2res_rd32_co),
    .mem_rd_valid(n2res_rd32_valid),.mem_rd_data(res1mem_rd32_data),
    .out_valid(n2_norm_valid),.out_token(n2_norm_tok),.out_co_tile(n2_norm_co),.out_data(n2_norm_data)
  );

  swin_dense_live_stage_shared32_client #(
    .TOKENS(PIXELS),.CIN(CHANNELS),.COUT(FC1_C),
    .WEIGHT_MEM({ASSET_DIR,"/dense/fc1_weight_i8_packed32.mem"}),
    .BIAS_MEM({ASSET_DIR,"/dense/fc1_folded_bias_i32.mem"}),
    .M_MEM({ASSET_DIR,"/dense/fc1_requant_M_i32.mem"}),
    .SHIFT_MEM({ASSET_DIR,"/dense/fc1_requant_shift_i16.mem"}),.POST_ROUTE_ID(POST_ROUTE_BASE+2)
  ) FC1(
    .clk,.rst_n,.start(f1_start),.busy(),.done(f1_done),
    .src_rd_en(f1n2_rd32_en),.src_rd_token(f1n2_pix32),.src_rd_co_tile(f1n2_co32),
    .src_rd_valid(n2_norm_valid),.src_rd_data(n2_norm_data),
    .out_valid(f1_wr32_v),.out_token(f1_wr32_pix),.out_co_tile(f1_wr32_co),.out_data(f1_wr32_data),
    .client_req(mac_req[3]),.client_grant(mac_grant[3]),
    .client_cfg_tokens_m1(mac_cfg_tokens_m1[3]),.client_cfg_k_tiles_m1(mac_cfg_k_tiles_m1[3]),.client_cfg_n_tiles_m1(mac_cfg_n_tiles_m1[3]),
    .client_input_valid(mac_input_valid[3]),.client_weight_valid(mac_weight_valid[3]),
    .client_input_vector(mac_input_vector[3]),.client_weight_row_values(mac_weight_row_values[3]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(post_valid_i[2]),.post_in_route(post_route_i[2]),.post_in_op(post_op_i[2]),
    .post_in_layer(post_layer_i[2]),.post_in_token(post_token_i[2]),.post_in_co(post_co_i[2]),
    .post_in_value(post_value_i[2]),.post_in_multiplier(post_multiplier_i[2]),.post_in_shift(post_shift_i[2]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );

  // Exact fused FC1 -> PolySiLU.
  swin_poly_silu_lut32 #(.LANES(32),.TOKEN_W(PIX_W),.CO_W(FC1_CO32_W),.SILU_LUT_MEM(POLY_LUT_MEM)) FUSED_POLY32(
    .clk,.rst_n,.in_valid(f1_wr32_v),.in_token(f1_wr32_pix),.in_co_tile(f1_wr32_co),.in_data(f1_wr32_data),
    .out_valid(f1_act32_v),.out_token(f1_act32_pix),.out_co_tile(f1_act32_co),.out_data(f1_act32_data)
  );

  logic poly_done_q;
  always_ff @(posedge clk or negedge rst_n) begin if(!rst_n)poly_done_q<=1'b0;else poly_done_q<=poly_start;end
  assign poly_done=poly_done_q;

  // ---- FC2 fused with residual-2 --------------------------------------------
  swin_dense_live_stage_shared32_client #(
    .TOKENS(PIXELS),.CIN(FC1_C),.COUT(CHANNELS),
    .WEIGHT_MEM({ASSET_DIR,"/dense/fc2_weight_i8_packed32.mem"}),
    .BIAS_MEM({ASSET_DIR,"/dense/fc2_folded_bias_i32.mem"}),
    .M_MEM({ASSET_DIR,"/dense/fc2_requant_M_i32.mem"}),
    .SHIFT_MEM({ASSET_DIR,"/dense/fc2_requant_shift_i16.mem"}),.POST_ROUTE_ID(POST_ROUTE_BASE+3)
  ) FC2(
    .clk,.rst_n,.start(f2_start),.busy(),.done(f2_done),
    .src_rd_en(f2_rd32_en),.src_rd_token(f2_pix32),.src_rd_co_tile(f2_co32),
    .src_rd_valid(f1a_rd32_valid),.src_rd_data(f1a_rd32_data),
    .out_valid(f2_wr32_v),.out_token(f2_wr32_pix),.out_co_tile(f2_wr32_co),.out_data(f2_wr32_data),
    .client_req(mac_req[4]),.client_grant(mac_grant[4]),
    .client_cfg_tokens_m1(mac_cfg_tokens_m1[4]),.client_cfg_k_tiles_m1(mac_cfg_k_tiles_m1[4]),.client_cfg_n_tiles_m1(mac_cfg_n_tiles_m1[4]),
    .client_input_valid(mac_input_valid[4]),.client_weight_valid(mac_weight_valid[4]),
    .client_input_vector(mac_input_vector[4]),.client_weight_row_values(mac_weight_row_values[4]),
    .svc_stream_valid,.svc_stream_token_id,.svc_active_ci_tile,.svc_active_co_tile,
    .svc_weight_row_load,.svc_weight_row_index,.svc_done,.svc_raw_valid,.svc_raw_token_id,.svc_raw_co_tile,.svc_raw_acc,
    .post_in_valid(post_valid_i[3]),.post_in_route(post_route_i[3]),.post_in_op(post_op_i[3]),
    .post_in_layer(post_layer_i[3]),.post_in_token(post_token_i[3]),.post_in_co(post_co_i[3]),
    .post_in_value(post_value_i[3]),.post_in_multiplier(post_multiplier_i[3]),.post_in_shift(post_shift_i[3]),
    .post_out_valid,.post_out_route,.post_out_op,.post_out_layer,.post_out_token,.post_out_co,.post_out_code
  );

  swin_residual_fused32 #(
    .PIXELS(PIXELS),.CHANNELS(CHANNELS),
    .A_M_FILE({ASSET_DIR,"/residual/res2_a_M_i32.mem"}),.A_SHIFT_FILE({ASSET_DIR,"/residual/res2_a_shift_i16.mem"}),
    .B_M_FILE({ASSET_DIR,"/residual/res2_b_M_i32.mem"}),.B_SHIFT_FILE({ASSET_DIR,"/residual/res2_b_shift_i16.mem"})
  ) FUSED_R2(
    .clk,.rst_n,.in_valid(f2_wr32_v),.in_token(f2_wr32_pix),.in_co_tile(f2_wr32_co),.in_data(f2_wr32_data),
    .res_rd_en(r2res_rd32_en),.res_rd_token(r2res_rd32_pix),.res_rd_co_tile(r2res_rd32_co),
    .res_rd_valid(res1_rd32_valid),.res_rd_data(res1mem_rd32_data),
    .out_valid(y_wr32_v),.out_token(y_wr32_pix),.out_co_tile(y_wr32_co),.out_data(y_wr32_data)
  );

  logic r2_done_q;
  always_ff @(posedge clk or negedge rst_n) begin if(!rst_n)r2_done_q<=1'b0;else r2_done_q<=r2_start;end
  assign r2_done=r2_done_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(rst_n&&(n1x32_rd_en&&prx32_rd_en))$fatal(1,"XMEM simultaneous QKV/projection reads");
    if(rst_n&&(n2res_rd32_en&&r2res_rd32_en))$fatal(1,"RES1MEM simultaneous Norm2/residual2 reads");
  end
`endif

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && !$onehot0(post_valid_i))
      $fatal(1, "Swin block: simultaneous post-MAC requant producers");
  end
`endif

endmodule
