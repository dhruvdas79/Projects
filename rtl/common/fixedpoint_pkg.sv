`timescale 1ns/1ps
// ============================================================================
// fixedpoint_pkg.sv
// Alpha1 strict fixed-point helper set.
//
// FAST-NODSP revision:
//   * All non-MAC 64x32 scale products use exact radix-4 Booth shift/add.
//   * The reduction tree is balanced (not a 32-term serial adder chain).
//   * No '*' operator exists in the requant / norm / residual helpers.
//   * Signed rounding and saturation remain bit-exact with the baseline.
//
// The only intended DSP multiplier in the active design is the multiplier in
// rtl/dense/ws_systolic_pe.sv.
// ============================================================================
package fixedpoint_pkg;

  typedef logic signed [7:0] s8_t;
  typedef logic        [7:0] u8_t;

  function automatic s8_t sat_s8(input longint signed x);
    begin
      if (x > 64'sd127)
        sat_s8 = 8'sd127;
      else if (x < -64'sd128)
        sat_s8 = 8'sh80;
      else
        sat_s8 = s8_t'(x);
    end
  endfunction

  function automatic u8_t sat_u8(input longint signed x);
    begin
      if (x < 0)
        sat_u8 = 8'd0;
      else if (x > 64'sd255)
        sat_u8 = 8'hff;
      else
        sat_u8 = u8_t'(x);
    end
  endfunction

  // Strict signed nearest rounding following divide-by-2^shift.
  // shift > 0: exact .5 ties go away from zero.
  // shift < 0: exact left shift.
  function automatic longint signed round_shift(
      input longint signed value,
      input integer signed shift
  );
    longint signed half;
    begin
      if (shift > 0) begin
        half = 64'sd1 <<< (shift - 1);
        if (value >= 0)
          round_shift = (value + half) >>> shift;
        else
          round_shift = -(((-value + half) >>> shift));
      end
      else if (shift < 0)
        round_shift = value <<< (-shift);
      else
        round_shift = value;
    end
  endfunction

  function automatic logic signed [63:0] round_shift_i64(
      input logic signed [63:0] value,
      input integer signed shift
  );
    begin
      round_shift_i64 = round_shift(value, shift);
    end
  endfunction

  // One radix-4 Booth digit: -2, -1, 0, +1, or +2 times x.
  function automatic longint signed booth_term_s64(
      input longint signed x,
      input logic [2:0] code
  );
    begin
      case (code)
        3'b001, 3'b010: booth_term_s64 = x;
        3'b011:         booth_term_s64 = x <<< 1;
        3'b100:         booth_term_s64 = -(x <<< 1);
        3'b101, 3'b110: booth_term_s64 = -x;
        default:        booth_term_s64 = 64'sd0;
      endcase
    end
  endfunction

  // Exact signed 64x32 product, reduced as a balanced tree.
  // Arithmetic is intentionally 64-bit two's-complement, matching the old
  // longint product assignment used by the strict RTL.
  function automatic longint signed mul_s64_s32_shiftadd(
      input longint signed x,
      input logic signed [31:0] mult
  );
    longint signed p0,p1,p2,p3,p4,p5,p6,p7;
    longint signed p8,p9,p10,p11,p12,p13,p14,p15;
    longint signed a0,a1,a2,a3,a4,a5,a6,a7;
    longint signed b0,b1,b2,b3;
    longint signed c0,c1;
    begin
      p0  = booth_term_s64(x, {mult[1],  mult[0],  1'b0});
      p1  = booth_term_s64(x, {mult[3],  mult[2],  mult[1]})  <<< 2;
      p2  = booth_term_s64(x, {mult[5],  mult[4],  mult[3]})  <<< 4;
      p3  = booth_term_s64(x, {mult[7],  mult[6],  mult[5]})  <<< 6;
      p4  = booth_term_s64(x, {mult[9],  mult[8],  mult[7]})  <<< 8;
      p5  = booth_term_s64(x, {mult[11], mult[10], mult[9]})  <<< 10;
      p6  = booth_term_s64(x, {mult[13], mult[12], mult[11]}) <<< 12;
      p7  = booth_term_s64(x, {mult[15], mult[14], mult[13]}) <<< 14;
      p8  = booth_term_s64(x, {mult[17], mult[16], mult[15]}) <<< 16;
      p9  = booth_term_s64(x, {mult[19], mult[18], mult[17]}) <<< 18;
      p10 = booth_term_s64(x, {mult[21], mult[20], mult[19]}) <<< 20;
      p11 = booth_term_s64(x, {mult[23], mult[22], mult[21]}) <<< 22;
      p12 = booth_term_s64(x, {mult[25], mult[24], mult[23]}) <<< 24;
      p13 = booth_term_s64(x, {mult[27], mult[26], mult[25]}) <<< 26;
      p14 = booth_term_s64(x, {mult[29], mult[28], mult[27]}) <<< 28;
      p15 = booth_term_s64(x, {mult[31], mult[30], mult[29]}) <<< 30;

      a0 = p0  + p1;   a1 = p2  + p3;
      a2 = p4  + p5;   a3 = p6  + p7;
      a4 = p8  + p9;   a5 = p10 + p11;
      a6 = p12 + p13;  a7 = p14 + p15;
      b0 = a0 + a1;    b1 = a2 + a3;
      b2 = a4 + a5;    b3 = a6 + a7;
      c0 = b0 + b1;    c1 = b2 + b3;
      mul_s64_s32_shiftadd = c0 + c1;
    end
  endfunction

  // Exact signed-64 by unsigned-32 product. The extra p16 term is the
  // zero-extension correction required by radix-4 Booth recoding.
  function automatic longint signed mul_s64_u32_shiftadd(
      input longint signed x,
      input logic [31:0] mult_u32
  );
    longint signed p0,p1,p2,p3,p4,p5,p6,p7;
    longint signed p8,p9,p10,p11,p12,p13,p14,p15,p16;
    longint signed a0,a1,a2,a3,a4,a5,a6,a7,a8;
    longint signed b0,b1,b2,b3,b4;
    longint signed c0,c1,c2;
    longint signed d0;
    begin
      p0  = booth_term_s64(x, {mult_u32[1],  mult_u32[0],  1'b0});
      p1  = booth_term_s64(x, {mult_u32[3],  mult_u32[2],  mult_u32[1]})  <<< 2;
      p2  = booth_term_s64(x, {mult_u32[5],  mult_u32[4],  mult_u32[3]})  <<< 4;
      p3  = booth_term_s64(x, {mult_u32[7],  mult_u32[6],  mult_u32[5]})  <<< 6;
      p4  = booth_term_s64(x, {mult_u32[9],  mult_u32[8],  mult_u32[7]})  <<< 8;
      p5  = booth_term_s64(x, {mult_u32[11], mult_u32[10], mult_u32[9]})  <<< 10;
      p6  = booth_term_s64(x, {mult_u32[13], mult_u32[12], mult_u32[11]}) <<< 12;
      p7  = booth_term_s64(x, {mult_u32[15], mult_u32[14], mult_u32[13]}) <<< 14;
      p8  = booth_term_s64(x, {mult_u32[17], mult_u32[16], mult_u32[15]}) <<< 16;
      p9  = booth_term_s64(x, {mult_u32[19], mult_u32[18], mult_u32[17]}) <<< 18;
      p10 = booth_term_s64(x, {mult_u32[21], mult_u32[20], mult_u32[19]}) <<< 20;
      p11 = booth_term_s64(x, {mult_u32[23], mult_u32[22], mult_u32[21]}) <<< 22;
      p12 = booth_term_s64(x, {mult_u32[25], mult_u32[24], mult_u32[23]}) <<< 24;
      p13 = booth_term_s64(x, {mult_u32[27], mult_u32[26], mult_u32[25]}) <<< 26;
      p14 = booth_term_s64(x, {mult_u32[29], mult_u32[28], mult_u32[27]}) <<< 28;
      p15 = booth_term_s64(x, {mult_u32[31], mult_u32[30], mult_u32[29]}) <<< 30;
      p16 = booth_term_s64(x, {2'b00, mult_u32[31]}) <<< 32;

      a0 = p0  + p1;   a1 = p2  + p3;
      a2 = p4  + p5;   a3 = p6  + p7;
      a4 = p8  + p9;   a5 = p10 + p11;
      a6 = p12 + p13;  a7 = p14 + p15;
      a8 = p16;
      b0 = a0 + a1;    b1 = a2 + a3;
      b2 = a4 + a5;    b3 = a6 + a7;
      b4 = a8;
      c0 = b0 + b1;    c1 = b2 + b3;    c2 = b4;
      d0 = c0 + c1;
      mul_s64_u32_shiftadd = d0 + c2;
    end
  endfunction

  // Wide value; intentionally no final clamp.
  function automatic longint signed apply_mshift(
      input longint signed x,
      input longint signed mult,
      input integer signed shift
  );
    logic signed [31:0] mult32;
    longint signed product;
    begin
      mult32 = mult[31:0];
      product = mul_s64_s32_shiftadd(x, mult32);
      apply_mshift = round_shift(product, shift);
    end
  endfunction

  function automatic logic signed [63:0] apply_mshift_i64(
      input logic signed [63:0] value,
      input logic signed [31:0] multiplier,
      input integer signed shift
  );
    begin
      apply_mshift_i64 = round_shift_i64(
          mul_s64_s32_shiftadd(value, multiplier), shift
      );
    end
  endfunction

  function automatic longint signed apply_mshift_u32(
      input longint signed x,
      input logic [31:0] mult_u32,
      input integer signed shift
  );
    begin
      apply_mshift_u32 = round_shift(
          mul_s64_u32_shiftadd(x, mult_u32), shift
      );
    end
  endfunction

  function automatic s8_t requantize_s8(
      input longint signed acc,
      input longint signed mult,
      input integer signed shift
  );
    begin
      requantize_s8 = sat_s8(apply_mshift(acc, mult, shift));
    end
  endfunction

  function automatic u8_t requantize_u8(
      input longint signed acc,
      input longint signed mult,
      input integer signed shift
  );
    begin
      requantize_u8 = sat_u8(apply_mshift(acc, mult, shift));
    end
  endfunction

  function automatic s8_t requant_add_s8(
      input s8_t a_code,
      input longint signed a_mult,
      input integer signed a_shift,
      input s8_t b_code,
      input longint signed b_mult,
      input integer signed b_shift
  );
    longint signed a_aligned;
    longint signed b_aligned;
    begin
      a_aligned = apply_mshift($signed(a_code), a_mult, a_shift);
      b_aligned = apply_mshift($signed(b_code), b_mult, b_shift);
      requant_add_s8 = sat_s8(a_aligned + b_aligned);
    end
  endfunction

endpackage
