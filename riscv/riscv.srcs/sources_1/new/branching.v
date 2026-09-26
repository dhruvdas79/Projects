 module branching(
    input        zero_alu,       
    input [31:0] result_alu,      
    input        branch,        
    input [2:0]  func3,          
    input [63:0] pc_branch,     
    input [63:0] imm_data,        
    output reg   branch_taken,
    output reg   flush_if,
    output reg   cond
);

    always @(*) begin
        branch_taken = 1'b0;
        flush_if     = 1'b0;

        if (branch) begin
            case (func3)
                3'b000: branch_taken = zero_alu;                  // BEQ
                3'b001: branch_taken = ~zero_alu;                 // BNE
                3'b100: branch_taken = (result_alu == 32'd1);     // BLT (signed SLT result)
                3'b101: branch_taken = (result_alu == 32'd0);     // BGE (signed)
                default: branch_taken = 1'b0;
            endcase
            flush_if = branch_taken;
            cond=branch_taken;
        end
        
    end
endmodule