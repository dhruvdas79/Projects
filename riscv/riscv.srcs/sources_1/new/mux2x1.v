module mux2x1(
input [31:0]a,b,
input sel,
output c
    );
   assign c=sel?a:b;
endmodule
