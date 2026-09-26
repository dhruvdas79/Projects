module rca_8(
    input [7:0] a, b,
    input cin,
    output [7:0] s,
    output cout
);
    wire [7:0]c;
    genvar i;
    generate 
        for( i=0;i<8;i++)begin
            if(i==0) begin
            assign s[i] = (a[i] ^ b[i]) ^ cin ;
            assign c[i] = (a[i] & b[i]) | ((a[i] ^ b[i]) & cin );
        end
            else begin
                assign s[i] = (a[i] ^ b[i]) ^ c[i-1] ;
                assign c[i] = (a[i] & b[i]) | ((a[i] ^ b[i]) & c[i-1] );   
            end
        end
            endgenerate
        assign cout = c[7];
endmodule
