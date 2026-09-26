module data_mem(
input memwrite,
input memread,
input [5:0]address,
input clk,
input rst,
input [63:0] w_data,
output reg [63:0] r_data
    );
    reg [7:0] mem [0:63];
    integer i;
    initial
    begin
    for(i=0;i<63;i=i+1)begin
        mem[i]=0;
    end
    end
    always@(posedge clk) begin
         if(memwrite)begin
            mem[address+0]<=w_data[7:0];
             mem[address+1]<=w_data[15:8];
             mem[address+2]<=w_data[23:16];
             mem[address+3]<=w_data[31:24];
             mem[address+4]<=w_data[39:32];
             mem[address+5]<=w_data[47:40];
             mem[address+6]<=w_data[55:48];
             mem[address+7]<=w_data[63:56];
            end
          else if(memread)begin
                r_data[7:0]<=mem[address+0];
                r_data[15:8]<=mem[address+1];
                r_data[23:16]<=mem[address+2];
                r_data[31:24]<=mem[address+3];
                r_data[39:32]<=mem[address+4];
                r_data[47:40]<=mem[address+5];
                r_data[55:48]<=mem[address+6];
                r_data[63:56]<=mem[address+7];
                end
                end
                
endmodule
