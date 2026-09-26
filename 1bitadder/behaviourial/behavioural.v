module fa(input a,b,cin,
          output reg cout,sum
         );
  always@(*) begin
    sum = a ^ b ^ cin;
    cout = (a & b) | (b & cin) | ( cin & a);
  end