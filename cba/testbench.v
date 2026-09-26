module cba_32_tb;
  reg [31:0]a,b;
reg cin;
  wire [31:0]s;
wire cout;

cba_32 dut(a,b,cin,s,cout);
initial begin
    $dumpfile("cba.vcd");
  $dumpvars(0,cba_32_tb);
    a=0;b=0;cin=0;
    #10 a=0;b=1;cin=1;
    #10 a=33456865;b=255664433;cin=0;
    #10 a=42356436;b=56754564;cin=1;
    #10 a=22142132;b=7454565;cin=0;
    #10 a=0;b=0;cin=0;
    #10 a=4;b=8;cin=1;
    #10 a=32'hFFFF_FFFF;b=32'hFFFF_FFFF;cin=1;
    $display("Test done");
    #10 $finish;
end
endmodule