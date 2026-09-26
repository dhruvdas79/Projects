`timescale 1ns/1ps
// ============================================================================
// post_swin_p3_stream_scheduler.sv
//
// Exact-model stage scheduler for the shared post-Swin MAC client.
//
// The mathematical layer set is unchanged.  Only the execution order of the
// P3 head is changed so that the classification prediction is consumed
// immediately after cls_conv2, before the regression branch starts:
//
//   stem -> cls1 -> cls2 -> cls_pred -> reg1 -> reg2 -> reg_pred -> obj_pred
//
// This shortens the lifetime of the classification tail tensor and, more
// importantly, provides an early look-ahead stage ID for a two-bank DDR/BRAM
// weight cache.  The same 32x32 MAC service remains the only compute array.
// ============================================================================
module post_swin_p3_stream_scheduler (
  input  logic [4:0] current_stage_id,
  output logic       next_valid,
  output logic [4:0] next_stage_id,
  output logic       p3_stream_active,
  output logic [2:0] p3_stream_phase,
  output logic       next_is_p3
);
  always_comb begin
    next_valid       = 1'b1;
    next_stage_id    = current_stage_id + 5'd1;
    p3_stream_active = 1'b0;
    p3_stream_phase  = 3'd0;

    unique case (current_stage_id)
      // FPN stages.
      5'd0: next_stage_id = 5'd1;
      5'd1: next_stage_id = 5'd2;
      5'd2: next_stage_id = 5'd3;
      5'd3: next_stage_id = 5'd4;
      5'd4: next_stage_id = 5'd5;

      // P3 dedicated stream order. Stage IDs remain the exported model IDs.
      5'd5:  begin next_stage_id=5'd6;  p3_stream_active=1'b1; p3_stream_phase=3'd0; end // stem
      5'd6:  begin next_stage_id=5'd7;  p3_stream_active=1'b1; p3_stream_phase=3'd1; end // cls1
      5'd7:  begin next_stage_id=5'd10; p3_stream_active=1'b1; p3_stream_phase=3'd2; end // cls2
      5'd10: begin next_stage_id=5'd8;  p3_stream_active=1'b1; p3_stream_phase=3'd3; end // cls pred
      5'd8:  begin next_stage_id=5'd9;  p3_stream_active=1'b1; p3_stream_phase=3'd4; end // reg1
      5'd9:  begin next_stage_id=5'd11; p3_stream_active=1'b1; p3_stream_phase=3'd5; end // reg2
      5'd11: begin next_stage_id=5'd12; p3_stream_active=1'b1; p3_stream_phase=3'd6; end // reg pred
      5'd12: begin next_stage_id=5'd13; p3_stream_active=1'b1; p3_stream_phase=3'd7; end // obj pred

      // P4/P5 retain their original exported order.
      5'd13: next_stage_id = 5'd14;
      5'd14: next_stage_id = 5'd15;
      5'd15: next_stage_id = 5'd16;
      5'd16: next_stage_id = 5'd17;
      5'd17: next_stage_id = 5'd18;
      5'd18: next_stage_id = 5'd19;
      5'd19: next_stage_id = 5'd20;
      5'd20: next_stage_id = 5'd21;
      5'd21: next_stage_id = 5'd22;
      5'd22: next_stage_id = 5'd23;
      5'd23: next_stage_id = 5'd24;
      5'd24: next_stage_id = 5'd25;
      5'd25: next_stage_id = 5'd26;
      5'd26: next_stage_id = 5'd27;
      5'd27: next_stage_id = 5'd28;
      5'd28: begin next_valid=1'b0; next_stage_id=5'd28; end
      default: begin next_valid=1'b0; next_stage_id=5'd0; end
    endcase

    next_is_p3 = next_valid && (next_stage_id >= 5'd5) &&
                 (next_stage_id <= 5'd12);
  end

`ifndef SYNTHESIS
  initial $display("[POST_P3_STREAM_SCHEDULER_V64_COMPILED] %m EXACT_29_STAGE_MODEL");
`endif
endmodule
