// ============================================================================
// ws16x16_weight_stationary_core.sv
// True 16x16 weight-stationary systolic GEMM tile.
//
// Input skew:
//   - row r activation is delayed by r cycles before column 0.
//   - column c top psum token is delayed by c cycles before row 0.
//
// Bottom outputs therefore leave column c c cycles later than column 0.
// The final reverse output deskew delays lane c by (PE_N-1-c) cycles, so this
// module emits one *aligned* vector: all PE_N lanes have the same pixel tag on
// every out_valid beat. This is required by a vector psum BRAM and 16-lane
// postprocess block.
// ============================================================================
module ws16x16_weight_stationary_core #(
    parameter int DATA_W   = 8,
    parameter int ACC_W    = 64,
    parameter int PE_K     = 16,
    parameter int PE_N     = 16,
    parameter int PIX_ID_W = 12
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         pipe_flush,

    input  logic                         weight_row_load,
    input  logic [$clog2(PE_K)-1:0]      weight_row_index,
    input  logic signed [DATA_W-1:0]     weight_row_values [0:PE_N-1],

    input  logic                         input_valid,
    input  logic [PIX_ID_W-1:0]          input_pixel_id,
    input  logic signed [DATA_W-1:0]     input_vector [0:PE_K-1],

    output logic                         out_valid [0:PE_N-1],
    output logic [PIX_ID_W-1:0]          out_pixel_id [0:PE_N-1],
    output logic signed [ACC_W-1:0]      out_psum [0:PE_N-1]
);

    localparam int ALIGN_STAGES = (PE_N <= 1) ? 1 : (PE_N - 1);

    // For PE_K/PE_N=16 these arrays implement the 0..15 input/top delays.
    logic signed [DATA_W-1:0] act_skew_data  [0:PE_K-1][0:PE_K-2];
    logic                     act_skew_valid [0:PE_K-1][0:PE_K-2];
    logic [PIX_ID_W-1:0]      act_skew_tag   [0:PE_K-1][0:PE_K-2];

    logic                     top_skew_valid [0:PE_N-1][0:PE_N-2];
    logic [PIX_ID_W-1:0]      top_skew_tag   [0:PE_N-1][0:PE_N-2];

    logic                     act_valid_grid [0:PE_K-1][0:PE_N-1];
    logic [PIX_ID_W-1:0]      act_tag_grid   [0:PE_K-1][0:PE_N-1];
    logic signed [DATA_W-1:0] act_data_grid  [0:PE_K-1][0:PE_N-1];

    logic                     psum_valid_grid[0:PE_K-1][0:PE_N-1];
    logic [PIX_ID_W-1:0]      psum_tag_grid  [0:PE_K-1][0:PE_N-1];
    logic signed [ACC_W-1:0]  psum_data_grid [0:PE_K-1][0:PE_N-1];

    logic                     firstcol_act_valid [0:PE_K-1];
    logic [PIX_ID_W-1:0]      firstcol_act_tag   [0:PE_K-1];
    logic signed [DATA_W-1:0] firstcol_act_data  [0:PE_K-1];

    logic                     top_psum_valid [0:PE_N-1];
    logic [PIX_ID_W-1:0]      top_psum_tag   [0:PE_N-1];

    // Reverse output deskew. Only lanes 0..PE_N-2 use this storage; the last
    // lane is the latest naturally and is passed through directly.
    logic                     out_deskew_valid [0:PE_N-1][0:ALIGN_STAGES-1];
    logic [PIX_ID_W-1:0]      out_deskew_tag   [0:PE_N-1][0:ALIGN_STAGES-1];
    logic signed [ACC_W-1:0]  out_deskew_data  [0:PE_N-1][0:ALIGN_STAGES-1];

    assign firstcol_act_valid[0] = input_valid;
    assign firstcol_act_tag[0]   = input_pixel_id;
    assign firstcol_act_data[0]  = input_vector[0];

    assign top_psum_valid[0] = input_valid;
    assign top_psum_tag[0]   = input_pixel_id;

    genvar gr;
    generate
        for (gr=1; gr<PE_K; gr=gr+1) begin : G_ACT_SKEW_OUT
            assign firstcol_act_valid[gr] = act_skew_valid[gr][gr-1];
            assign firstcol_act_tag[gr]   = act_skew_tag[gr][gr-1];
            assign firstcol_act_data[gr]  = act_skew_data[gr][gr-1];
        end
    endgenerate

    genvar gc;
    generate
        for (gc=1; gc<PE_N; gc=gc+1) begin : G_PSUM_SKEW_OUT
            assign top_psum_valid[gc] = top_skew_valid[gc][gc-1];
            assign top_psum_tag[gc]   = top_skew_tag[gc][gc-1];
        end
    endgenerate

    integer r, c, d;
    always_ff @(posedge clk) begin
        if (!rst_n || pipe_flush) begin
            for (r=0; r<PE_K; r=r+1) begin
                for (d=0; d<PE_K-1; d=d+1) begin
                    act_skew_data[r][d]  <= '0;
                    act_skew_valid[r][d] <= 1'b0;
                    act_skew_tag[r][d]   <= '0;
                end
            end
            for (c=0; c<PE_N; c=c+1) begin
                for (d=0; d<PE_N-1; d=d+1) begin
                    top_skew_valid[c][d] <= 1'b0;
                    top_skew_tag[c][d]   <= '0;
                end
                for (d=0; d<ALIGN_STAGES; d=d+1) begin
                    out_deskew_valid[c][d] <= 1'b0;
                    out_deskew_tag[c][d]   <= '0;
                    out_deskew_data[c][d]  <= '0;
                end
            end
        end else begin
            // Input activation skew.
            for (r=1; r<PE_K; r=r+1) begin
                act_skew_data[r][0]  <= input_vector[r];
                act_skew_valid[r][0] <= input_valid;
                act_skew_tag[r][0]   <= input_pixel_id;
                for (d=1; d<PE_K-1; d=d+1) begin
                    if (d < r) begin
                        act_skew_data[r][d]  <= act_skew_data[r][d-1];
                        act_skew_valid[r][d] <= act_skew_valid[r][d-1];
                        act_skew_tag[r][d]   <= act_skew_tag[r][d-1];
                    end
                end
            end

            // Top-edge psum-token skew.
            for (c=1; c<PE_N; c=c+1) begin
                top_skew_valid[c][0] <= input_valid;
                top_skew_tag[c][0]   <= input_pixel_id;
                for (d=1; d<PE_N-1; d=d+1) begin
                    if (d < c) begin
                        top_skew_valid[c][d] <= top_skew_valid[c][d-1];
                        top_skew_tag[c][d]   <= top_skew_tag[c][d-1];
                    end
                end
            end

            // Reverse-deskew the bottom-of-array outputs. Bottom lane c has
            // pixel tag p at c cycles later than lane 0; delay lane c by
            // PE_N-1-c so every lane emits the same p together.
            for (c=0; c<PE_N-1; c=c+1) begin
                out_deskew_valid[c][0] <= psum_valid_grid[PE_K-1][c];
                out_deskew_tag[c][0]   <= psum_tag_grid[PE_K-1][c];
                out_deskew_data[c][0]  <= psum_data_grid[PE_K-1][c];
                for (d=1; d<ALIGN_STAGES; d=d+1) begin
                    if (d < (PE_N-1-c)) begin
                        out_deskew_valid[c][d] <= out_deskew_valid[c][d-1];
                        out_deskew_tag[c][d]   <= out_deskew_tag[c][d-1];
                        out_deskew_data[c][d]  <= out_deskew_data[c][d-1];
                    end else begin
                        out_deskew_valid[c][d] <= 1'b0;
                        out_deskew_tag[c][d]   <= '0;
                        out_deskew_data[c][d]  <= '0;
                    end
                end
            end
        end
    end

    genvar rk, cn;
    generate
        for (rk=0; rk<PE_K; rk=rk+1) begin : G_ROW
            for (cn=0; cn<PE_N; cn=cn+1) begin : G_COL
                if (rk==0 && cn==0) begin : G_00
                    ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W)) u_pe (
                        .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
                        .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
                        .act_valid_in(firstcol_act_valid[rk]),.act_tag_in(firstcol_act_tag[rk]),.act_in(firstcol_act_data[rk]),
                        .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
                        .psum_valid_in(top_psum_valid[cn]),.psum_tag_in(top_psum_tag[cn]),.psum_in('0),
                        .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
                    );
                end else if (cn==0) begin : G_LEFT
                    ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W)) u_pe (
                        .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
                        .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
                        .act_valid_in(firstcol_act_valid[rk]),.act_tag_in(firstcol_act_tag[rk]),.act_in(firstcol_act_data[rk]),
                        .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
                        .psum_valid_in(psum_valid_grid[rk-1][cn]),.psum_tag_in(psum_tag_grid[rk-1][cn]),.psum_in(psum_data_grid[rk-1][cn]),
                        .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
                    );
                end else if (rk==0) begin : G_TOP
                    ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W)) u_pe (
                        .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
                        .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
                        .act_valid_in(act_valid_grid[rk][cn-1]),.act_tag_in(act_tag_grid[rk][cn-1]),.act_in(act_data_grid[rk][cn-1]),
                        .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
                        .psum_valid_in(top_psum_valid[cn]),.psum_tag_in(top_psum_tag[cn]),.psum_in('0),
                        .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
                    );
                end else begin : G_MID
                    ws_systolic_pe #(.DATA_W(DATA_W),.ACC_W(ACC_W),.PIX_ID_W(PIX_ID_W)) u_pe (
                        .clk(clk),.rst_n(rst_n),.pipe_flush(pipe_flush),
                        .weight_load(weight_row_load && (weight_row_index==rk)),.weight_in(weight_row_values[cn]),
                        .act_valid_in(act_valid_grid[rk][cn-1]),.act_tag_in(act_tag_grid[rk][cn-1]),.act_in(act_data_grid[rk][cn-1]),
                        .act_valid_out(act_valid_grid[rk][cn]),.act_tag_out(act_tag_grid[rk][cn]),.act_out(act_data_grid[rk][cn]),
                        .psum_valid_in(psum_valid_grid[rk-1][cn]),.psum_tag_in(psum_tag_grid[rk-1][cn]),.psum_in(psum_data_grid[rk-1][cn]),
                        .psum_valid_out(psum_valid_grid[rk][cn]),.psum_tag_out(psum_tag_grid[rk][cn]),.psum_out(psum_data_grid[rk][cn])
                    );
                end
            end
        end
    endgenerate

    genvar oc;
    generate
        for (oc=0; oc<PE_N; oc=oc+1) begin : G_OUT
            if (oc == PE_N-1) begin : G_LAST_DIRECT
                assign out_valid[oc]    = psum_valid_grid[PE_K-1][oc];
                assign out_pixel_id[oc] = psum_tag_grid[PE_K-1][oc];
                assign out_psum[oc]     = psum_data_grid[PE_K-1][oc];
            end else begin : G_REVERSE_DESKEW
                localparam int DELAY = PE_N - 1 - oc;
                assign out_valid[oc]    = out_deskew_valid[oc][DELAY-1];
                assign out_pixel_id[oc] = out_deskew_tag[oc][DELAY-1];
                assign out_psum[oc]     = out_deskew_data[oc][DELAY-1];
            end
        end
    endgenerate

endmodule
