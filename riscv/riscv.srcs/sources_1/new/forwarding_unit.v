module forwarding_unit(
    input [4:0] rd_exmem,
    input [4:0] rd_wbmem,
    input [4:0] Rs1,
    input [4:0] Rs2,
    input write_wb,write_rd,
    output reg [1:0] forward_A,
    output reg [1:0] forward_B
    );
    always @(*) begin
  forward_A = 2'b00;
  forward_B = 2'b00;
  if (write_rd && (rd_exmem != 0) && (rd_exmem == Rs1))
    forward_A = 2'b10;
  if (write_rd && (rd_exmem != 0) && (rd_exmem == Rs2))
    forward_B = 2'b10;
  if (write_wb && (rd_wbmem != 0) && (rd_wbmem == Rs1) 
      && !(write_rd && (rd_exmem != 0) && (rd_exmem == Rs1)))
    forward_A = 2'b01;
  if (write_wb && (rd_wbmem != 0) && (rd_wbmem == Rs2) 
      && !(write_rd && (rd_exmem != 0) && (rd_exmem == Rs2)))
    forward_B = 2'b01;
end
endmodule