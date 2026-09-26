module comp(
  input [1:0] a,
  input [1:0] b,
  output a_grt_b,a_less_b,eq
);
  assign a_grt_b = (a[1]&~b[1])|(a[0]&~b[1]&~b[0])|(a[0]&a[1]&~b[0]);
  assign a_less_b = (~a[1]&~a[0]&b[0])|(~a[1]&b[1])|(~a[0]&b[1]&b[0]);
  assign eq = (a[1]~^b[1]) & (a[0]~^b[0]);
endmodule