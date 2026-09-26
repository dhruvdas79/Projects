module fa_3_tb;
  reg [2:0]a,b;
  reg cin;
  wire [2:0]s;
  wire cout;
  
  fa_3 uut(a,b,cin,s,cout);
  
  initial begin 
    $dumpfile("fa_3.vcd");
    $dumpvars(0,fa_3_tb);
    
    for(int i=0;i<8;i++)begin
      for(int j=0;j<8;j++)begin
        for(int k=0;k<2;k++)begin
            a=i;
            b=j;
          cin=k;
        #10;
     	 end
        end
    end
    $display("Test Done");
           #10 $finish; 
  end
endmodule