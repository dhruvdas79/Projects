`timescale 1ns/1ps
// ============================================================================
// requant_s8_shiftadd_pipe.sv -- V6.2 exact current-model requant pipeline
//
// Current Alpha1 exported requant multipliers are positive and fit in 25 bits.
// The former generic signed 64x32 Booth network generated 16 partial products
// per lane.  This implementation keeps the external 32-bit interface and the
// same 7-clock latency, but removes the three provably-zero upper Booth terms.
//
// Computes, lane-wise:
//   y = sat_s8(round_shift(x * multiplier, shift))
//
// Throughput: one LANES-wide vector / clock (II=1)
// Latency   : 7 clocks (unchanged, so metadata pipelines remain compatible)
// DSP usage : zero
// ============================================================================
(* use_dsp = "no" *)
module requant_s8_shiftadd_pipe #(
    parameter int LANES = 32,
    parameter int ACTIVE_MULT_BITS = 25
) (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic signed [63:0] in_value      [0:LANES-1],
    input  logic signed [31:0] in_multiplier [0:LANES-1],
    input  logic signed [15:0] in_shift      [0:LANES-1],
    output logic out_valid,
    output logic signed [7:0] out_code       [0:LANES-1]
);
    import fixedpoint_pkg::*;

    // 25 active multiplier bits require 13 radix-4 Booth digits.
    logic valid_p0, valid_p1, valid_p2, valid_p3, valid_p4, valid_p5;

    logic signed [63:0] p_q [0:LANES-1][0:12];
    logic signed [15:0] shift_p0 [0:LANES-1];

    logic signed [63:0] a_q [0:LANES-1][0:6];
    logic signed [15:0] shift_p1 [0:LANES-1];

    logic signed [63:0] b_q [0:LANES-1][0:3];
    logic signed [15:0] shift_p2 [0:LANES-1];

    logic signed [63:0] c_q [0:LANES-1][0:1];
    logic signed [15:0] shift_p3 [0:LANES-1];

    logic signed [63:0] product_q [0:LANES-1];
    logic signed [15:0] shift_p4 [0:LANES-1];
    logic signed [63:0] rounded_q [0:LANES-1];

    initial begin
      if (ACTIVE_MULT_BITS != 25)
        $error("requant_s8_shiftadd_pipe V6.2 is qualified for ACTIVE_MULT_BITS=25");
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_p0 <= 1'b0;
            valid_p1 <= 1'b0;
            valid_p2 <= 1'b0;
            valid_p3 <= 1'b0;
            valid_p4 <= 1'b0;
            valid_p5 <= 1'b0;
            out_valid <= 1'b0;
            for (int lane = 0; lane < LANES; lane = lane + 1) begin
                shift_p0[lane] <= '0;
                shift_p1[lane] <= '0;
                shift_p2[lane] <= '0;
                shift_p3[lane] <= '0;
                shift_p4[lane] <= '0;
                product_q[lane] <= '0;
                rounded_q[lane] <= '0;
                out_code[lane] <= '0;
                for (int term = 0; term < 13; term = term + 1)
                    p_q[lane][term] <= '0;
                for (int term = 0; term < 7; term = term + 1)
                    a_q[lane][term] <= '0;
                for (int term = 0; term < 4; term = term + 1)
                    b_q[lane][term] <= '0;
                for (int term = 0; term < 2; term = term + 1)
                    c_q[lane][term] <= '0;
            end
        end else begin
            valid_p0 <= in_valid;
            valid_p1 <= valid_p0;
            valid_p2 <= valid_p1;
            valid_p3 <= valid_p2;
            valid_p4 <= valid_p3;
            valid_p5 <= valid_p4;
            out_valid <= valid_p5;

            // P0: exact radix-4 Booth terms for bits [24:0].  All exported
            // multipliers have bits [31:25] equal to zero.
            if (in_valid) begin
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    p_q[lane][0]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][1],  in_multiplier[lane][0],  1'b0});
                    p_q[lane][1]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][3],  in_multiplier[lane][2],  in_multiplier[lane][1]})  <<< 2;
                    p_q[lane][2]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][5],  in_multiplier[lane][4],  in_multiplier[lane][3]})  <<< 4;
                    p_q[lane][3]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][7],  in_multiplier[lane][6],  in_multiplier[lane][5]})  <<< 6;
                    p_q[lane][4]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][9],  in_multiplier[lane][8],  in_multiplier[lane][7]})  <<< 8;
                    p_q[lane][5]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][11], in_multiplier[lane][10], in_multiplier[lane][9]})  <<< 10;
                    p_q[lane][6]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][13], in_multiplier[lane][12], in_multiplier[lane][11]}) <<< 12;
                    p_q[lane][7]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][15], in_multiplier[lane][14], in_multiplier[lane][13]}) <<< 14;
                    p_q[lane][8]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][17], in_multiplier[lane][16], in_multiplier[lane][15]}) <<< 16;
                    p_q[lane][9]  <= booth_term_s64(in_value[lane], {in_multiplier[lane][19], in_multiplier[lane][18], in_multiplier[lane][17]}) <<< 18;
                    p_q[lane][10] <= booth_term_s64(in_value[lane], {in_multiplier[lane][21], in_multiplier[lane][20], in_multiplier[lane][19]}) <<< 20;
                    p_q[lane][11] <= booth_term_s64(in_value[lane], {in_multiplier[lane][23], in_multiplier[lane][22], in_multiplier[lane][21]}) <<< 22;
                    p_q[lane][12] <= booth_term_s64(in_value[lane], {1'b0, in_multiplier[lane][24], in_multiplier[lane][23]}) <<< 24;
                    shift_p0[lane] <= in_shift[lane];
                end
            end

            // P1: 13 -> 7.
            if (valid_p0) begin
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    a_q[lane][0] <= p_q[lane][0]  + p_q[lane][1];
                    a_q[lane][1] <= p_q[lane][2]  + p_q[lane][3];
                    a_q[lane][2] <= p_q[lane][4]  + p_q[lane][5];
                    a_q[lane][3] <= p_q[lane][6]  + p_q[lane][7];
                    a_q[lane][4] <= p_q[lane][8]  + p_q[lane][9];
                    a_q[lane][5] <= p_q[lane][10] + p_q[lane][11];
                    a_q[lane][6] <= p_q[lane][12];
                    shift_p1[lane] <= shift_p0[lane];
                end
            end

            // P2: 7 -> 4.
            if (valid_p1) begin
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    b_q[lane][0] <= a_q[lane][0] + a_q[lane][1];
                    b_q[lane][1] <= a_q[lane][2] + a_q[lane][3];
                    b_q[lane][2] <= a_q[lane][4] + a_q[lane][5];
                    b_q[lane][3] <= a_q[lane][6];
                    shift_p2[lane] <= shift_p1[lane];
                end
            end

            // P3: 4 -> 2.
            if (valid_p2) begin
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    c_q[lane][0] <= b_q[lane][0] + b_q[lane][1];
                    c_q[lane][1] <= b_q[lane][2] + b_q[lane][3];
                    shift_p3[lane] <= shift_p2[lane];
                end
            end

            // P4: final product.
            if (valid_p3) begin
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    product_q[lane] <= c_q[lane][0] + c_q[lane][1];
                    shift_p4[lane] <= shift_p3[lane];
                end
            end

            // P5: exact ties-away-from-zero rounding / variable shift.
            if (valid_p4) begin
                for (int lane = 0; lane < LANES; lane = lane + 1)
                    rounded_q[lane] <= round_shift_i64(product_q[lane], $signed(shift_p4[lane]));
            end

            // P6: final INT8 clamp.
            if (valid_p5) begin
                for (int lane = 0; lane < LANES; lane = lane + 1)
                    out_code[lane] <= sat_s8(rounded_q[lane]);
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n && in_valid) begin
        for (int lane = 0; lane < LANES; lane = lane + 1) begin
          if (in_multiplier[lane][31:25] != 7'b0)
            $fatal(1, "V6.2 requant multiplier exceeds qualified positive 25-bit range: lane=%0d value=%0d", lane, in_multiplier[lane]);
        end
      end
    end
`endif
endmodule
