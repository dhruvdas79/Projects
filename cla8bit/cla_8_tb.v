module cla_tb;
reg [7:0]a,b;
reg cin;
wire [7:0]s;
wire cout;

cla_8 uut(a,b,cin,s,cout);
initial begin
    $dumpfile("cla.vcd");
    $dumpvars(0,cla_tb);
     a=0;b=0;cin=0;
    #10 a=0;b=1;cin=1;
    #10 a=3;b=2;cin=0;
    #10 a=6;b=5;cin=1;
    #10 a=2;b=7;cin=0;
    #10 a=0;b=0;cin=0;
    #10 a=4;b=8;cin=1;
    #10 a=7;b=7;cin=1;
    $display("Test done");
    #10 $finish;
end
endmodule