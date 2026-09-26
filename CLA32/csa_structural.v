module xor3_32bit(input [31:0] a, input [31:0] b, input [31:0] c, output [31:0] out);
  assign out = a ^ b ^ c;
endmodule

module carry3_32bit(input [31:0] a, input [31:0] b, input [31:0] c, output [31:0] out);
  assign out = (a & b) | (b & c) | (a & c);
endmodule

module csa_structural(
  input [31:0] a,
  input [31:0] b,
  input [31:0] c,
  output [31:0] sum,
  output [31:0] carry
);
  xor3_32bit u1(a, b, c, sum);
  carry3_32bit u2(a, b, c, carry);
endmodule