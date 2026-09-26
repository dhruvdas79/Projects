// ============================================================================
// poly_silu_lane_pipe.sv
// One fully-pipelined, exact integer PolySiLU lane.
//
// Input  : one pre-SiLU signed INT8 code each clock.
// Output : one final activation signed INT8 code each clock after latency 5.
//
// The lane uses an 8-segment Q20 cubic with Q15 local fraction.  It does NOT
// implement a 256-entry input/output activation LUT.
//
// Pipeline:
//   S0: sign/abs, clamp test, segment, t(Q15)
//   S1: coefficient read, Horner step 1, u->Q20
//   S2: Horner step 2
//   S3: Horner step 3
//   S4: sign path + output requants
//   S5: clamp override + INT8 saturation
// ============================================================================
module poly_silu_lane_pipe_universal #(
    parameter logic [31:0] PRE_SCALE_Q      = 32'd1,
    parameter integer      PRE_SCALE_SHIFT  = 0,
    parameter logic [31:0] CLAMP_Q          = 32'd8,
    parameter integer      CLAMP_SHIFT      = 0,
    parameter logic        [31:0] H_TO_OUT_M      = 32'd1,
    parameter integer               H_TO_OUT_SHIFT = 0,
    parameter logic        [31:0] U_TO_Q20_M      = 32'd1,
    parameter integer               U_TO_Q20_SHIFT = 0,
    parameter logic        [31:0] X_TO_OUT_M      = 32'd1,
    parameter integer               X_TO_OUT_SHIFT = 0,
    parameter [8*256-1:0] COEFF_MEM = ""
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              in_valid,
    input  logic [11:0]       in_pixel_index,
    input  logic [8:0]        in_channel_base,
    input  logic signed [7:0] in_code,

    output logic              out_valid,
    output logic [11:0]       out_pixel_index,
    output logic [8:0]        out_channel_base,
    output logic signed [7:0] out_code
);
    import fixedpoint_pkg::*;

    // Each of the 16 outer lanes receives its own tiny replicated 32x32 ROM.
    // This provides 16 independent coefficient reads every cycle.
    logic signed [31:0] coeff_mem [0:31];

    // S0 decoded values.
    logic signed [8:0]  in_ext_d;
    logic               is_neg_d;
    logic        [8:0]  abs_q_d;
    logic        [63:0] u_num_d;
    logic        [95:0] clamp_lhs_d;
    logic        [95:0] clamp_rhs_d;
    logic               clamp_hit_d;
    logic        [63:0] floor_u_d;
    logic        [2:0]  segment_d;
    logic        [63:0] rem_d;
    logic        [95:0] t_num_d;
    logic        [95:0] t_round_d;
    logic        [14:0] t_q15_d;

    // S0 registers.
    logic              v0;
    logic signed [7:0] in0;
    logic              neg0;
    logic        [8:0] abs0;
    logic              clamp0;
    logic        [2:0] seg0;
    logic        [14:0] t0;
    logic [11:0]       pix0;
    logic [8:0]        ch0;

    // Coefficients selected from S0 segment.
    logic signed [31:0] a0, b0, c0, d0;

    // S1 registers.
    logic              v1;
    logic signed [31:0] h1;
    logic signed [31:0] c1, d1;
    logic signed [31:0] u_q20_1;
    logic signed [7:0] in1;
    logic              neg1, clamp1;
    logic        [14:0] t1;
    logic [11:0]       pix1;
    logic [8:0]        ch1;

    // S2 registers.
    logic              v2;
    logic signed [31:0] h2;
    logic signed [31:0] d2;
    logic signed [31:0] u_q20_2;
    logic signed [7:0] in2;
    logic              neg2, clamp2;
    logic        [14:0] t2;
    logic [11:0]       pix2;
    logic [8:0]        ch2;

    // S3 registers.
    logic              v3;
    logic signed [31:0] h3;
    logic signed [31:0] u_q20_3;
    logic signed [7:0] in3;
    logic              neg3, clamp3;
    logic [11:0]       pix3;
    logic [8:0]        ch3;

    // S4 registers.
    logic              v4;
    logic signed [63:0] normal_code4;
    logic signed [63:0] identity_code4;
    logic              neg4, clamp4;
    logic [11:0]       pix4;
    logic [8:0]        ch4;

    // S3/S4 combinational helper values.
    logic signed [31:0] h3_ext;
    logic signed [31:0] signed_result_s3;
    logic signed [63:0] normal_code_s3;
    logic signed [63:0] identity_code_s3;
    logic signed [63:0] final_code_s4;

    // 32-bit Q20 Horner state is sufficient for the exported Alpha1
    // coefficients (generator checks the actual range). This intentionally
    // infers a compact 32x16 multiplier instead of a 64x64 multiplier.
    function automatic logic signed [31:0] mul_q20_by_q15(
        input logic signed [31:0] value_q20,
        input logic        [14:0] frac_q15
    );
        logic signed [15:0] frac_ext;
        logic signed [47:0] product;
        logic signed [63:0] rounded;
        begin
            frac_ext = {1'b0, frac_q15};
            product = value_q20 * frac_ext;
            rounded = round_shift_i64({{16{product[47]}}, product}, 15);
            mul_q20_by_q15 = rounded[31:0];
        end
    endfunction

    // Used for |x|->Q20, Q20->activation code, and identity conversion.
    // It keeps operand widths at 32x32; the exact Alpha1 products fit signed
    // 64-bit and are checked by the asset generator.
    // Alpha1 PolySiLU scale multipliers are positive Q-format values. Some
    // legitimate values exceed signed-INT32 maximum, so keep the multiplier
    // unsigned and sign-extend only the input value before multiplication.
    function automatic logic signed [63:0] apply_mshift_s32_u(
        input logic signed [31:0] value,
        input logic        [31:0] multiplier,
        input integer signed      shift
    );
        logic signed [63:0] value_ext;
        logic signed [63:0] mult_ext;
        logic signed [63:0] product;
        begin
            value_ext = {{32{value[31]}}, value};
            mult_ext  = {32'd0, multiplier};
            product   = value_ext * mult_ext;
            apply_mshift_s32_u = round_shift_i64(product, shift);
        end
    endfunction

    initial begin
        $readmemh(COEFF_MEM, coeff_mem);
    end

    // S0 exact fraction arithmetic. PRE_SCALE_Q / 2^PRE_SCALE_SHIFT is the
    // same FixedValue represented by the strict Python simulator.
    always_comb begin
        in_ext_d = {in_code[7], in_code};
        is_neg_d = (in_ext_d < 0);
        if (is_neg_d)
            abs_q_d = -in_ext_d;        // abs(-128)=128; hence 9 bits.
        else
            abs_q_d = in_ext_d;

        u_num_d = $unsigned(abs_q_d) * $unsigned(PRE_SCALE_Q);

        // u >= clamp without any floating-point division.
        clamp_lhs_d = {32'd0, u_num_d} << CLAMP_SHIFT;
        clamp_rhs_d = {64'd0, CLAMP_Q} << PRE_SCALE_SHIFT;
        clamp_hit_d = (clamp_lhs_d >= clamp_rhs_d);

        floor_u_d = u_num_d >> PRE_SCALE_SHIFT;
        if (floor_u_d > 64'd7)
            segment_d = 3'd7;
        else
            segment_d = floor_u_d[2:0];

        // For u>=8, strict code deliberately still forms seg=7 then later
        // overwrites the polynomial with the boundary contract.
        rem_d = u_num_d - ({61'd0, segment_d} << PRE_SCALE_SHIFT);
        t_num_d = {32'd0, rem_d} << 15;
        if (PRE_SCALE_SHIFT == 0)
            t_round_d = t_num_d;
        else
            t_round_d = (t_num_d + (96'd1 << (PRE_SCALE_SHIFT - 1)))
                        >> PRE_SCALE_SHIFT;
        if (t_round_d > 96'd32767)
            t_q15_d = 15'd32767;
        else
            t_q15_d = t_round_d[14:0];
    end

    always_comb begin
        a0 = coeff_mem[{seg0, 2'b00}];
        b0 = coeff_mem[{seg0, 2'b01}];
        c0 = coeff_mem[{seg0, 2'b10}];
        d0 = coeff_mem[{seg0, 2'b11}];

        h3_ext = h3;
        if (neg3)
            signed_result_s3 = h3_ext - u_q20_3;
        else
            signed_result_s3 = h3_ext;

        normal_code_s3 = apply_mshift_s32_u(
            signed_result_s3, H_TO_OUT_M, H_TO_OUT_SHIFT
        );
        identity_code_s3 = apply_mshift_s32_u(
            {{24{in3[7]}}, in3}, X_TO_OUT_M, X_TO_OUT_SHIFT
        );

        if (clamp4) begin
            if (neg4)
                final_code_s4 = 64'sd0;
            else
                final_code_s4 = identity_code4;
        end
        else begin
            final_code_s4 = normal_code4;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0              <= 1'b0;
            v1              <= 1'b0;
            v2              <= 1'b0;
            v3              <= 1'b0;
            v4              <= 1'b0;
            out_valid       <= 1'b0;
            out_code        <= '0;
            out_pixel_index <= '0;
            out_channel_base <= '0;
        end
        else begin
            // S0
            v0 <= in_valid;
            if (in_valid) begin
                in0    <= in_code;
                neg0   <= is_neg_d;
                abs0   <= abs_q_d;
                clamp0 <= clamp_hit_d;
                seg0   <= segment_d;
                t0     <= t_q15_d;
                pix0   <= in_pixel_index;
                ch0    <= in_channel_base;
            end

            // S1: first Horner multiply/add and conversion of |x| to Q20.
            v1 <= v0;
            if (v0) begin
                h1       <= mul_q20_by_q15(a0, t0) + b0;
                c1       <= c0;
                d1       <= d0;
                u_q20_1  <= apply_mshift_s32_u(
                            {{23{1'b0}}, abs0}, U_TO_Q20_M, U_TO_Q20_SHIFT
                           );
                in1      <= in0;
                neg1     <= neg0;
                clamp1   <= clamp0;
                t1       <= t0;
                pix1     <= pix0;
                ch1      <= ch0;
            end

            // S2: second Horner multiply/add.
            v2 <= v1;
            if (v1) begin
                h2       <= mul_q20_by_q15(h1, t1) + c1;
                d2       <= d1;
                u_q20_2  <= u_q20_1;
                in2      <= in1;
                neg2     <= neg1;
                clamp2   <= clamp1;
                t2       <= t1;
                pix2     <= pix1;
                ch2      <= ch1;
            end

            // S3: final Horner multiply/add.
            v3 <= v2;
            if (v2) begin
                h3       <= mul_q20_by_q15(h2, t2) + d2;
                u_q20_3  <= u_q20_2;
                in3      <= in2;
                neg3     <= neg2;
                clamp3   <= clamp2;
                pix3     <= pix2;
                ch3      <= ch2;
            end

            // S4: negative identity and final-code-domain requants.
            v4 <= v3;
            if (v3) begin
                normal_code4   <= normal_code_s3;
                identity_code4 <= identity_code_s3;
                neg4           <= neg3;
                clamp4         <= clamp3;
                pix4           <= pix3;
                ch4            <= ch3;
            end

            // S5: exact clamp override and signed INT8 saturation.
            out_valid <= v4;
            if (v4) begin
                out_code         <= sat_s8(final_code_s4);
                out_pixel_index  <= pix4;
                out_channel_base <= ch4;
            end
        end
    end
endmodule
