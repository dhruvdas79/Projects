 

module csa_tb;
  reg [31:0] a, b, c;
  wire [31:0] sum, carry;
  csa_structural uut(a, b, c, sum, carry);
  initial begin
    $dumpfile("csa_structural.vcd");
    $dumpvars(0, csa_structural_tb);
    a = 32'hA5A5A5A5;
    b = 32'h5A5A5A5A;
    c = 32'hFFFFFFFF;
    #10;
    a = 32'h00000000;
    b = 32'hFFFFFFFF;
    c = 32'h12345678;
    #10;
    $finish;
  end
endmodule