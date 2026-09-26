`timescale 1ns / 1ps

module top_systolic_wrapper (
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,
    output reg  pass,
    output reg [3:0] debug
);

    // ------------------------------------------------------------
    // Internal control signals for your existing accelerator
    // ------------------------------------------------------------
    reg        wr_en_a;
    reg [1:0]  wr_col_a;
    reg [31:0] wr_data_a;
    reg        rd_en_a;
    reg [1:0]  rd_col_a;

    reg        wr_en_b;
    reg [1:0]  wr_row_b;
    reg [31:0] wr_data_b;
    reg        rd_en_b;
    reg [1:0]  rd_row_b;

    wire signed [31:0] c00,c01,c02,c03;
    wire signed [31:0] c10,c11,c12,c13;
    wire signed [31:0] c20,c21,c22,c23;
    wire signed [31:0] c30,c31,c32,c33;

    // ------------------------------------------------------------
    // Instantiate your verified systolic accelerator
    // ------------------------------------------------------------
    top_systolic_accelerator DUT (
        .clk(clk),
        .rst(rst),

        .wr_en_a(wr_en_a),
        .wr_col_a(wr_col_a),
        .wr_data_a(wr_data_a),
        .rd_en_a(rd_en_a),
        .rd_col_a(rd_col_a),

        .wr_en_b(wr_en_b),
        .wr_row_b(wr_row_b),
        .wr_data_b(wr_data_b),
        .rd_en_b(rd_en_b),
        .rd_row_b(rd_row_b),

        .c00(c00), .c01(c01), .c02(c02), .c03(c03),
        .c10(c10), .c11(c11), .c12(c12), .c13(c13),
        .c20(c20), .c21(c21), .c22(c22), .c23(c23),
        .c30(c30), .c31(c31), .c32(c32), .c33(c33)
    );

    // ------------------------------------------------------------
    // FSM states
    // ------------------------------------------------------------
    localparam IDLE   = 3'd0;
    localparam LOAD_A = 3'd1;
    localparam LOAD_B = 3'd2;
    localparam RUN    = 3'd3;
    localparam WAIT   = 3'd4;
    localparam CHECK  = 3'd5;
    localparam DONE_S = 3'd6;

    reg [2:0] state;
    reg [3:0] count;

    // ------------------------------------------------------------
    // Simple internal test:
    // A = Identity
    // B = Identity
    // Expected C = Identity
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            count     <= 0;

            wr_en_a   <= 0;
            wr_col_a  <= 0;
            wr_data_a <= 0;
            rd_en_a   <= 0;
            rd_col_a  <= 0;

            wr_en_b   <= 0;
            wr_row_b  <= 0;
            wr_data_b <= 0;
            rd_en_b   <= 0;
            rd_row_b  <= 0;

            done      <= 0;
            pass      <= 0;
            debug     <= 0;
        end else begin

            // default values
            wr_en_a <= 0;
            wr_en_b <= 0;
            rd_en_a <= 0;
            rd_en_b <= 0;

            case (state)

                IDLE: begin
                    done  <= 0;
                    pass  <= 0;
                    debug <= 4'd0;
                    count <= 0;

                    if (start) begin
                        state <= LOAD_A;
                    end
                end

                // ------------------------------------------------
                // Load matrix A column-wise
                // A = identity
                //
                // wr_data_a = {A[3][col], A[2][col], A[1][col], A[0][col]}
                // ------------------------------------------------
                LOAD_A: begin
                    wr_en_a  <= 1;
                    wr_col_a <= count[1:0];

                    case (count)
                        4'd0: wr_data_a <= {8'd0, 8'd0, 8'd0, 8'd1};
                        4'd1: wr_data_a <= {8'd0, 8'd0, 8'd1, 8'd0};
                        4'd2: wr_data_a <= {8'd0, 8'd1, 8'd0, 8'd0};
                        4'd3: wr_data_a <= {8'd1, 8'd0, 8'd0, 8'd0};
                        default: wr_data_a <= 32'd0;
                    endcase

                    if (count == 4'd3) begin
                        count <= 0;
                        state <= LOAD_B;
                    end else begin
                        count <= count + 1;
                    end
                end

                // ------------------------------------------------
                // Load matrix B row-wise
                // B = identity
                //
                // wr_data_b = {B[row][3], B[row][2], B[row][1], B[row][0]}
                // ------------------------------------------------
                LOAD_B: begin
                    wr_en_b  <= 1;
                    wr_row_b <= count[1:0];

                    case (count)
                        4'd0: wr_data_b <= {8'd0, 8'd0, 8'd0, 8'd1};
                        4'd1: wr_data_b <= {8'd0, 8'd0, 8'd1, 8'd0};
                        4'd2: wr_data_b <= {8'd0, 8'd1, 8'd0, 8'd0};
                        4'd3: wr_data_b <= {8'd1, 8'd0, 8'd0, 8'd0};
                        default: wr_data_b <= 32'd0;
                    endcase

                    if (count == 4'd3) begin
                        count <= 0;
                        state <= RUN;
                    end else begin
                        count <= count + 1;
                    end
                end

                // ------------------------------------------------
                // Feed A columns and B rows into array
                // ------------------------------------------------
                RUN: begin
                    rd_en_a  <= 1;
                    rd_en_b  <= 1;
                    rd_col_a <= count[1:0];
                    rd_row_b <= count[1:0];

                    if (count == 4'd3) begin
                        count <= 0;
                        state <= WAIT;
                    end else begin
                        count <= count + 1;
                    end
                end

                // wait for systolic pipeline to finish
                WAIT: begin
                    if (count == 4'd14) begin
                        count <= 0;
                        state <= CHECK;
                    end else begin
                        count <= count + 1;
                    end
                end

                // ------------------------------------------------
                // Check identity result
                // Expected:
                // c00,c11,c22,c33 = 1
                // others = 0
                // ------------------------------------------------
                CHECK: begin
                    if (
                        c00 == 32'sd1 && c01 == 32'sd0 && c02 == 32'sd0 && c03 == 32'sd0 &&
                        c10 == 32'sd0 && c11 == 32'sd1 && c12 == 32'sd0 && c13 == 32'sd0 &&
                        c20 == 32'sd0 && c21 == 32'sd0 && c22 == 32'sd1 && c23 == 32'sd0 &&
                        c30 == 32'sd0 && c31 == 32'sd0 && c32 == 32'sd0 && c33 == 32'sd1
                    ) begin
                        pass <= 1;
                        debug <= 4'hA;
                    end else begin
                        pass <= 0;
                        debug <= 4'hF;
                    end

                    state <= DONE_S;
                end

                DONE_S: begin
                    done <= 1;
                    state <= DONE_S;
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule