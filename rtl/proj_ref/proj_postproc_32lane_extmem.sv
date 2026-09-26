`timescale 1ns/1ps
// ============================================================================
// proj_postproc_32lane_extmem.sv -- FAST-NODSP
//
// 32-lane projection postprocess, fully throughput-pipelined:
//   S1      : bias add + requant descriptor capture
//   S2..S8  : exact radix-4 Booth shift/add requant (II=1, zero DSP)
//   S9      : exact 256-entry PolySiLU output LUT
//
// The legacy runtime polynomial ports remain for interface compatibility. The
// active path uses bit-exact, pre-generated P3/P4/P5 INT8 output LUTs.
// ============================================================================
(* use_dsp = "no" *)
module proj_postproc_32lane_extmem #(
    parameter int LANES = 32,
    parameter int COUT  = 128,
    parameter [8*256-1:0] P3_SILU_LUT_MEM = "generated_projection/p3_silu_lut_i8.mem",
    parameter [8*256-1:0] P4_SILU_LUT_MEM = "generated_projection/p4_silu_lut_i8.mem",
    parameter [8*256-1:0] P5_SILU_LUT_MEM = "generated_projection/p5_silu_lut_i8.mem"
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       in_valid,
    input  logic [1:0]                 in_layer_id,
    input  logic [11:0]                in_pixel_index,
    input  logic [6:0]                 in_channel_base,
    input  logic signed [LANES*64-1:0] mac_sum_data,

    input  logic signed [31:0]         bias_vec_i [0:LANES-1],
    input  logic signed [31:0]         requant_m_vec_i [0:LANES-1],
    input  logic        [15:0]         requant_shift_vec_i [0:LANES-1],
    input  logic signed [31:0]         poly_coeff_i [0:31],

    input  logic        [31:0]         pre_scale_q_i,
    input  logic        [5:0]          pre_scale_shift_i,
    input  logic        [31:0]         clamp_q_i,
    input  logic        [5:0]          clamp_shift_i,
    input  logic signed [31:0]         h_to_out_m_i,
    input  logic        [5:0]          h_to_out_shift_i,
    input  logic signed [31:0]         u_to_q20_m_i,
    input  logic        [5:0]          u_to_q20_shift_i,
    input  logic signed [31:0]         x_to_out_m_i,
    input  logic        [5:0]          x_to_out_shift_i,

    output logic                       acc_valid_dbg,
    output logic [1:0]                 acc_layer_id_dbg,
    output logic [11:0]                acc_pixel_index_dbg,
    output logic [6:0]                 acc_channel_base_dbg,
    output logic signed [LANES*64-1:0] acc_with_bias_dbg,

    output logic                       pre_valid_dbg,
    output logic [1:0]                 pre_layer_id_dbg,
    output logic [11:0]                pre_pixel_index_dbg,
    output logic [6:0]                 pre_channel_base_dbg,
    output logic signed [LANES*8-1:0]  pre_silu_data_dbg,

    output logic                       out_valid,
    output logic [1:0]                 out_layer_id,
    output logic [11:0]                out_pixel_index,
    output logic [6:0]                 out_channel_base,
    output logic signed [LANES*8-1:0]  out_data
);
    localparam int REQ_LAT = 7;

    logic signed [LANES*64-1:0] acc_comb_data;
    logic signed [31:0] m_q [0:LANES-1];
    logic signed [15:0] s_q [0:LANES-1];
    logic signed [63:0] req_value [0:LANES-1];
    logic req_valid;
    logic signed [7:0] req_code [0:LANES-1];

    logic [1:0] layer_pipe [0:REQ_LAT-1];
    logic [11:0] pixel_pipe [0:REQ_LAT-1];
    logic [6:0] channel_pipe [0:REQ_LAT-1];
    logic meta_valid [0:REQ_LAT-1];

    integer stage;
    integer r;

    // S1 combinational bias add.
    always_comb begin
        for (int g=0; g<LANES; g=g+1) begin
            logic signed [63:0] mac_lane;
            logic signed [63:0] bias_lane;
            int channel_index;
            channel_index = $unsigned(in_channel_base) + g;
            mac_lane = mac_sum_data[g*64 +: 64];
            bias_lane = 64'sd0;
            if (channel_index < COUT)
                bias_lane = {{32{bias_vec_i[g][31]}}, bias_vec_i[g]};
            acc_comb_data[g*64 +: 64] =
                (channel_index < COUT) ? ($signed(mac_lane) + $signed(bias_lane)) : 64'sd0;
            req_value[g] = acc_with_bias_dbg[g*64 +: 64];
        end
    end

    requant_s8_shiftadd_pipe #(.LANES(LANES)) u_requant_pipe (
        .clk(clk), .rst_n(rst_n),
        .in_valid(acc_valid_dbg),
        .in_value(req_value),
        .in_multiplier(m_q),
        .in_shift(s_q),
        .out_valid(req_valid),
        .out_code(req_code)
    );

    // Expose the exact requant output as the pre-PolySiLU debug stream.
    always_comb begin
        pre_valid_dbg = req_valid;
        pre_layer_id_dbg = layer_pipe[REQ_LAT-1];
        pre_pixel_index_dbg = pixel_pipe[REQ_LAT-1];
        pre_channel_base_dbg = channel_pipe[REQ_LAT-1];
        for (int p=0; p<LANES; p=p+1)
            pre_silu_data_dbg[p*8 +: 8] = req_code[p];
    end

    // One private 256-entry distributed ROM per lane gives 32 reads per clock.
    logic signed [7:0] lut_code [0:LANES-1];
    genvar lane;
    generate
        for (lane=0; lane<LANES; lane=lane+1) begin : G_SILU_LUT
            (* rom_style = "distributed" *) logic signed [7:0] p3_lut [0:255];
            (* rom_style = "distributed" *) logic signed [7:0] p4_lut [0:255];
            (* rom_style = "distributed" *) logic signed [7:0] p5_lut [0:255];
            initial begin
                $readmemh(P3_SILU_LUT_MEM, p3_lut);
                $readmemh(P4_SILU_LUT_MEM, p4_lut);
                $readmemh(P5_SILU_LUT_MEM, p5_lut);
            end
            always_comb begin
                case (pre_layer_id_dbg)
                    2'd0: lut_code[lane] = p3_lut[$unsigned(pre_silu_data_dbg[lane*8 +: 8])];
                    2'd1: lut_code[lane] = p4_lut[$unsigned(pre_silu_data_dbg[lane*8 +: 8])];
                    default: lut_code[lane] = p5_lut[$unsigned(pre_silu_data_dbg[lane*8 +: 8])];
                endcase
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_valid_dbg <= 1'b0;
            out_valid <= 1'b0;
            acc_layer_id_dbg <= '0; out_layer_id <= '0;
            acc_pixel_index_dbg <= '0; out_pixel_index <= '0;
            acc_channel_base_dbg <= '0; out_channel_base <= '0;
            acc_with_bias_dbg <= '0; out_data <= '0;
            for (r=0; r<LANES; r=r+1) begin m_q[r]<='0; s_q[r]<='0; end
            for(stage=0; stage<REQ_LAT; stage=stage+1) begin
                meta_valid[stage] <= 1'b0;
                layer_pipe[stage] <= '0;
                pixel_pipe[stage] <= '0;
                channel_pipe[stage] <= '0;
            end
        end else begin
            // S1 register.
            acc_valid_dbg <= in_valid;
            if (in_valid) begin
                acc_layer_id_dbg <= in_layer_id;
                acc_pixel_index_dbg <= in_pixel_index;
                acc_channel_base_dbg <= in_channel_base;
                acc_with_bias_dbg <= acc_comb_data;
                for (r=0; r<LANES; r=r+1) begin
                    m_q[r] <= requant_m_vec_i[r];
                    s_q[r] <= $signed(requant_shift_vec_i[r]);
                end
            end

            // Metadata follows the 7-cycle requant pipeline.
            meta_valid[0] <= acc_valid_dbg;
            if(acc_valid_dbg) begin
                layer_pipe[0] <= acc_layer_id_dbg;
                pixel_pipe[0] <= acc_pixel_index_dbg;
                channel_pipe[0] <= acc_channel_base_dbg;
            end
            for(stage=1; stage<REQ_LAT; stage=stage+1) begin
                meta_valid[stage] <= meta_valid[stage-1];
                if(meta_valid[stage-1]) begin
                    layer_pipe[stage] <= layer_pipe[stage-1];
                    pixel_pipe[stage] <= pixel_pipe[stage-1];
                    channel_pipe[stage] <= channel_pipe[stage-1];
                end
            end

            // Final LUT output register.
            out_valid <= pre_valid_dbg;
            if (pre_valid_dbg) begin
                out_layer_id <= pre_layer_id_dbg;
                out_pixel_index <= pre_pixel_index_dbg;
                out_channel_base <= pre_channel_base_dbg;
                for (r=0; r<LANES; r=r+1)
                    out_data[r*8 +: 8] <= lut_code[r];
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && (req_valid !== meta_valid[REQ_LAT-1]))
            $fatal(1, "projection postproc metadata / data pipeline misalignment");
        if (rst_n && in_valid) begin
            if (^pre_scale_q_i === 1'bx || ^pre_scale_shift_i === 1'bx ||
                ^clamp_q_i === 1'bx || ^clamp_shift_i === 1'bx ||
                ^h_to_out_m_i === 1'bx || ^h_to_out_shift_i === 1'bx ||
                ^u_to_q20_m_i === 1'bx || ^u_to_q20_shift_i === 1'bx ||
                ^x_to_out_m_i === 1'bx || ^x_to_out_shift_i === 1'bx ||
                ^poly_coeff_i[0] === 1'bx)
                $fatal(1, "Projection PolySiLU profile contains X");
        end
    end
`endif
endmodule
