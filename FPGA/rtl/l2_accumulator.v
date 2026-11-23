`timescale 1ns/1ps
// 512 digital INT32 accumulators. A response is read only on valid && ready.
module l2_accumulator (
    input wire clk, input wire rst, input wire drain_enable,
    input wire response_valid, output wire response_ready, input wire [31:0] response_data,
    input wire clear_valid, output wire clear_ready, input wire pe_quiescent,
    input wire [8:0] read_addr, output wire [31:0] read_data,
    output reg [31:0] compute_words_read, output wire clearing
);
    (* ram_style = "distributed" *) reg [31:0] sums [0:511];
    reg clear_busy;
    reg [8:0] clear_addr;
    wire clear_fire = clear_valid && clear_ready;
    assign clearing = clear_busy;
    assign clear_ready = !rst && !clear_busy && pe_quiescent;
    assign response_ready = !rst && !clear_busy && !clear_fire && drain_enable;
    assign read_data = sums[read_addr];
    always @(posedge clk) begin
        if (rst) begin
            clear_busy <= 1; clear_addr <= 0; compute_words_read <= 0;
        end else if (clear_fire) begin
            clear_busy <= 1; clear_addr <= 0; compute_words_read <= 0;
        end else if (clear_busy) begin
            sums[clear_addr] <= 0;
            if (clear_addr == 511) clear_busy <= 0;
            else clear_addr <= clear_addr + 1'b1;
        end else if (response_valid && response_ready && response_data[24:23] == 2'b10) begin
            sums[response_data[22:14]] <= sums[response_data[22:14]] + {18'b0,response_data[13:0]};
            compute_words_read <= compute_words_read + 1'b1;
        end
    end
endmodule
