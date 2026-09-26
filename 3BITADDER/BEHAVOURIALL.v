module fa_3( 
  input [2:0] a,b,
  input cin,
  output reg [2:0] s,
  output reg cout
);
   reg c1,c2;
  always @(*)begin 
   
    s[0] = a[0]^b[0]^cin;
    c1 = ((a[0]^b[0])&cin) | (a[0]&b[0]);
    
    s[1] = a[1]^b[1]^c1;
    c2 = ((a[1]^b[1])&c1) | (a[1]&b[1]);
    
    s[2] = a[2]^b[2]^c2;
    cout = ((a[2]^b[2])&c2) | (a[2]&b[2]);
  end
endmodule