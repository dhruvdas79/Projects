`timescale 1ns/1ps
// Runtime window-attention client with BRAM-friendly local storage interfaces.
// Q/K/V are supplied through synchronous request/response ports. Logits and
// probabilities are stored as one 256-bit row per {head,query}, and context is
// streamed directly to the caller instead of being retained in a 3-D register
// array. The shared MAC service supplies backpressure while BRAM reads fill.
(* use_dsp="no" *)
module swin_runtime_attention_client #(
  parameter int LANES=32,
  parameter int MAX_HEADS=4,
  parameter int MAX_TOKENS=25,
  parameter int MAX_CHUNKS=2
)(
  input logic clk,input logic rst_n,input logic start,
  input logic [2:0] block_id,
  input logic [2:0] cfg_heads,
  input logic [5:0] cfg_tokens,
  input logic [1:0] cfg_chunks,
  input logic signed [31:0] cfg_qk_m,input logic [5:0] cfg_qk_shift,
  input logic signed [31:0] cfg_ctx_m,input logic [5:0] cfg_ctx_shift,

  output logic q_rd_en,output logic [4:0] q_rd_token,output logic [1:0] q_rd_co,
  input logic q_rd_valid,input logic signed [255:0] q_rd_data,
  output logic k_rd_en,output logic [1:0] k_rd_co,output logic [4:0] k_rd_row,
  input logic k_rd_valid,input logic signed [255:0] k_rd_data,
  output logic v_rd_en,output logic [4:0] v_rd_token,output logic [1:0] v_rd_co,
  input logic v_rd_valid,input logic signed [255:0] v_rd_data,

  output logic busy,output logic done,
  output logic ctx_valid,output logic [4:0] ctx_token,output logic [1:0] ctx_co_tile,
  output logic signed [255:0] ctx_data,

  output logic relpos_req_valid,output logic [2:0] relpos_req_block,
  output logic [2:0] relpos_req_head,output logic [4:0] relpos_req_query,
  input logic relpos_resp_valid,input logic signed [15:0] relpos_resp_bias[0:31],
  output logic exp_req_valid,output logic [2:0] exp_req_block,
  output logic signed [7:0] exp_req_delta[0:31],input logic exp_resp_valid,
  input logic [15:0] exp_resp_value[0:31],

  output logic client_req,input logic client_grant,
  output logic [11:0] client_cfg_tokens_m1,output logic [3:0] client_cfg_k_tiles_m1,
  output logic [3:0] client_cfg_n_tiles_m1,output logic client_input_valid,
  output logic client_weight_valid,output logic signed [8:0] client_input_vector[0:31],
  output logic signed [8:0] client_weight_row_values[0:31],
  input logic svc_stream_valid,input logic [11:0] svc_stream_token_id,
  input logic [3:0] svc_active_ci_tile,input logic [3:0] svc_active_co_tile,
  input logic svc_weight_row_load,input logic [4:0] svc_weight_row_index,
  input logic svc_done,input logic svc_raw_valid,input logic [11:0] svc_raw_token_id,
  input logic [3:0] svc_raw_co_tile,input logic signed [63:0] svc_raw_acc[0:31]
);
  import fixedpoint_pkg::*;

  localparam int ROWS = MAX_HEADS*MAX_TOKENS;
  localparam int ROW_AW = (ROWS<=2) ? 1 : $clog2(ROWS);

  typedef enum logic [4:0] {
    A_IDLE,A_QK_REQ,A_QK_RUN,A_QK_DRAIN,
    A_SM_ROW_REQ,A_SM_ROW_WAIT,A_SM_MAX,A_SM_EXP_REQ,A_SM_EXP_WAIT,
    A_SM_SUM,A_SM_DIV_INIT,A_SM_DIV_ITER,A_SM_PROB_WRITE,
    A_PV_REQ,A_PV_RUN,A_PV_DRAIN,A_DONE
  } ast_t;
  ast_t st_q;

  logic [2:0] block_q,heads_q,head_q,sm_head_q;
  logic [5:0] tokens_q;
  logic [1:0] chunks_q;
  logic signed [31:0] qk_m_q,ctx_m_q;
  logic [5:0] qk_shift_q,ctx_shift_q;

  (* ram_style="distributed", rw_addr_collision="no" *)
  logic signed [255:0] logits_mem[0:ROWS-1];
  (* ram_style="distributed", rw_addr_collision="no" *)
  logic [255:0] probs_mem[0:ROWS-1];

  logic [15:0] exp_cache[0:31];
  logic signed [255:0] soft_logits_q;
  logic [255:0] prob_row_q;
  logic [4:0] sm_query_q,sm_key_q;
  logic signed [7:0] soft_max_q;
  logic [31:0] soft_denom_q;
  // Two quotient bits are resolved per cycle. Legal MAX_TOKENS<=32 bounds
  // keep the rounded work value and denom<<7 trial inside 32 bits.
  logic [31:0] div_work_q,div_trial_q;
  logic [7:0] div_quot_q;
  logic [2:0] div_bit_q;
  logic [11:0] qk_resp_count_q,pv_resp_count_q;
  logic [11:0] qk_expected,pv_expected;

  logic qk_pipe_valid_q;
  logic [4:0] qk_pipe_query_q;
  logic [2:0] qk_pipe_head_q;
  logic signed [63:0] qk_pipe_acc_q[0:31];

  logic qk_logit_wr_en;
  logic [ROW_AW-1:0] qk_logit_wr_addr;
  logic logit_rd_en,logit_rd_valid_q;
  logic [ROW_AW-1:0] logit_rd_addr;
  logic signed [255:0] logit_rd_data_q;
  logic prob_wr_en;
  logic [ROW_AW-1:0] prob_wr_addr;
  logic prob_rd_en,prob_rd_valid_q;
  logic [ROW_AW-1:0] prob_rd_addr;
  logic [255:0] prob_rd_data_q;
  logic mode_pv;
  logic pv_v_zero_row;

  logic scale_in_valid,scale_in_is_qk;
  logic [2:0] scale_in_head,scale_out_head;
  logic [4:0] scale_in_query,scale_out_query;
  logic [1:0] scale_in_co,scale_out_co;
  logic signed [2047:0] scale_in_acc;
  logic signed [511:0] scale_in_bias;
  logic signed [31:0] scale_in_mult;
  logic [5:0] scale_in_shift;
  logic scale_out_valid,scale_out_is_qk;
  logic signed [255:0] scale_out_code;

  function automatic logic [ROW_AW-1:0] row_addr(
    input logic [2:0] head,
    input logic [4:0] query
  );
    int unsigned a;
    begin
      a=$unsigned(head)*MAX_TOKENS+$unsigned(query);
      row_addr=a[ROW_AW-1:0];
    end
  endfunction

  assign mode_pv=(st_q==A_PV_REQ)||(st_q==A_PV_RUN)||(st_q==A_PV_DRAIN);
  assign client_req=(st_q==A_QK_REQ)||(st_q==A_PV_REQ);
  assign client_cfg_tokens_m1={6'd0,tokens_q-1'b1};
  assign client_cfg_k_tiles_m1=mode_pv?4'd0:{2'b00,(chunks_q-1'b1)};
  assign client_cfg_n_tiles_m1=mode_pv?{2'b00,(chunks_q-1'b1)}:4'd0;
  assign qk_expected=$unsigned(heads_q)*$unsigned(tokens_q);
  assign pv_expected=$unsigned(heads_q)*$unsigned(tokens_q)*$unsigned(chunks_q);

  // BRAM requests use one-word lookahead. The shared MAC advances its address
  // only when the matching response-valid is asserted, so data and token tags
  // remain aligned after the initial one-cycle fill.
  always_comb begin
    q_rd_en=1'b0;q_rd_token=svc_stream_token_id[4:0];q_rd_co='0;
    k_rd_en=1'b0;k_rd_co='0;k_rd_row=svc_weight_row_index;
    v_rd_en=1'b0;v_rd_token=svc_weight_row_index;v_rd_co='0;

    if(!mode_pv && client_grant && svc_stream_valid) begin
      q_rd_en=!q_rd_valid || (svc_stream_token_id<$unsigned(tokens_q)-1'b1);
      q_rd_token=svc_stream_token_id[4:0]+(q_rd_valid?5'd1:5'd0);
      q_rd_co=(head_q*chunks_q)+svc_active_ci_tile[1:0];
    end
    if(!mode_pv && client_grant && svc_weight_row_load) begin
      k_rd_en=!k_rd_valid || (svc_weight_row_index<5'd31);
      k_rd_row=svc_weight_row_index+(k_rd_valid?5'd1:5'd0);
      k_rd_co=(head_q*chunks_q)+svc_active_ci_tile[1:0];
    end
    if(mode_pv && client_grant && svc_weight_row_load &&
       (svc_weight_row_index<$unsigned(tokens_q))) begin
      v_rd_en=!v_rd_valid || (svc_weight_row_index<5'd31);
      if(svc_weight_row_index==$unsigned(tokens_q)-1'b1)
        v_rd_en=!v_rd_valid;
      v_rd_token=svc_weight_row_index+(v_rd_valid?5'd1:5'd0);
      v_rd_co=(head_q*chunks_q)+svc_active_co_tile[1:0];
    end
  end

  always_comb begin
    pv_v_zero_row=mode_pv&&svc_weight_row_load&&
                  (svc_weight_row_index>=$unsigned(tokens_q));
    client_input_valid=mode_pv?prob_rd_valid_q:q_rd_valid;
    client_weight_valid=mode_pv?(pv_v_zero_row?1'b1:v_rd_valid):k_rd_valid;
    for(int lane=0;lane<32;lane=lane+1) begin
      if(mode_pv) begin
        client_input_vector[lane]={1'b0,prob_rd_data_q[lane*8+:8]};
        if(pv_v_zero_row)
          client_weight_row_values[lane]='0;
        else
          client_weight_row_values[lane]=
            {v_rd_data[lane*8+7],v_rd_data[lane*8+:8]};
      end else begin
        client_input_vector[lane]=
          {q_rd_data[lane*8+7],q_rd_data[lane*8+:8]};
        client_weight_row_values[lane]=
          {k_rd_data[lane*8+7],k_rd_data[lane*8+:8]};
      end
    end

    relpos_req_valid=svc_raw_valid&&client_grant&&!mode_pv;
    relpos_req_block=block_q;
    relpos_req_head=head_q;
    relpos_req_query=svc_raw_token_id[4:0];

    exp_req_valid=(st_q==A_SM_EXP_REQ);
    exp_req_block=block_q;
    for(int lane=0;lane<32;lane=lane+1) begin
      if(lane<$unsigned(tokens_q))
        exp_req_delta[lane]=soft_max_q-$signed(soft_logits_q[lane*8+:8]);
      else
        exp_req_delta[lane]=8'sd0;
    end

    busy=(st_q!=A_IDLE)&&(st_q!=A_DONE);
  end

  always_comb begin
    scale_in_valid=(relpos_resp_valid&&qk_pipe_valid_q)||
                   (svc_raw_valid&&client_grant&&mode_pv);
    scale_in_is_qk=relpos_resp_valid&&qk_pipe_valid_q;
    scale_in_head=scale_in_is_qk?qk_pipe_head_q:head_q;
    scale_in_query=scale_in_is_qk?qk_pipe_query_q:svc_raw_token_id[4:0];
    scale_in_co=scale_in_is_qk?2'd0:
      ((head_q*chunks_q)+svc_raw_co_tile[1:0]);
    scale_in_mult=scale_in_is_qk?qk_m_q:ctx_m_q;
    scale_in_shift=scale_in_is_qk?qk_shift_q:ctx_shift_q;
    scale_in_acc='0;
    scale_in_bias='0;
    for(int lane=0;lane<32;lane=lane+1) begin
      scale_in_acc[lane*64+:64]=scale_in_is_qk?
        qk_pipe_acc_q[lane]:svc_raw_acc[lane];
      if(scale_in_is_qk)
        scale_in_bias[lane*16+:16]=relpos_resp_bias[lane];
    end

    qk_logit_wr_en=scale_out_valid&&scale_out_is_qk;
    qk_logit_wr_addr=row_addr(scale_out_head,scale_out_query);

    logit_rd_en=(st_q==A_SM_ROW_REQ);
    logit_rd_addr=row_addr(sm_head_q,sm_query_q);
    prob_wr_en=(st_q==A_SM_PROB_WRITE);
    prob_wr_addr=row_addr(sm_head_q,sm_query_q);

    prob_rd_en=1'b0;
    prob_rd_addr=row_addr(head_q,svc_stream_token_id[4:0]);
    if(mode_pv && client_grant && svc_stream_valid) begin
      prob_rd_en=!prob_rd_valid_q ||
                 (svc_stream_token_id<$unsigned(tokens_q)-1'b1);
      prob_rd_addr=row_addr(head_q,
        svc_stream_token_id[4:0]+(prob_rd_valid_q?5'd1:5'd0));
    end

  end

  swin_attention_scale32_dsp u_attention_scaler(
    .clk,.rst_n,.in_valid(scale_in_valid),.in_is_qk(scale_in_is_qk),
    .in_head(scale_in_head),.in_query(scale_in_query),.in_co(scale_in_co),
    .in_acc(scale_in_acc),.in_bias(scale_in_bias),
    .in_mult(scale_in_mult),.in_shift(scale_in_shift),
    .out_valid(scale_out_valid),.out_is_qk(scale_out_is_qk),
    .out_head(scale_out_head),.out_query(scale_out_query),.out_co(scale_out_co),
    .out_code(scale_out_code));

  // BRAM read/write processes: no array reset loops.
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      logit_rd_valid_q<=1'b0;
      prob_rd_valid_q<=1'b0;
    end else begin
      if(qk_logit_wr_en)
        logits_mem[qk_logit_wr_addr]<=scale_out_code;
      logit_rd_valid_q<=logit_rd_en;
      if(logit_rd_en)
        logit_rd_data_q<=logits_mem[logit_rd_addr];

      if(prob_wr_en)
        probs_mem[prob_wr_addr]<=prob_row_q;
      prob_rd_valid_q<=prob_rd_en;
      if(prob_rd_en)
        prob_rd_data_q<=probs_mem[prob_rd_addr];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      st_q<=A_IDLE;done<=1'b0;
      block_q<='0;heads_q<='0;tokens_q<='0;chunks_q<='0;
      qk_m_q<='0;qk_shift_q<='0;ctx_m_q<='0;ctx_shift_q<='0;
      head_q<='0;sm_head_q<='0;sm_query_q<='0;sm_key_q<='0;
      soft_max_q<='0;soft_denom_q<='0;soft_logits_q<='0;prob_row_q<='0;
      div_work_q<='0;div_trial_q<='0;div_quot_q<='0;div_bit_q<='0;
      qk_pipe_valid_q<=1'b0;qk_pipe_query_q<='0;qk_pipe_head_q<='0;
      qk_resp_count_q<='0;pv_resp_count_q<='0;
      ctx_valid<=1'b0;ctx_token<='0;ctx_co_tile<='0;ctx_data<='0;
      for(int lane=0;lane<32;lane=lane+1) qk_pipe_acc_q[lane]<='0;
    end else begin
      done<=1'b0;
      ctx_valid<=1'b0;

      qk_pipe_valid_q<=relpos_req_valid;
      if(relpos_req_valid) begin
        qk_pipe_query_q<=svc_raw_token_id[4:0];
        qk_pipe_head_q<=head_q;
        for(int lane=0;lane<32;lane=lane+1)
          qk_pipe_acc_q[lane]<=svc_raw_acc[lane];
      end

      if(qk_logit_wr_en)
        qk_resp_count_q<=qk_resp_count_q+1'b1;

      if(scale_out_valid&&!scale_out_is_qk) begin
        pv_resp_count_q<=pv_resp_count_q+1'b1;
        ctx_valid<=1'b1;
        ctx_token<=scale_out_query;
        ctx_co_tile<=scale_out_co;
        ctx_data<=scale_out_code;
      end

      if(exp_resp_valid)
        for(int lane=0;lane<32;lane=lane+1)
          exp_cache[lane]<=exp_resp_value[lane];

      case(st_q)
        A_IDLE: if(start) begin
          block_q<=block_id;heads_q<=cfg_heads;tokens_q<=cfg_tokens;chunks_q<=cfg_chunks;
          qk_m_q<=cfg_qk_m;qk_shift_q<=cfg_qk_shift;
          ctx_m_q<=cfg_ctx_m;ctx_shift_q<=cfg_ctx_shift;
          head_q<='0;qk_resp_count_q<='0;pv_resp_count_q<='0;
          st_q<=A_QK_REQ;
        end

        A_QK_REQ: if(client_grant) st_q<=A_QK_RUN;
        A_QK_RUN: if(svc_done&&client_grant) begin
          if(head_q==heads_q-1'b1) st_q<=A_QK_DRAIN;
          else begin head_q<=head_q+1'b1;st_q<=A_QK_REQ;end
        end
        A_QK_DRAIN: if(qk_resp_count_q==qk_expected) begin
          sm_head_q<='0;sm_query_q<='0;sm_key_q<='0;
          st_q<=A_SM_ROW_REQ;
        end

        A_SM_ROW_REQ: st_q<=A_SM_ROW_WAIT;
        A_SM_ROW_WAIT: if(logit_rd_valid_q) begin
          soft_logits_q<=logit_rd_data_q;
          soft_max_q<=$signed(logit_rd_data_q[7:0]);
          sm_key_q<='0;prob_row_q<='0;
          st_q<=A_SM_MAX;
        end
        A_SM_MAX: begin
          if($signed(soft_logits_q[sm_key_q*8+:8])>soft_max_q)
            soft_max_q<=$signed(soft_logits_q[sm_key_q*8+:8]);
          if(sm_key_q==tokens_q-1'b1) begin
            sm_key_q<='0;st_q<=A_SM_EXP_REQ;
          end else sm_key_q<=sm_key_q+1'b1;
        end
        A_SM_EXP_REQ: st_q<=A_SM_EXP_WAIT;
        A_SM_EXP_WAIT: if(exp_resp_valid) begin
          soft_denom_q<='0;sm_key_q<='0;st_q<=A_SM_SUM;
        end
        A_SM_SUM: begin
          soft_denom_q<=soft_denom_q+{16'd0,exp_cache[sm_key_q]};
          if(sm_key_q==tokens_q-1'b1) begin
            sm_key_q<='0;st_q<=A_SM_DIV_INIT;
          end else sm_key_q<=sm_key_q+1'b1;
        end
        A_SM_DIV_INIT: begin
          logic [31:0] exp_wide;
          logic [31:0] numer;
          exp_wide={16'd0,exp_cache[sm_key_q]};
          numer=(exp_wide<<8)-exp_wide;

          // Preserve div_round_uq08 exactly: round by denom/2, then resolve
          // quotient bits 7..0. Four ITER cycles resolve two adjacent bits
          // each, limiting the path to two compare/subtract stages.
          div_work_q<=numer+(soft_denom_q>>1);
          div_trial_q<=soft_denom_q<<7;
          div_quot_q<='0;
          div_bit_q<=3'd7;

          if(soft_denom_q==0) begin
            prob_row_q[sm_key_q*8+:8]<=8'd0;
            if(sm_key_q==tokens_q-1'b1) begin
              sm_key_q<='0;st_q<=A_SM_PROB_WRITE;
            end else begin
              sm_key_q<=sm_key_q+1'b1;st_q<=A_SM_DIV_INIT;
            end
          end else begin
            st_q<=A_SM_DIV_ITER;
          end
        end

        A_SM_DIV_ITER: begin
          logic [31:0] work_mid;
          logic [31:0] work_next;
          logic [31:0] trial_low;
          logic [7:0] quot_next;
          work_mid=div_work_q;
          work_next=div_work_q;
          trial_low=div_trial_q>>1;
          quot_next=div_quot_q;

          if(work_mid>=div_trial_q) begin
            work_mid=work_mid-div_trial_q;
            quot_next[div_bit_q]=1'b1;
          end
          work_next=work_mid;
          if(work_mid>=trial_low) begin
            work_next=work_mid-trial_low;
            quot_next[div_bit_q-1'b1]=1'b1;
          end

          if(div_bit_q==3'd1) begin
            // quot_next includes both final bit-1 and bit-0 decisions.
            prob_row_q[sm_key_q*8+:8]<=quot_next;
            if(sm_key_q==tokens_q-1'b1) begin
              sm_key_q<='0;st_q<=A_SM_PROB_WRITE;
            end else begin
              sm_key_q<=sm_key_q+1'b1;st_q<=A_SM_DIV_INIT;
            end
          end else begin
            div_work_q<=work_next;
            div_trial_q<=div_trial_q>>2;
            div_quot_q<=quot_next;
            div_bit_q<=div_bit_q-3'd2;
          end
        end
        A_SM_PROB_WRITE: begin
          if(sm_query_q==tokens_q-1'b1) begin
            sm_query_q<='0;
            if(sm_head_q==heads_q-1'b1) begin
              head_q<='0;st_q<=A_PV_REQ;
            end else begin
              sm_head_q<=sm_head_q+1'b1;st_q<=A_SM_ROW_REQ;
            end
          end else begin
            sm_query_q<=sm_query_q+1'b1;st_q<=A_SM_ROW_REQ;
          end
        end

        A_PV_REQ: if(client_grant) st_q<=A_PV_RUN;
        A_PV_RUN: if(svc_done&&client_grant) begin
          if(head_q==heads_q-1'b1) st_q<=A_PV_DRAIN;
          else begin head_q<=head_q+1'b1;st_q<=A_PV_REQ;end
        end
        A_PV_DRAIN: if(pv_resp_count_q==pv_expected) st_q<=A_DONE;
        A_DONE: begin done<=1'b1;st_q<=A_IDLE;end
        default: st_q<=A_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if(rst_n&&start&&((cfg_tokens==0)||(cfg_tokens>MAX_TOKENS)))
      $fatal(1,"single-engine attention token count out of range: %0d",cfg_tokens);
    if(rst_n&&start&&((cfg_heads==0)||(cfg_heads>MAX_HEADS)))
      $fatal(1,"single-engine attention head count out of range: %0d",cfg_heads);
    if(rst_n&&start&&((cfg_chunks==0)||(cfg_chunks>MAX_CHUNKS)))
      $fatal(1,"single-engine attention chunk count out of range: %0d",cfg_chunks);
    if(rst_n&&relpos_resp_valid&&!qk_pipe_valid_q)
      $fatal(1,"single-engine attention relpos response without raw QK vector");
    if(rst_n&&q_rd_valid&&mode_pv)
      $fatal(1,"single-engine attention stale Q response in PV phase");
    if(rst_n&&svc_stream_valid&&client_grant&&
       (svc_stream_token_id>=$unsigned(tokens_q)))
      $fatal(1,"single-engine attention stream token out of range: %0d/%0d",
             svc_stream_token_id,tokens_q);
  end
`endif
endmodule
