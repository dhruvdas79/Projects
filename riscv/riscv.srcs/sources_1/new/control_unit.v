 module CU(
  input  [6:0] opcode,
  input        stall,
  output reg   branch,
  output reg   memread,
  output reg   memtoreg,
  output reg   memwrite,
  output reg   aluSrc,
  output reg   regwrite,
  output reg [1:0] Aluop
);
  always @(*) begin
    if (stall) begin
      aluSrc    = 1'b0;
      memtoreg  = 1'b0;
      regwrite  = 1'b0;
      memread   = 1'b0;
      memwrite  = 1'b0;
      branch    = 1'b0;
      Aluop     = 2'b00;
    end else begin
      case (opcode)
        7'b0000011: begin  //LOAD
          aluSrc    = 1'b1;
          memtoreg  = 1'b1;
          regwrite  = 1'b1;
          memread   = 1'b1;
          memwrite  = 1'b0;
          branch    = 1'b0;
          Aluop     = 2'b00;
        end
        7'b0100011: begin 
          aluSrc    = 1'b1;
          memtoreg  = 1'b0;
          regwrite  = 1'b0;
          memread   = 1'b0;//STORE
          memwrite  = 1'b1;
          branch    = 1'b0;
          Aluop     = 2'b00;
        end
        7'b0110011: begin 
          aluSrc    = 1'b0;
          memtoreg  = 1'b0;
          regwrite  = 1'b1;
          memread   = 1'b0;//R-type
          memwrite  = 1'b0;
          branch    = 1'b0;
          Aluop     = 2'b10;
        end
        7'b1100011: begin 
          aluSrc    = 1'b0;
          memtoreg  = 1'b0;//B-type
          regwrite  = 1'b0;
          memread   = 1'b0;
          memwrite  = 1'b0;
          branch    = 1'b1;
          Aluop     = 2'b01;
        end
        7'b0010011: begin 
          aluSrc    = 1'b1;
          memtoreg  = 1'b0;
          regwrite  = 1'b1;
          memread   = 1'b0;//I-type
          memwrite  = 1'b0;
          branch    = 1'b0;
          Aluop     = 2'b10; 
        end
        default: begin  
          aluSrc    = 1'b0;
          memtoreg  = 1'b0;
          regwrite  = 1'b0;
          memread   = 1'b0;
          memwrite  = 1'b0;
          branch    = 1'b0;
          Aluop     = 2'b00;
        end
      endcase
    end
  end
endmodule