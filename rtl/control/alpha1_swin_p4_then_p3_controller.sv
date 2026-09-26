`timescale 1ns/1ps
// ============================================================================
// alpha1_swin_p4_then_p3_controller.sv
//
// Master control for the post-projection Alpha1 Swin subsystem.
// Inputs are written by the already-verified projection RTL before the matching
// *_projection_ready flag is asserted. The controller then runs P4 completely,
// waits for P3 projection readiness, and runs P3 completely.
//
// Every child start is exactly one clock. abort resets child datapaths through
// the parent top and reports ABORTED until start is deasserted.
// ============================================================================
module alpha1_swin_p4_then_p3_controller (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic abort,

    input  logic p4_projection_ready,
    input  logic p3_projection_ready,
    input  logic p4_swin_done,
    input  logic p3_swin_done,

    output logic p4_swin_start,
    output logic p3_swin_start,
    output logic busy,
    output logic done,
    output logic aborted,
    output logic [3:0] state_code
);
    typedef enum logic [3:0] {
        ST_IDLE       = 4'd0,
        ST_WAIT_P4    = 4'd1,
        ST_LAUNCH_P4  = 4'd2,
        ST_RUN_P4     = 4'd3,
        ST_WAIT_P3    = 4'd4,
        ST_LAUNCH_P3  = 4'd5,
        ST_RUN_P3     = 4'd6,
        ST_DONE       = 4'd7,
        ST_ABORTED    = 4'd8
    } state_t;

    state_t st_q;

    always_comb begin
        p4_swin_start = 1'b0;
        p3_swin_start = 1'b0;
        busy          = (st_q != ST_IDLE) && (st_q != ST_DONE) && (st_q != ST_ABORTED);
        done          = (st_q == ST_DONE);
        aborted       = (st_q == ST_ABORTED);
        state_code    = st_q;
        if (st_q == ST_LAUNCH_P4) p4_swin_start = 1'b1;
        if (st_q == ST_LAUNCH_P3) p3_swin_start = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q <= ST_IDLE;
        end else if (abort && (st_q != ST_IDLE)) begin
            st_q <= ST_ABORTED;
        end else begin
            case (st_q)
                ST_IDLE:      if (start)               st_q <= ST_WAIT_P4;
                ST_WAIT_P4:   if (p4_projection_ready) st_q <= ST_LAUNCH_P4;
                ST_LAUNCH_P4:                         st_q <= ST_RUN_P4;
                ST_RUN_P4:    if (p4_swin_done)        st_q <= ST_WAIT_P3;
                ST_WAIT_P3:   if (p3_projection_ready) st_q <= ST_LAUNCH_P3;
                ST_LAUNCH_P3:                         st_q <= ST_RUN_P3;
                ST_RUN_P3:    if (p3_swin_done)        st_q <= ST_DONE;
                ST_DONE:      if (!start)              st_q <= ST_IDLE;
                ST_ABORTED:   if (!start)              st_q <= ST_IDLE;
                default:                              st_q <= ST_IDLE;
            endcase
        end
    end
endmodule
