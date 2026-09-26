 module fa_tb;
   wire cout,sum;
   reg a,b,cin;
   fa uut(
     .a(a),
     .b(b),
     .cin(cin),
     .cout(cout),
     .sum(sum)
   );
   initial begin
     $dumpfile("fa.vcd");
     $dumpvars;
   end
   initial begin
       a=0; b=0; cin=0; #10;
     a=0; b=0; cin=1; #10;
     a=0; b=1; cin=0; #10;
     a=0; b=1; cin=1; #10;
     a=1; b=0; cin=0; #10;
     a=1; b=0; cin=1; #10;
     a=1; b=1; cin=0; #10;
     a=1; b=1; cin=1; #10;
     $finish;
   end
   initial begin
     $monitor("time=%g,a=%b,b=%b,cin=&b,cout=%b,sum=%sum",$time,a,b,cin,cout,sum);
   end
 endmodule