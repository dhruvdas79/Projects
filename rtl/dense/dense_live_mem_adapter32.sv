`timescale 1ns/1ps
// V6.2: packed synchronous ROM plus streaming source prefetch.
// The source request counter runs independently of the service token counter,
// allowing a fixed-latency synchronous source to return one vector per clock
// after pipeline fill. Weight rows use one-step lookahead for II=1 loading.
module dense_live_mem_adapter32 #(
  parameter int TOKENS=900,parameter int CIN=128,parameter int COUT=128,
  parameter int PE_K=32,parameter int PE_N=32,
  parameter int TOKEN_W=(TOKENS<=1)?1:$clog2(TOKENS),
  parameter int CI_W=((CIN/PE_K)<=1)?1:$clog2(CIN/PE_K),
  parameter int CO_W=((COUT/PE_N)<=1)?1:$clog2(COUT/PE_N),
  parameter int N_TILES=COUT/PE_N,
  parameter int ROM_DEPTH=CIN*N_TILES,
  parameter int ROM_AW=(ROM_DEPTH<=1)?1:$clog2(ROM_DEPTH),
  parameter [8*256-1:0] WEIGHT_MEM_FILE="dense_weight_i8_packed32.mem"
)(
  input logic clk,input logic rst_n,
  input logic stream_valid,input logic [TOKEN_W-1:0] stream_token,
  input logic [CI_W-1:0] active_ci_tile,input logic [CO_W-1:0] active_co_tile,
  input logic weight_row_load,input logic [$clog2(PE_K)-1:0] weight_row_index,
  output logic src_rd_en,output logic [TOKEN_W-1:0] src_rd_token,output logic [CI_W-1:0] src_rd_co_tile,
  input logic src_rd_valid,input logic signed [PE_K*8-1:0] src_rd_data,
  output logic input_vector_valid,output logic weight_row_valid,
  output logic signed [7:0] input_vector [0:PE_K-1],
  output logic signed [7:0] weight_row_values [0:PE_N-1]
);
  localparam int ISSUE_W=(TOKENS<=1)?1:$clog2(TOKENS+1);
  (* rom_style="block" *) logic [PE_N*8-1:0] weight_rom [0:ROM_DEPTH-1];
  logic [PE_N*8-1:0] weight_word_q;
  logic weight_armed;
  logic [ROM_AW-1:0] last_weight_addr;
  logic [ISSUE_W-1:0] issued_q;
  logic [TOKEN_W-1:0] issue_token_q;
  logic [$clog2(PE_K)-1:0] weight_req_row;
  logic [ROM_AW-1:0] weight_addr;
  logic accept_weight;

  initial $readmemh(WEIGHT_MEM_FILE,weight_rom);

  always_comb begin
    src_rd_en=stream_valid && (issued_q<TOKENS);
    src_rd_token=issue_token_q;
    src_rd_co_tile=active_ci_tile;
    input_vector_valid=stream_valid&&src_rd_valid;
    for(int lane=0;lane<PE_K;lane=lane+1)
      input_vector[lane]=input_vector_valid?src_rd_data[lane*8+:8]:'0;
    for(int lane=0;lane<PE_N;lane=lane+1)
      weight_row_values[lane]=weight_row_valid?weight_word_q[lane*8+:8]:'0;

    // While row N is being consumed, request row N+1 at the same edge.
    if(weight_row_valid && (weight_row_index<PE_K-1)) weight_req_row=weight_row_index+1'b1;
    else weight_req_row=weight_row_index;
    weight_addr=ROM_AW'((($unsigned(active_ci_tile)*PE_K)+$unsigned(weight_req_row))*N_TILES+$unsigned(active_co_tile));
    accept_weight=weight_row_load&&(!weight_armed||(weight_addr!=last_weight_addr));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      weight_row_valid<=1'b0;weight_word_q<='0;weight_armed<=1'b0;last_weight_addr<='0;
      issued_q<='0;issue_token_q<='0;
    end else begin
      if(!stream_valid) begin issued_q<='0;issue_token_q<='0;end
      else if(src_rd_en) begin
        issued_q<=issued_q+1'b1;
        if(issue_token_q<TOKENS-1)issue_token_q<=issue_token_q+1'b1;
      end

      weight_row_valid<=accept_weight;
      if(!weight_row_load)weight_armed<=1'b0;
      else if(accept_weight)begin
        weight_armed<=1'b1;last_weight_addr<=weight_addr;weight_word_q<=weight_rom[weight_addr];
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(rst_n&&input_vector_valid&&(stream_token>=TOKENS))$fatal(1,"dense source token out of range");
    if(rst_n&&stream_valid&&src_rd_valid&&(stream_token>=issued_q))$fatal(1,"dense prefetch response outran issue count");
  end
`endif
endmodule
