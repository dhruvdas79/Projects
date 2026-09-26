 module stall_unit(
    input        MemRead,          
    input  [4:0] Rd,           
    input  [31:0] instruction,     
    output reg   stall
);

always @(*) begin
    stall = 1'b0;
    if (MemRead && ((Rd == instruction[19:15]) || (Rd == instruction[24:20]))) begin
        stall = 1'b1;
    end
end
endmodule