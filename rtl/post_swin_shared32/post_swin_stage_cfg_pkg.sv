`timescale 1ns/1ps
package post_swin_stage_cfg_pkg;
  localparam int POST_STAGE_COUNT = 29;
  function automatic logic [6:0] stage_h_in(input logic [4:0] id);
    case (id)
      5'd0: stage_h_in = 7'd52;
      5'd1: stage_h_in = 7'd52;
      5'd2: stage_h_in = 7'd26;
      5'd3: stage_h_in = 7'd26;
      5'd4: stage_h_in = 7'd13;
      5'd5: stage_h_in = 7'd52;
      5'd6: stage_h_in = 7'd52;
      5'd7: stage_h_in = 7'd52;
      5'd8: stage_h_in = 7'd52;
      5'd9: stage_h_in = 7'd52;
      5'd10: stage_h_in = 7'd52;
      5'd11: stage_h_in = 7'd52;
      5'd12: stage_h_in = 7'd52;
      5'd13: stage_h_in = 7'd26;
      5'd14: stage_h_in = 7'd26;
      5'd15: stage_h_in = 7'd26;
      5'd16: stage_h_in = 7'd26;
      5'd17: stage_h_in = 7'd26;
      5'd18: stage_h_in = 7'd26;
      5'd19: stage_h_in = 7'd26;
      5'd20: stage_h_in = 7'd26;
      5'd21: stage_h_in = 7'd13;
      5'd22: stage_h_in = 7'd13;
      5'd23: stage_h_in = 7'd13;
      5'd24: stage_h_in = 7'd13;
      5'd25: stage_h_in = 7'd13;
      5'd26: stage_h_in = 7'd13;
      5'd27: stage_h_in = 7'd13;
      5'd28: stage_h_in = 7'd13;
      default: stage_h_in = '0;
    endcase
  endfunction
  function automatic logic [6:0] stage_w_in(input logic [4:0] id);
    case (id)
      5'd0: stage_w_in = 7'd52;
      5'd1: stage_w_in = 7'd52;
      5'd2: stage_w_in = 7'd26;
      5'd3: stage_w_in = 7'd26;
      5'd4: stage_w_in = 7'd13;
      5'd5: stage_w_in = 7'd52;
      5'd6: stage_w_in = 7'd52;
      5'd7: stage_w_in = 7'd52;
      5'd8: stage_w_in = 7'd52;
      5'd9: stage_w_in = 7'd52;
      5'd10: stage_w_in = 7'd52;
      5'd11: stage_w_in = 7'd52;
      5'd12: stage_w_in = 7'd52;
      5'd13: stage_w_in = 7'd26;
      5'd14: stage_w_in = 7'd26;
      5'd15: stage_w_in = 7'd26;
      5'd16: stage_w_in = 7'd26;
      5'd17: stage_w_in = 7'd26;
      5'd18: stage_w_in = 7'd26;
      5'd19: stage_w_in = 7'd26;
      5'd20: stage_w_in = 7'd26;
      5'd21: stage_w_in = 7'd13;
      5'd22: stage_w_in = 7'd13;
      5'd23: stage_w_in = 7'd13;
      5'd24: stage_w_in = 7'd13;
      5'd25: stage_w_in = 7'd13;
      5'd26: stage_w_in = 7'd13;
      5'd27: stage_w_in = 7'd13;
      5'd28: stage_w_in = 7'd13;
      default: stage_w_in = '0;
    endcase
  endfunction
  function automatic logic [6:0] stage_h_out(input logic [4:0] id);
    case (id)
      5'd0: stage_h_out = 7'd52;
      5'd1: stage_h_out = 7'd26;
      5'd2: stage_h_out = 7'd26;
      5'd3: stage_h_out = 7'd13;
      5'd4: stage_h_out = 7'd13;
      5'd5: stage_h_out = 7'd52;
      5'd6: stage_h_out = 7'd52;
      5'd7: stage_h_out = 7'd52;
      5'd8: stage_h_out = 7'd52;
      5'd9: stage_h_out = 7'd52;
      5'd10: stage_h_out = 7'd52;
      5'd11: stage_h_out = 7'd52;
      5'd12: stage_h_out = 7'd52;
      5'd13: stage_h_out = 7'd26;
      5'd14: stage_h_out = 7'd26;
      5'd15: stage_h_out = 7'd26;
      5'd16: stage_h_out = 7'd26;
      5'd17: stage_h_out = 7'd26;
      5'd18: stage_h_out = 7'd26;
      5'd19: stage_h_out = 7'd26;
      5'd20: stage_h_out = 7'd26;
      5'd21: stage_h_out = 7'd13;
      5'd22: stage_h_out = 7'd13;
      5'd23: stage_h_out = 7'd13;
      5'd24: stage_h_out = 7'd13;
      5'd25: stage_h_out = 7'd13;
      5'd26: stage_h_out = 7'd13;
      5'd27: stage_h_out = 7'd13;
      5'd28: stage_h_out = 7'd13;
      default: stage_h_out = '0;
    endcase
  endfunction
  function automatic logic [6:0] stage_w_out(input logic [4:0] id);
    case (id)
      5'd0: stage_w_out = 7'd52;
      5'd1: stage_w_out = 7'd26;
      5'd2: stage_w_out = 7'd26;
      5'd3: stage_w_out = 7'd13;
      5'd4: stage_w_out = 7'd13;
      5'd5: stage_w_out = 7'd52;
      5'd6: stage_w_out = 7'd52;
      5'd7: stage_w_out = 7'd52;
      5'd8: stage_w_out = 7'd52;
      5'd9: stage_w_out = 7'd52;
      5'd10: stage_w_out = 7'd52;
      5'd11: stage_w_out = 7'd52;
      5'd12: stage_w_out = 7'd52;
      5'd13: stage_w_out = 7'd26;
      5'd14: stage_w_out = 7'd26;
      5'd15: stage_w_out = 7'd26;
      5'd16: stage_w_out = 7'd26;
      5'd17: stage_w_out = 7'd26;
      5'd18: stage_w_out = 7'd26;
      5'd19: stage_w_out = 7'd26;
      5'd20: stage_w_out = 7'd26;
      5'd21: stage_w_out = 7'd13;
      5'd22: stage_w_out = 7'd13;
      5'd23: stage_w_out = 7'd13;
      5'd24: stage_w_out = 7'd13;
      5'd25: stage_w_out = 7'd13;
      5'd26: stage_w_out = 7'd13;
      5'd27: stage_w_out = 7'd13;
      5'd28: stage_w_out = 7'd13;
      default: stage_w_out = '0;
    endcase
  endfunction
  function automatic logic [7:0] stage_cout(input logic [4:0] id);
    case (id)
      5'd0: stage_cout = 8'd128;
      5'd1: stage_cout = 8'd128;
      5'd2: stage_cout = 8'd128;
      5'd3: stage_cout = 8'd128;
      5'd4: stage_cout = 8'd128;
      5'd5: stage_cout = 8'd128;
      5'd6: stage_cout = 8'd128;
      5'd7: stage_cout = 8'd128;
      5'd8: stage_cout = 8'd128;
      5'd9: stage_cout = 8'd128;
      5'd10: stage_cout = 8'd4;
      5'd11: stage_cout = 8'd4;
      5'd12: stage_cout = 8'd1;
      5'd13: stage_cout = 8'd128;
      5'd14: stage_cout = 8'd128;
      5'd15: stage_cout = 8'd128;
      5'd16: stage_cout = 8'd128;
      5'd17: stage_cout = 8'd128;
      5'd18: stage_cout = 8'd4;
      5'd19: stage_cout = 8'd4;
      5'd20: stage_cout = 8'd1;
      5'd21: stage_cout = 8'd128;
      5'd22: stage_cout = 8'd128;
      5'd23: stage_cout = 8'd128;
      5'd24: stage_cout = 8'd128;
      5'd25: stage_cout = 8'd128;
      5'd26: stage_cout = 8'd4;
      5'd27: stage_cout = 8'd4;
      5'd28: stage_cout = 8'd1;
      default: stage_cout = '0;
    endcase
  endfunction
  function automatic logic [1:0] stage_kh(input logic [4:0] id);
    case (id)
      5'd0: stage_kh = 2'd3;
      5'd1: stage_kh = 2'd3;
      5'd2: stage_kh = 2'd3;
      5'd3: stage_kh = 2'd3;
      5'd4: stage_kh = 2'd3;
      5'd5: stage_kh = 2'd1;
      5'd6: stage_kh = 2'd3;
      5'd7: stage_kh = 2'd3;
      5'd8: stage_kh = 2'd3;
      5'd9: stage_kh = 2'd3;
      5'd10: stage_kh = 2'd1;
      5'd11: stage_kh = 2'd1;
      5'd12: stage_kh = 2'd1;
      5'd13: stage_kh = 2'd1;
      5'd14: stage_kh = 2'd3;
      5'd15: stage_kh = 2'd3;
      5'd16: stage_kh = 2'd3;
      5'd17: stage_kh = 2'd3;
      5'd18: stage_kh = 2'd1;
      5'd19: stage_kh = 2'd1;
      5'd20: stage_kh = 2'd1;
      5'd21: stage_kh = 2'd1;
      5'd22: stage_kh = 2'd3;
      5'd23: stage_kh = 2'd3;
      5'd24: stage_kh = 2'd3;
      5'd25: stage_kh = 2'd3;
      5'd26: stage_kh = 2'd1;
      5'd27: stage_kh = 2'd1;
      5'd28: stage_kh = 2'd1;
      default: stage_kh = '0;
    endcase
  endfunction
  function automatic logic [1:0] stage_kw(input logic [4:0] id);
    case (id)
      5'd0: stage_kw = 2'd3;
      5'd1: stage_kw = 2'd3;
      5'd2: stage_kw = 2'd3;
      5'd3: stage_kw = 2'd3;
      5'd4: stage_kw = 2'd3;
      5'd5: stage_kw = 2'd1;
      5'd6: stage_kw = 2'd3;
      5'd7: stage_kw = 2'd3;
      5'd8: stage_kw = 2'd3;
      5'd9: stage_kw = 2'd3;
      5'd10: stage_kw = 2'd1;
      5'd11: stage_kw = 2'd1;
      5'd12: stage_kw = 2'd1;
      5'd13: stage_kw = 2'd1;
      5'd14: stage_kw = 2'd3;
      5'd15: stage_kw = 2'd3;
      5'd16: stage_kw = 2'd3;
      5'd17: stage_kw = 2'd3;
      5'd18: stage_kw = 2'd1;
      5'd19: stage_kw = 2'd1;
      5'd20: stage_kw = 2'd1;
      5'd21: stage_kw = 2'd1;
      5'd22: stage_kw = 2'd3;
      5'd23: stage_kw = 2'd3;
      5'd24: stage_kw = 2'd3;
      5'd25: stage_kw = 2'd3;
      5'd26: stage_kw = 2'd1;
      5'd27: stage_kw = 2'd1;
      5'd28: stage_kw = 2'd1;
      default: stage_kw = '0;
    endcase
  endfunction
  function automatic logic [1:0] stage_stride(input logic [4:0] id);
    case (id)
      5'd0: stage_stride = 2'd1;
      5'd1: stage_stride = 2'd2;
      5'd2: stage_stride = 2'd1;
      5'd3: stage_stride = 2'd2;
      5'd4: stage_stride = 2'd1;
      5'd5: stage_stride = 2'd1;
      5'd6: stage_stride = 2'd1;
      5'd7: stage_stride = 2'd1;
      5'd8: stage_stride = 2'd1;
      5'd9: stage_stride = 2'd1;
      5'd10: stage_stride = 2'd1;
      5'd11: stage_stride = 2'd1;
      5'd12: stage_stride = 2'd1;
      5'd13: stage_stride = 2'd1;
      5'd14: stage_stride = 2'd1;
      5'd15: stage_stride = 2'd1;
      5'd16: stage_stride = 2'd1;
      5'd17: stage_stride = 2'd1;
      5'd18: stage_stride = 2'd1;
      5'd19: stage_stride = 2'd1;
      5'd20: stage_stride = 2'd1;
      5'd21: stage_stride = 2'd1;
      5'd22: stage_stride = 2'd1;
      5'd23: stage_stride = 2'd1;
      5'd24: stage_stride = 2'd1;
      5'd25: stage_stride = 2'd1;
      5'd26: stage_stride = 2'd1;
      5'd27: stage_stride = 2'd1;
      5'd28: stage_stride = 2'd1;
      default: stage_stride = '0;
    endcase
  endfunction
  function automatic logic [1:0] stage_pad(input logic [4:0] id);
    case (id)
      5'd0: stage_pad = 2'd1;
      5'd1: stage_pad = 2'd0;
      5'd2: stage_pad = 2'd1;
      5'd3: stage_pad = 2'd0;
      5'd4: stage_pad = 2'd1;
      5'd5: stage_pad = 2'd0;
      5'd6: stage_pad = 2'd1;
      5'd7: stage_pad = 2'd1;
      5'd8: stage_pad = 2'd1;
      5'd9: stage_pad = 2'd1;
      5'd10: stage_pad = 2'd0;
      5'd11: stage_pad = 2'd0;
      5'd12: stage_pad = 2'd0;
      5'd13: stage_pad = 2'd0;
      5'd14: stage_pad = 2'd1;
      5'd15: stage_pad = 2'd1;
      5'd16: stage_pad = 2'd1;
      5'd17: stage_pad = 2'd1;
      5'd18: stage_pad = 2'd0;
      5'd19: stage_pad = 2'd0;
      5'd20: stage_pad = 2'd0;
      5'd21: stage_pad = 2'd0;
      5'd22: stage_pad = 2'd1;
      5'd23: stage_pad = 2'd1;
      5'd24: stage_pad = 2'd1;
      5'd25: stage_pad = 2'd1;
      5'd26: stage_pad = 2'd0;
      5'd27: stage_pad = 2'd0;
      5'd28: stage_pad = 2'd0;
      default: stage_pad = '0;
    endcase
  endfunction
  function automatic logic stage_use_silu(input logic [4:0] id);
    case (id)
      5'd0: stage_use_silu = 1'b1;
      5'd1: stage_use_silu = 1'b1;
      5'd2: stage_use_silu = 1'b1;
      5'd3: stage_use_silu = 1'b1;
      5'd4: stage_use_silu = 1'b1;
      5'd5: stage_use_silu = 1'b1;
      5'd6: stage_use_silu = 1'b1;
      5'd7: stage_use_silu = 1'b1;
      5'd8: stage_use_silu = 1'b1;
      5'd9: stage_use_silu = 1'b1;
      5'd10: stage_use_silu = 1'b0;
      5'd11: stage_use_silu = 1'b0;
      5'd12: stage_use_silu = 1'b0;
      5'd13: stage_use_silu = 1'b1;
      5'd14: stage_use_silu = 1'b1;
      5'd15: stage_use_silu = 1'b1;
      5'd16: stage_use_silu = 1'b1;
      5'd17: stage_use_silu = 1'b1;
      5'd18: stage_use_silu = 1'b0;
      5'd19: stage_use_silu = 1'b0;
      5'd20: stage_use_silu = 1'b0;
      5'd21: stage_use_silu = 1'b1;
      5'd22: stage_use_silu = 1'b1;
      5'd23: stage_use_silu = 1'b1;
      5'd24: stage_use_silu = 1'b1;
      5'd25: stage_use_silu = 1'b1;
      5'd26: stage_use_silu = 1'b0;
      5'd27: stage_use_silu = 1'b0;
      5'd28: stage_use_silu = 1'b0;
      default: stage_use_silu = 1'b0;
    endcase
  endfunction
  function automatic logic [11:0] stage_tokens_m1(input logic [4:0] id);
    int unsigned h, w;
    begin
      h = stage_h_out(id);
      w = stage_w_out(id);
      stage_tokens_m1 = h*w - 1;
    end
  endfunction
  function automatic logic [5:0] stage_k_tiles_m1(input logic [4:0] id);
    int unsigned kh, kw;
    begin
      kh = stage_kh(id);
      kw = stage_kw(id);
      stage_k_tiles_m1 = kh*kw*4 - 1;
    end
  endfunction
  function automatic logic [5:0] stage_n_tiles_m1(input logic [4:0] id);
    case (stage_cout(id))
      8'd128: stage_n_tiles_m1 = 6'd3;
      default: stage_n_tiles_m1 = 6'd0;
    endcase
  endfunction
  function automatic logic [13:0] stage_expected_vectors(input logic [4:0] id);
    int unsigned h, w, nt;
    begin
      h = stage_h_out(id);
      w = stage_w_out(id);
      nt = stage_n_tiles_m1(id) + 1;
      stage_expected_vectors = h*w*nt;
    end
  endfunction
  function automatic logic [31:0] stage_last_lane_mask(input logic [4:0] id);
    case (stage_cout(id))
      8'd1: stage_last_lane_mask = 32'h0000_0001;
      8'd4: stage_last_lane_mask = 32'h0000_000f;
      default: stage_last_lane_mask = 32'hffff_ffff;
    endcase
  endfunction
endpackage
