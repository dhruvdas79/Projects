 module pc(
    input        clk,
    input        rst,
    input        stall,          // Stall signal
    input  [31:0] pc_inst,       // Next PC candidate
    output reg [31:0] pc_out     // Current PC
);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      pc_out <= 32'h00000000;   
    end else if (stall == 1'b0) begin
      pc_out <= pc_inst;         
    end else begin
      pc_out <= pc_out;          
    end
  end

endmodule