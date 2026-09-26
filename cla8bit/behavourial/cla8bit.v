module cla_4(
   input [3:0] a,b,
   input cin, 
   output [3:0] s, 
   output cout
   );
   always@(*)begin
  reg [3:0] p,g;
  reg [4:0] c;
   p=a^b;
   g=a&b;
   c[0]=cin;
   c[1] = g[0] | (p[0] & c[0]);
   c[2] = g[1] | (p[1] & g[0]) | (p[1] & p[0] & c[0]);
   c[3] = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) | (p[2] & p[1] &  p[0] & c[0]);
   c[4] = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) | (p[3] & p[2] & p[1] & g[0]) | (p[3] & p[2] & p[1] & p[0] & c[0]);
  
   s=p^c[3:0];
   cout=c[4];
   end
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
   always@(*) begin
  cout=c[1];
   end
endmodule