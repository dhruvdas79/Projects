module comp(
  input [1:0]a,b,
  output reg a_grt_b,a_less_b,eq
);
  always @(*)begin
    a_grt_b = (a[1]&~b[1])|(a[0]&~b[1]&~b[0])|(a[0]&a[1]&~b[0]);
 	a_less_b = (~a[1]&~a[0]&b[0])|(~a[1]&b[1])|(~a[0]&b[1]&b[0]);
 	eq = (a[1]~^b[1]) & (a[0]~^b[0]);
    
  end
endmodule