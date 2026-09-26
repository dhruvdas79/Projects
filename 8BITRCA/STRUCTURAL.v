module rca_8(
    input [7:0] a, b,
    input cin,
    output [7:0] s,
    output cout
);
   wire c1, c2, c3, c4, c5, c6, c7;  
   wire x1,x2,x3,x4,x5,x6,x7,x8,x9,x10,x11,x12,x13,x14,x15,x16,x17,x18,x19,x20,x21,x22,x23,x24;
  
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
  or m15(c3,x8,x9);

  xor m16(x10,a[3],b[3]);
  xor m17(s[3],x10,c3);
  and m18(x11,x10,c3);
  and m19(x12,a[3],b[3]);
  or m20 (c4,x11,x12);

  xor m21(x13,a[4],b[4]);
  xor m22(s[4],x13,c4);
  and m23(x14,x13,c4);
  and m24(x15,a[4],b[4]);
  or m25 (c5,x14,x15);

  xor m26(x16,a[5],b[5]);
  xor m27(s[5],x16,c5);
  and m28(x17,x16,c5);
  and m29(x18,a[5],b[5]);
  or m30 (c6,x17,x18);

  xor m31(x19,a[6],b[6]);
  xor m32(s[6],x19,c6);
  and m33(x20,x19,c6);
  and m34(x21,a[6],b[6]);
  or m35 (c7,x20,x21);

  xor m36(x22,a[7],b[7]);
  xor m37(s[7],x22,c7);
  and m38(x23,x22,c7);
  and m39(x24,a[7],b[7]);
  or m40 (cout,x23,x24);

endmodule