module comp_tb;
  reg [1:0]a,b;
   wire a_grt_b,a_less_b,eq;
  
  comp uut(a,b,a_grt_b,a_less_b,eq);
  
  initial begin 
    $dumpfile("comp.vcd");
    $dumpvars(0,comp_tb);
    
    for(int i=0;i<2;i=i+1)begin
      for(int j=0;j<2;j=j+1)begin
        for(int k=0;k<2;k=k+1)begin
          for(int l=0;l<2;l=l+1)begin
            a[1]=i;
            a[0]=j;
            b[1]=k;
            b[0]=l;
          #10;  
     	 end
        end
      end
    end
            $display("Done");
           #10 $finish; 
  end
endmodule