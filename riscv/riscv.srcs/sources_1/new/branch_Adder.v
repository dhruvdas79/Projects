module branch_Adder(
input cond,
input [63:0] pc_ex,
input [63:0]imm_data,
output  pc_next
    );
  assign  pc_next=pc_ex+imm_data;
endmodule
