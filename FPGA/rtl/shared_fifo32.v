`timescale 1ns/1ps
// One synchronous-clock, 32-word FIFO. Data is valid only when out_valid is high.
module shared_fifo32 (
    input wire clk, input wire rst,
    input wire in_valid, output wire in_ready, input wire [31:0] in_data,
    output wire out_valid, input wire out_ready, output wire [31:0] out_data,
    output reg [5:0] count
);
    reg [31:0] mem [0:31];
    reg [4:0] wr_ptr, rd_ptr;
    wire push = in_valid && in_ready;
    wire pop = out_valid && out_ready;
    assign in_ready = !rst && count < 32;
    assign out_valid = !rst && count != 0;
    assign out_data = mem[rd_ptr];
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0; rd_ptr <= 0; count <= 0;
        end else begin
            if (push) begin mem[wr_ptr] <= in_data; wr_ptr <= wr_ptr + 1'b1; end
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            case ({push,pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
