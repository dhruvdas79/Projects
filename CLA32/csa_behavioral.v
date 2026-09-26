module csa_behavioral(
  input [31:0] a,
  input [31:0] b,
  input [31:0] c,
  output reg [31:0] sum,
  output reg [31:0] carry
);
  always @(*) begin
    sum = a ^ b ^ c;
    carry = (a & b) | (b & c) | (a & c);
  end
endmodule