 module boothmultiplier16(
   input  signed [7:0]M,
   input         [7:0]Q,
    input                Qm1,
   output signed [15:0] result
);
   wire [1:0] sel [0:7];
   wire signed [15:0] partials [0:7];
    integer j;
   reg signed [15:0] sum;
    assign sel[0] = {Q[0], Qm1};
    genvar i;
    generate
      for (i = 1; i < 16; i = i + 1) begin : sel_gen
            assign sel[i] = {Q[i], Q[i-1]};
        end
    endgenerate
    generate
      for (i = 0; i < 16; i = i + 1) begin : partial_gen
            assign partials[i] = (sel[i] == 2'b01) ?  ($signed(M) <<< i) :
                                 (sel[i] == 2'b10) ? -($signed(M) <<< i) :
                                                     16'd0;
        end
    endgenerate
    always @(*) begin
        sum = 16'd0;
      for (j = 0; j < 8; j = j + 1) begin
            sum = sum + partials[j];
        end
    end
    assign result = sum;
endmodule
