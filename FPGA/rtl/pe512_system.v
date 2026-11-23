`timescale 1ns/1ps
// PS-facing ready/valid wrapper. The L2 consumer can be paused with drain_enable.
module pe512_system (
    input wire clk, input wire rst,
    input wire cmd_valid, output wire cmd_ready, input wire [31:0] cmd_data,
    input wire prog_valid, output wire prog_ready,
    input wire [12:0] prog_addr, input wire [31:0] prog_data,
    input wire drain_enable,
    output wire response_valid, output wire response_ready, output wire [31:0] response_data,
    input wire l2_clear_valid, output wire l2_clear_ready,
    input wire [8:0] l2_read_addr, output wire [31:0] l2_read_data,
    output wire l2_clearing, output wire [31:0] l2_compute_words,
    output wire init_done, output wire configured, output wire busy,
    output wire [5:0] command_count, output wire [5:0] response_count,
    output wire [31:0] launch_count, output wire [31:0] responses_read,
    output wire [31:0] responses_discarded, output wire [3:0] error_code
);
    wire quiescent = !busy && command_count == 0 && response_count == 0 && !cmd_valid && !prog_valid;
    pe512_core pe (
        .clk(clk),.rst(rst),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_data(cmd_data),
        .rsp_valid(response_valid),.rsp_ready(response_ready),.rsp_data(response_data),
        .prog_valid(prog_valid),.prog_ready(prog_ready),.prog_addr(prog_addr),.prog_data(prog_data),
        .init_done(init_done),.configured(configured),.busy(busy),
        .command_count(command_count),.response_count(response_count),
        .launch_count(launch_count),.responses_read(responses_read),
        .responses_discarded(responses_discarded),.error_code(error_code));
    l2_accumulator l2 (
        .clk(clk),.rst(rst),.drain_enable(drain_enable),
        .response_valid(response_valid),.response_ready(response_ready),.response_data(response_data),
        .clear_valid(l2_clear_valid),.clear_ready(l2_clear_ready),.pe_quiescent(quiescent),
        .read_addr(l2_read_addr),.read_data(l2_read_data),.clearing(l2_clearing),
        .compute_words_read(l2_compute_words));
endmodule
