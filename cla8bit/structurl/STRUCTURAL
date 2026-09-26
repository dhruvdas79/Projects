module cla_4(
   input [3:0] a,b,
   input cin, 
   output [3:0] s, 
   output cout
   );
  wire [3:0] p,g;
  wire [4:0] c;
  assign p=a^b;
  assign g=a&b;
  assign c[0]=cin;
  assign c[1] = g[0] | (p[0] & c[0]);
  assign c[2] = g[1] | (p[1] & g[0]) | (p[1] & p[0] & c[0]);
  assign c[3] = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) | (p[2] & p[1] &  p[0] & c[0]);
  assign c[4] = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) | (p[3] & p[2] & p[1] & g[0]) | (p[3] & p[2] & p[1] & p[0] & c[0]);
  
  assign s=p^c[3:0];
  assign cout=c[4];
endmodule;
module cla_8(
  input [7:0] a,b,
  input cin, 
  output [7:0] s, 
  output cout
  );
  wire [1:0] c;
  cla_4 cla1(.a(a[3:0]),.b(b[3:0]),.cin(cin),.s(s[3:0]),.cout(c[0]));
  cla_4 cla2(.a(a[7:4]),.b(b[7:4]),.cin(c[0]),.s(s[7:4]),.cout(c[1]));
  assign cout=c[1];
endmodule