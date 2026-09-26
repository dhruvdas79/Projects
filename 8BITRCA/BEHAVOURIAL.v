module rca_8(
    input [7:0] a, b,
    input cin,
    output reg [7:0] s,
    output reg cout
);
    reg [7:0] carry; 
    always@(*) begin
    s[0] = a[0] ^ b[0] ^ cin;
      carry[0] = (a[0] & b[0]) | ((a[0] ^ b[0]) & cin);
        for(int i=1;i<8;i++)begin
            if (i<7) begin
                carry[i] = (a[i] & b[i]) | ((a[i] ^ b[i]) & carry[i-1]);
            end
                s[i] = a[i] ^ b[i] ^ carry[i-1];
            cout = (a[7] & b[7]) | ((a[7] ^ b[7]) & carry[6]);
        end
    end
 endmodule
