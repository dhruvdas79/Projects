module rca_8_tb;
  reg [7:0]a,b;
  reg cin;
  wire [7:0]s;
  wire cout;
  
  rca_8 uut(a,b,cin,s,cout);
  
  initial begin 
    $dumpfile("rca_8.vcd");
    $dumpvars(0,rca_8_tb);
    a=0;b=0;cin=0;
    #10 a[0]=0;b[5]=0;cin=0;
    #10 a[4]=1;b[7]=0;cin=0;
    #10 a[6]=1;b[1]=0;cin=1;
    #10 a[3]=0;b[2]=1;cin=0;
    #10 a[2]=0;b[6]=1;cin=1;
    #10 a[7]=1;b[3]=1;cin=0;
    #10 a[1]=0;b[0]=0;cin=0;
    #10 a[5]=1;b[4]=1;cin=1;
    
    $display("Test Done");
           #10 $finish; 
  end
endmodule