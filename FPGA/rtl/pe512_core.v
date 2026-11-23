`timescale 1ns/1ps
// Binary logical 512x512 PE: 256 resident 32x32 tiles share exactly two FIFOs.
// No next command is executed until the preceding response batch is drained.
module pe512_core (
    input wire clk, input wire rst,
    input wire cmd_valid, output wire cmd_ready, input wire [31:0] cmd_data,
    output wire rsp_valid, input wire rsp_ready, output wire [31:0] rsp_data,
    input wire prog_valid, output wire prog_ready,
    input wire [12:0] prog_addr, input wire [31:0] prog_data,
    output wire init_done, output wire configured, output wire busy,
    output wire [5:0] command_count, output wire [5:0] response_count,
    output reg [31:0] launch_count, output reg [31:0] responses_read,
    output wire [31:0] responses_discarded, output reg [3:0] error_code
);
    localparam S_SCRUB=0, S_IDLE=1, S_START=2, S_FETCH=3, S_ACC=4,
               S_EMIT=5, S_DRAIN=6, S_CELL_FETCH=7, S_CELL_VALUE=8,
               S_CELL_WRITE=9, S_CELL_EMIT=10;
    reg [3:0] state;
    reg [12:0] scrub_addr;
    reg [1:0] config_count;
    reg [31:0] configuration [0:2];
    reg [3:0] tile_row, tile_col;
    reg [31:0] input_bits;
    reg [5:0] packet_count;
    reg [4:0] row_index, emit_index;
    reg [5:0] sums [0:31];
    reg [12:0] cell_addr;
    reg [4:0] cell_col;
    reg [8:0] cell_global_col;
    reg [1:0] cell_mode;
    reg cell_value;
    reg [31:0] cell_write_word;
    (* ram_style = "block" *) reg [31:0] weights [0:8191];
    reg [31:0] weight_q;
    integer j;

    wire cq_valid, cq_ready, cq_in_ready;
    wire [31:0] packet;
    wire rq_valid, rq_ready, rq_push_ready;
    wire rq_push = state == S_EMIT || state == S_CELL_EMIT;
    wire [8:0] result_col = {tile_col,emit_index};
    wire [31:0] rq_data = state == S_EMIT ?
        {7'b0,2'b10,result_col,8'b0,sums[emit_index]} :
        {7'b0,cell_mode,cell_global_col,13'b0,cell_value};
    wire consume = cq_valid && cq_ready;
    wire [1:0] mode = packet[31:30];
    wire [3:0] packet_tile_row = packet[29:26];
    wire [4:0] packet_local_row = packet[25:21];
    wire [3:0] packet_tile_col = packet[20:17];
    wire [4:0] packet_local_col = packet[16:12];
    wire [12:0] packet_address = {packet_tile_row,packet_tile_col,packet_local_row};
    wire bank_mismatch = packet_count != 0 &&
        (packet_tile_row != tile_row || packet_tile_col != tile_col);
    wire ram_write_enable = !rst && (state == S_SCRUB ||
        (prog_valid && prog_ready) || state == S_CELL_WRITE);
    wire [12:0] ram_write_addr = state == S_SCRUB ? scrub_addr :
        state == S_CELL_WRITE ? cell_addr : prog_addr;
    wire [31:0] ram_write_data = state == S_SCRUB ? 32'b0 :
        state == S_CELL_WRITE ? cell_write_word : prog_data;
    wire ram_read_enable = !rst && (state == S_FETCH || state == S_CELL_FETCH);
    wire [12:0] ram_read_addr = state == S_CELL_FETCH ? cell_addr :
        {tile_row,tile_col,row_index};

    assign init_done = state != S_SCRUB && !rst;
    assign configured = config_count == 3 && init_done;
    assign busy = !init_done || state != S_IDLE || packet_count != 0;
    assign prog_ready = configured && state == S_IDLE && packet_count == 0 &&
                        command_count == 0 && response_count == 0 && !cmd_valid;
    assign cmd_ready = cq_in_ready && init_done;
    assign cq_ready = state == S_IDLE && response_count == 0 && !rst;
    assign rsp_valid = rq_valid && state == S_DRAIN && !rst;
    assign rq_ready = rsp_ready && state == S_DRAIN && !rst;
    assign responses_discarded = 32'd0; // Unread data is never flushed.

    shared_fifo32 command_fifo (
        .clk(clk),.rst(rst),.in_valid(cmd_valid && init_done),.in_ready(cq_in_ready),
        .in_data(cmd_data),.out_valid(cq_valid),.out_ready(cq_ready),
        .out_data(packet),.count(command_count));
    shared_fifo32 response_fifo (
        .clk(clk),.rst(rst),.in_valid(rq_push),.in_ready(rq_push_ready),
        .in_data(rq_data),.out_valid(rq_valid),.out_ready(rq_ready),
        .out_data(rsp_data),.count(response_count));

    // Single synchronous RAM read port, one write port; reset scrubs over 8192 clocks.
    // Physical memory address = {tile_row, tile_column, row_within_tile}.
    always @(posedge clk) begin
        if (ram_write_enable) weights[ram_write_addr] <= ram_write_data;
        if (ram_read_enable) weight_q <= weights[ram_read_addr];
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_SCRUB; scrub_addr <= 0; config_count <= 0;
            input_bits <= 0; packet_count <= 0; tile_row <= 0; tile_col <= 0;
            row_index <= 0; emit_index <= 0;
            launch_count <= 0; responses_read <= 0; error_code <= 0;
            cell_addr <= 0; cell_col <= 0; cell_global_col <= 0;
            cell_mode <= 0; cell_value <= 0; cell_write_word <= 0;
            for (j=0;j<32;j=j+1) sums[j] <= 0;
        end else begin
            if (rsp_valid && rsp_ready) responses_read <= responses_read + 1'b1;
            case (state)
                S_SCRUB: begin
                    if (scrub_addr == 8191) state <= S_IDLE;
                    else scrub_addr <= scrub_addr + 1'b1;
                end
                S_IDLE: if (consume) begin
                    if (config_count != 3) begin
                        // Keep the three Python configuration packets; analog timing is not emulated.
                        configuration[config_count] <= packet;
                        config_count <= config_count + 1'b1;
                    end else if (mode == 2'b10) begin
                        if (!packet[10] || packet[11] || packet[8] || packet[7:0] > 1) begin
                            error_code <= 1; input_bits <= 0; packet_count <= 0;
                        end else if (bank_mismatch) begin
                            error_code <= 2; input_bits <= 0; packet_count <= 0;
                        end else begin
                            if (packet_count == 0) begin
                                tile_row <= packet_tile_row; tile_col <= packet_tile_col;
                                input_bits <= packet[0] ? (32'b1 << packet_local_row) : 32'b0;
                            end else input_bits[packet_local_row] <= packet[0];
                            if (packet[9] || packet_count == 31) begin
                                packet_count <= 0; state <= S_START;
                            end else packet_count <= packet_count + 1'b1;
                        end
                    end else begin
                        // Binary cell SET, RESET or READ; one response, through the same FIFO.
                        input_bits <= 0; packet_count <= 0;
                        cell_addr <= packet_address; cell_col <= packet_local_col;
                        cell_global_col <= packet[20:12]; cell_mode <= mode;
                        state <= S_CELL_FETCH;
                    end
                end
                S_START: begin
                    launch_count <= launch_count + 1'b1;
                    row_index <= 0;
                    for (j=0;j<32;j=j+1) sums[j] <= 0;
                    state <= S_FETCH;
                end
                S_FETCH: state <= S_ACC;
                S_ACC: begin
                    for (j=0;j<32;j=j+1)
                        sums[j] <= sums[j] + (input_bits[row_index] & weight_q[j]);
                    if (row_index == 31) begin emit_index <= 0; state <= S_EMIT; end
                    else begin row_index <= row_index + 1'b1; state <= S_FETCH; end
                end
                S_EMIT: if (rq_push_ready) begin
                    if (emit_index == 31) state <= S_DRAIN;
                    else emit_index <= emit_index + 1'b1;
                end
                S_DRAIN: if (response_count == 0) begin
                    // This state cannot finish until the consumer accepts the last response.
                    input_bits <= 0; state <= S_IDLE;
                end
                S_CELL_FETCH: state <= S_CELL_VALUE;
                S_CELL_VALUE: begin
                    if (cell_mode == 2'b01) begin
                        cell_value <= weight_q[cell_col]; state <= S_CELL_EMIT;
                    end else begin
                        cell_value <= cell_mode == 2'b11;
                        cell_write_word <= cell_mode == 2'b11 ?
                            weight_q | (32'b1 << cell_col) : weight_q & ~(32'b1 << cell_col);
                        state <= S_CELL_WRITE;
                    end
                end
                S_CELL_WRITE: state <= S_CELL_EMIT;
                S_CELL_EMIT: if (rq_push_ready) state <= S_DRAIN;
                default: state <= S_SCRUB;
            endcase
        end
    end
endmodule
