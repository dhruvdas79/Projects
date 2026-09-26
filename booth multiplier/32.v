 module boothmultiplier32(
    input  signed [31:0] M,
    input         [31:0] Q,
    input                Qm1,
    output signed [63:0] result
);
    wire [1:0] sel [0:31];
    wire signed [63:0] partials [0:31];
    integer j;
    reg signed [63:0] sum;
    assign sel[0] = {Q[0], Qm1};
    genvar i;
    generate
        for (i = 1; i < 32; i = i + 1) begin : sel_gen
            assign sel[i] = {Q[i], Q[i-1]};
        end
    endgenerate
    generate
        for (i = 0; i < 32; i = i + 1) begin : partial_gen
            assign partials[i] = (sel[i] == 2'b01) ?  ($signed(M) <<< i) :
                                 (sel[i] == 2'b10) ? -($signed(M) <<< i) :
                                                     64'd0;
        end
    endgenerate
    always @(*) begin
        sum = 64'd0;
        for (j = 0; j < 32; j = j + 1) begin
            sum = sum + partials[j];
        end
    end
    assign result = sum;
endmodule
