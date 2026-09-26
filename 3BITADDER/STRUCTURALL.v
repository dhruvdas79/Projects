module fa_3( 
  input [2:0] a,b,
  input cin,
  output [2:0] s,
  output cout
);
   wire c1,c2,x1,x2,x3,x4,x5,x6,x7,x8,x9;

  xor m1(x1,a[0],b[0]);
  xor m2(s[0],x1,cin);
  and m3(x2,x1,cin);
  and m4(x3,a[0],b[0]);
  or  m5(c1,x2,x3);

  xor m6(x4,a[1],b[1]);
  xor m7(s[1],x4,c1);
  and m8(x5,x4,c1);
  and m9(x6,a[1],b[1]);
  or m10 (c2,x5,x6);

  xor m11(x7,a[2],b[2]);
  xor m12(s[2],x7,c2);
  and m13(x8,x7,c2);
  and m14 (x9,a[2],b[2]);
  or m15(cout,x8,x9);
endmodule