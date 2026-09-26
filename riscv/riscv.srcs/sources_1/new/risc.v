 module pc_Adder(
  input clk,
  input rst,
  input [31:0] pc_in,
  output reg [31:0] pc_next
);

always @(posedge clk or posedge rst) begin
  if (rst) begin
    pc_next <= 0;          
  end else begin
    pc_next <= pc_in + 4;   
  end
end

endmodule