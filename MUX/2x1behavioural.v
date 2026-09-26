module mux_2x1(
  input a,b,
  input sel,
  output reg out);
  
  always@(*)begin
    case(sel)
      1'b0:out=a;
      1'b1:out=b;
      default:out=1'bX;
    endcase
  end
endmodule