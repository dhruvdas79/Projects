`timescale 1ns/1ps
// ============================================================================
// ws_systolic_pe.sv
// Weight-stationary PE with selectable 1-cycle or 2-cycle datapath.
//
// PE_LATENCY=1 (DEFAULT):
//   - cycle-compatible with the existing V6.5 design
//   - inferred DSP48E2 A*B+C with registered P output
//
// PE_LATENCY=2 (HIGH-FMAX EXPERIMENT):
//   - registers product/C-path before the final add
//   - intended to encourage DSP48E2 MREG/CREG + PREG use
//   - requires matching PE_LATENCY=2 in ws32x32_weight_stationary_core and
//     swin_shared32_mac_service (this patch propagates the parameter)
//
// The arithmetic result is bit-identical; only pipeline latency changes.
// ============================================================================
(* use_dsp = "yes" *)
module ws_systolic_pe #(
    parameter int DATA_W     = 8,
    parameter int ACC_W      = 64,
    parameter int PIX_ID_W   = 12,
    parameter int PE_LATENCY = 1
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         pipe_flush,

    input  logic                         weight_load,
    input  logic signed [DATA_W-1:0]     weight_in,

    input  logic                         act_valid_in,
    input  logic [PIX_ID_W-1:0]          act_tag_in,
    input  logic signed [DATA_W-1:0]     act_in,
    output logic                         act_valid_out,
    output logic [PIX_ID_W-1:0]          act_tag_out,
    output logic signed [DATA_W-1:0]     act_out,

    input  logic                         psum_valid_in,
    input  logic [PIX_ID_W-1:0]          psum_tag_in,
    input  logic signed [ACC_W-1:0]      psum_in,
    output logic                         psum_valid_out,
    output logic [PIX_ID_W-1:0]          psum_tag_out,
    output logic signed [ACC_W-1:0]      psum_out
);
    localparam int PRODUCT_W = 2 * DATA_W;

    logic signed [DATA_W-1:0] weight_q;

    function automatic logic signed [ACC_W-1:0] sx_product(
        input logic signed [PRODUCT_W-1:0] value
    );
        sx_product = {{(ACC_W-PRODUCT_W){value[PRODUCT_W-1]}}, value};
    endfunction

    generate
        if (PE_LATENCY == 1) begin : G_PE_LAT1
            logic signed [PRODUCT_W-1:0] product_comb;
            logic signed [ACC_W-1:0]     product_ext;
            (* use_dsp = "yes" *) logic signed [ACC_W-1:0] mac_sum_comb;

            always_comb begin
                product_comb = $signed(act_in) * $signed(weight_q);
                product_ext  = sx_product(product_comb);
                mac_sum_comb = $signed(psum_in) + $signed(product_ext);
            end

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    weight_q       <= '0;
                    act_valid_out  <= 1'b0;
                    act_tag_out    <= '0;
                    act_out        <= '0;
                    psum_valid_out <= 1'b0;
                    psum_tag_out   <= '0;
                    psum_out       <= '0;
                end else begin
                    if (weight_load)
                        weight_q <= weight_in;

                    if (pipe_flush) begin
                        // Stationary weight is intentionally retained.
                        act_valid_out  <= 1'b0;
                        act_tag_out    <= '0;
                        act_out        <= '0;
                        psum_valid_out <= 1'b0;
                        psum_tag_out   <= '0;
                        psum_out       <= '0;
                    end else begin
                        act_valid_out <= act_valid_in;
                        act_tag_out   <= act_tag_in;
                        act_out       <= act_in;

                        psum_valid_out <= psum_valid_in;
                        psum_tag_out   <= psum_tag_in;
                        if (psum_valid_in && act_valid_in)
                            psum_out <= mac_sum_comb;
                        else
                            psum_out <= '0;
                    end
                end
            end
        end else if (PE_LATENCY == 2) begin : G_PE_LAT2
            // Stage 1: register multiplier result and C/metadata paths.
            // This is the form intended to infer MREG/CREG in DSP48E2.
            (* use_dsp = "yes" *) logic signed [PRODUCT_W-1:0] product_q;
            logic signed [ACC_W-1:0]     psum_q;
            logic                         psum_valid_q;
            logic [PIX_ID_W-1:0]          psum_tag_q;

            logic signed [DATA_W-1:0]     act_q;
            logic                         act_valid_q;
            logic [PIX_ID_W-1:0]          act_tag_q;

            (* use_dsp = "yes" *) logic signed [ACC_W-1:0] mac_sum_stage2;
            always_comb begin
                mac_sum_stage2 = $signed(psum_q) + $signed(sx_product(product_q));
            end

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    weight_q       <= '0;
                    product_q      <= '0;
                    psum_q         <= '0;
                    psum_valid_q   <= 1'b0;
                    psum_tag_q     <= '0;
                    act_q          <= '0;
                    act_valid_q    <= 1'b0;
                    act_tag_q      <= '0;
                    act_valid_out  <= 1'b0;
                    act_tag_out    <= '0;
                    act_out        <= '0;
                    psum_valid_out <= 1'b0;
                    psum_tag_out   <= '0;
                    psum_out       <= '0;
                end else begin
                    if (weight_load)
                        weight_q <= weight_in;

                    if (pipe_flush) begin
                        // Stationary weight is intentionally retained.
                        product_q      <= '0;
                        psum_q         <= '0;
                        psum_valid_q   <= 1'b0;
                        psum_tag_q     <= '0;
                        act_q          <= '0;
                        act_valid_q    <= 1'b0;
                        act_tag_q      <= '0;
                        act_valid_out  <= 1'b0;
                        act_tag_out    <= '0;
                        act_out        <= '0;
                        psum_valid_out <= 1'b0;
                        psum_tag_out   <= '0;
                        psum_out       <= '0;
                    end else begin
                        // Pipeline stage 1.
                        act_q        <= act_in;
                        act_valid_q  <= act_valid_in;
                        act_tag_q    <= act_tag_in;
                        psum_q       <= psum_in;
                        psum_valid_q <= psum_valid_in;
                        psum_tag_q   <= psum_tag_in;
                        if (psum_valid_in && act_valid_in)
                            product_q <= $signed(act_in) * $signed(weight_q);
                        else
                            product_q <= '0;

                        // Pipeline stage 2 / PE outputs.
                        act_valid_out <= act_valid_q;
                        act_tag_out   <= act_tag_q;
                        act_out       <= act_q;

                        psum_valid_out <= psum_valid_q;
                        psum_tag_out   <= psum_tag_q;
                        if (psum_valid_q && act_valid_q)
                            psum_out <= mac_sum_stage2;
                        else
                            psum_out <= '0;
                    end
                end
            end
        end else begin : G_BAD_LATENCY
            always_comb begin
                act_valid_out  = 1'b0;
                act_tag_out    = '0;
                act_out        = '0;
                psum_valid_out = 1'b0;
                psum_tag_out   = '0;
                psum_out       = '0;
            end
`ifndef SYNTHESIS
            initial $fatal(1, "ws_systolic_pe: PE_LATENCY must be 1 or 2");
`endif
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (ACC_W < PRODUCT_W)
            $fatal(1, "ws_systolic_pe: ACC_W must be >= 2*DATA_W");
        if ((PE_LATENCY != 1) && (PE_LATENCY != 2))
            $fatal(1, "ws_systolic_pe: unsupported PE_LATENCY=%0d", PE_LATENCY);
    end

    always_ff @(posedge clk) begin
        if (rst_n && !pipe_flush && (psum_valid_in || act_valid_in)) begin
            if (psum_valid_in !== act_valid_in)
                $fatal(1, "ws_systolic_pe: activation/psum valid misalignment");
            if (psum_valid_in && (psum_tag_in !== act_tag_in))
                $fatal(1, "ws_systolic_pe: tag mismatch psum=%0d act=%0d",
                       psum_tag_in, act_tag_in);
        end
    end
`endif

endmodule
