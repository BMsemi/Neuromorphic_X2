`timescale 1ns/1ps

// Self-checking generic AHB verification for Neuromorphic_X2_ahb_beh.
// The testbench drives the model's native 32-bit AHB subordinate interface.
module tb_Neuromorphic_X2_ahb_beh;

  localparam logic [31:0] X2_ADDR        = 32'hE000_0004;
  localparam logic [1:0]  HTRANS_IDLE    = 2'b00;
  localparam logic [1:0]  HTRANS_NONSEQ  = 2'b10;
  localparam logic [2:0]  HSIZE_BYTE     = 3'b000;
  localparam logic [2:0]  HSIZE_WORD     = 3'b010;
  localparam logic [1:0]  HRESP_OKAY     = 2'b00;
  localparam logic [1:0]  HRESP_ERROR    = 2'b01;
  localparam logic [1:0]  MODE_RESET     = 2'b00;
  localparam logic [1:0]  MODE_READ      = 2'b01;
  localparam logic [1:0]  MODE_COMPUTE   = 2'b10;
  localparam logic [1:0]  MODE_SET       = 2'b11;

  logic        HCLK;
  logic        HRESETn;
  logic        HSEL;
  logic [31:0] HADDR;
  logic [1:0]  HTRANS;
  logic        HWRITE;
  logic [2:0]  HSIZE;
  logic [2:0]  HBURST;
  logic [3:0]  HPROT;
  logic [3:0]  HMASTER;
  logic        HMASTLOCK;
  logic [31:0] HWDATA;
  wire         HREADY;
  wire  [31:0] HRDATA;
  wire         HREADYOUT;
  wire  [1:0]  HRESP;

  logic        i_scan_si1;
  logic        i_scan_se1;
  logic        i_TM;
  wire         o_TM;
  wire  [1:0]  o_mux_sel;
  wire  [511:0] o_sl_float;
  wire  [511:0] o_sl_addr;
  wire  [511:0] o_sl_data;
  wire  [511:0] o_bl_addr;
  wire  [511:0] o_bl_data;
  wire  [511:0] o_bl_float;
  wire  [511:0] o_wl_float;
  wire  [511:0] o_wl_addr;
  wire  [511:0] o_wl_data;

  integer failures;
  integer checks;

  // A single-subordinate test bus feeds the subordinate's HREADYOUT response
  // back as global HREADY, as an AHB interconnect does for its selected target.
  assign HREADY = HREADYOUT;

  Neuromorphic_X2_ahb_beh #(
    .ADDR_MATCH(X2_ADDR),
    .CONFIG_WRITES(3),
    .INITIAL_CELL_LEVEL(14'h0E23)
  ) dut (
    .HCLK       (HCLK),
    .HRESETn    (HRESETn),
    .HSEL       (HSEL),
    .HADDR      (HADDR),
    .HTRANS     (HTRANS),
    .HWRITE     (HWRITE),
    .HSIZE      (HSIZE),
    .HBURST     (HBURST),
    .HPROT      (HPROT),
    .HMASTER    (HMASTER),
    .HMASTLOCK  (HMASTLOCK),
    .HWDATA     (HWDATA),
    .HREADY     (HREADY),
    .HRDATA     (HRDATA),
    .HREADYOUT  (HREADYOUT),
    .HRESP      (HRESP),
    .i_scan_si1(i_scan_si1),
    .i_scan_se1(i_scan_se1),
    .i_TM(i_TM),
    .o_TM(o_TM),
    .o_mux_sel(o_mux_sel),
    .o_sl_float(o_sl_float),
    .o_sl_addr(o_sl_addr),
    .o_sl_data(o_sl_data),
    .o_bl_addr(o_bl_addr),
    .o_bl_data(o_bl_data),
    .o_bl_float(o_bl_float),
    .o_wl_float(o_wl_float),
    .o_wl_addr(o_wl_addr),
    .o_wl_data(o_wl_data)
  );

  always #5 HCLK = ~HCLK;

  function automatic [31:0] command_word;
    input logic [1:0] mode;
    input logic [8:0] row_index;
    input logic [8:0] col_index;
    input logic       fsm_error_read;
    input logic       compute_all;
    input logic       compute_start;
    input logic [7:0] pwm;
    begin
      command_word = {mode, row_index, col_index, fsm_error_read,
                      compute_all, compute_start, 1'b0, pwm};
    end
  endfunction

  function automatic [31:0] expected_result;
    input logic [1:0]  mode;
    input logic [8:0]  col_index;
    input logic [13:0] count;
    begin
      expected_result = {7'b0, mode, col_index, count};
    end
  endfunction

  task automatic check_word;
    input [31:0] actual;
    input [31:0] expected;
    input string label_text;
    begin
      checks = checks + 1;
      if (actual !== expected) begin
        failures = failures + 1;
        $display("FAIL: %s actual=%08x expected=%08x", label_text,
                 actual, expected);
      end else begin
        $display("PASS: %s value=%08x", label_text, actual);
      end
    end
  endtask

  task automatic check_bit;
    input logic actual;
    input logic expected;
    input string label_text;
    begin
      checks = checks + 1;
      if (actual !== expected) begin
        failures = failures + 1;
        $display("FAIL: %s actual=%b expected=%b", label_text,
                 actual, expected);
      end else begin
        $display("PASS: %s value=%b", label_text, actual);
      end
    end
  endtask

  // Protocol-accurate, non-pipelined AHB transfer.  A poison
  // value is driven during a write address phase and the real HWDATA is driven
  // only in the data phase, detecting accidental address-phase data sampling.
  task automatic ahb_transfer;
    input  logic        write_transfer;
    input  logic [31:0] address;
    input  logic [2:0]  size;
    input  logic [31:0] write_data;
    output logic [31:0] read_data;
    output logic [1:0]  response;
    output integer      wait_cycles;
    output logic        error_wait_seen;
    begin
      while (HREADYOUT !== 1'b1)
        @(negedge HCLK);

      HSEL      = 1'b1;
      HADDR     = address;
      HTRANS    = HTRANS_NONSEQ;
      HWRITE    = write_transfer;
      HSIZE     = size;
      HBURST    = 3'b000;
      HPROT     = 4'b0011;
      HMASTER   = 4'd1;
      HMASTLOCK = 1'b0;
      HWDATA    = write_transfer ? 32'hDEAD_BEEF : 32'b0;

      // Address phase is accepted on this edge.
      @(posedge HCLK);
      @(negedge HCLK);

      // Move to the data phase and remove the address-phase selection.
      HSEL   = 1'b0;
      HADDR  = 32'b0;
      HTRANS = HTRANS_IDLE;
      HWRITE = 1'b0;
      HSIZE  = HSIZE_WORD;
      HWDATA = write_transfer ? write_data : 32'b0;

      wait_cycles    = 0;
      error_wait_seen = 1'b0;
      while (HREADYOUT !== 1'b1) begin
        if (HRESP == HRESP_ERROR)
          error_wait_seen = 1'b1;
        wait_cycles = wait_cycles + 1;
        @(negedge HCLK);
      end

      read_data = HRDATA;
      response  = HRESP;

      // Complete the data phase before starting another transfer.
      @(posedge HCLK);
      @(negedge HCLK);
      HWDATA = 32'b0;
    end
  endtask

  task automatic ahb_write;
    input  logic [31:0] address;
    input  logic [2:0]  size;
    input  logic [31:0] data;
    output logic [1:0]  response;
    output integer      wait_cycles;
    output logic        error_wait_seen;
    logic [31:0] unused_read_data;
    begin
      ahb_transfer(1'b1, address, size, data, unused_read_data, response,
                   wait_cycles, error_wait_seen);
    end
  endtask

  task automatic ahb_read;
    input  logic [31:0] address;
    input  logic [2:0]  size;
    output logic [31:0] data;
    output logic [1:0]  response;
    output integer      wait_cycles;
    output logic        error_wait_seen;
    begin
      ahb_transfer(1'b0, address, size, 32'b0, data, response,
                   wait_cycles, error_wait_seen);
    end
  endtask

  task automatic wait_for_config;
    integer timeout;
    begin
      timeout = 0;
      while ((dut.config_count != 3) && (timeout < 40)) begin
        @(negedge HCLK);
        timeout = timeout + 1;
      end
      checks = checks + 1;
      if (dut.config_count != 3) begin
        failures = failures + 1;
        $display("FAIL: configuration did not complete");
      end else begin
        $display("PASS: three configuration writes processed");
      end
    end
  endtask

  task automatic wait_for_response;
    input string label_text;
    integer timeout;
    begin
      timeout = 0;
      while (dut.response_empty && (timeout < 1000)) begin
        @(negedge HCLK);
        timeout = timeout + 1;
      end
      checks = checks + 1;
      if (dut.response_empty) begin
        failures = failures + 1;
        $display("FAIL: timeout waiting for %s", label_text);
      end else begin
        $display("PASS: response available for %s after %0d cycles",
                 label_text, timeout);
      end
    end
  endtask

  initial begin
    logic [31:0] read_data;
    logic [1:0]  response;
    logic        error_wait_seen;
    integer      wait_cycles;
    integer      max_wait_cycles;
    integer      i;

    HCLK       = 1'b0;
    HRESETn    = 1'b0;
    HSEL       = 1'b0;
    HADDR      = 32'b0;
    HTRANS     = HTRANS_IDLE;
    HWRITE     = 1'b0;
    HSIZE      = HSIZE_WORD;
    HBURST     = 3'b000;
    HPROT      = 4'b0011;
    HMASTER    = 4'd1;
    HMASTLOCK  = 1'b0;
    HWDATA     = 32'b0;
    i_scan_si1 = 1'b0;
    i_scan_se1 = 1'b0;
    i_TM       = 1'b0;
    failures   = 0;
    checks     = 0;

    repeat (4) @(posedge HCLK);
    @(negedge HCLK);
    HRESETn = 1'b1;
    repeat (2) @(posedge HCLK);
    @(negedge HCLK);

    check_bit(HREADYOUT, 1'b1, "AHB ready after reset");
    check_word({30'b0, HRESP}, {30'b0, HRESP_OKAY},
               "AHB OKAY response after reset");

    $display("\n=== TEST 1: FRAME PACKING AND IDLE BUS ===");
    check_word(command_word(MODE_SET, 9'd0, 9'd0,
                            1'b0, 1'b0, 1'b0, 8'h01),
               32'hC000_0001, "SET command frame at row 0 column 0");
    check_word(command_word(MODE_READ, 9'd511, 9'd511,
                            1'b0, 1'b0, 1'b0, 8'h07),
               32'h7FFF_F007, "READ command frame at row 511 column 511");
    check_word(expected_result(MODE_READ, 9'd511, 14'h0116),
               32'h00FF_C116, "READ result frame packing example");
    repeat (3) @(posedge HCLK);
    @(negedge HCLK);
    check_bit(dut.command_empty, 1'b1,
              "idle bus does not create a command");

    $display("\n=== TEST 2: THREE CONFIGURATION WRITES ===");
    // Configuration packet 0: SET thresholds both 0x0100.
    ahb_write(X2_ADDR, HSIZE_WORD, 32'h0100_0100,
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "configuration write 0 response");

    // Configuration packet 1: RESET thresholds both 0x0020.
    ahb_write(X2_ADDR, HSIZE_WORD, 32'h0020_0020,
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "configuration write 1 response");

    // Configuration packet 2: dead time=1, timeout=max, counters=1.
    ahb_write(X2_ADDR, HSIZE_WORD, 32'h43F0_0401,
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "configuration write 2 response");
    wait_for_config();

    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "empty read AHB response");
    check_word(read_data, 32'hA000_0000, "empty result FIFO value");

    $display("\n=== TEST 3: BASIC MINIMUM-ADDRESS OPERATIONS ===");
    // The simplest functional example uses row 0 and column 0.  SET PWM 1
    // programs level 0x0101.  A READ with PWM 0 returns that same count.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd0, 9'd0,
                           1'b0, 1'b0, 1'b0, 8'd1),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "basic SET command AHB response");
    wait_for_response("basic SET row 0 column 0");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "basic SET result AHB response");
    check_word(read_data, expected_result(MODE_SET, 9'd0, 14'h0101),
               "basic SET automatic readback");

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_READ, 9'd0, 9'd0,
                           1'b0, 1'b0, 1'b0, 8'd0),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "basic READ command AHB response");
    wait_for_response("basic READ row 0 column 0");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "basic READ result AHB response");
    check_word(read_data, expected_result(MODE_READ, 9'd0, 14'h0101),
               "basic READ result");

    // A one-packet COMPUTE sets bit 9 in the same command that supplies the
    // selected row, column, and PWM.  One programmed row with PWM 6 gives 6.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd0, 9'd0,
                           1'b0, 1'b0, 1'b1, 8'd6),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "basic COMPUTE command AHB response");
    wait_for_response("basic one-packet COMPUTE");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "basic COMPUTE result AHB response");
    check_word(read_data, expected_result(MODE_COMPUTE, 9'd0, 14'd6),
               "basic one-row COMPUTE result");
    check_bit(dut.response_empty, 1'b1,
              "basic COMPUTE generated one result");

    $display("\n=== TEST 4: SET, READ, AND RESET SEQUENCE ===");
    // SET row 2, column 3, PWM 5.  Expected level is 0x0105.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd2, 9'd3, 1'b0, 1'b0, 1'b0, 8'd5),
              response, wait_cycles, error_wait_seen);
    wait_for_response("SET readback");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_SET, 9'd3, 14'h0105),
               "SET automatic readback");

    // READ the programmed cell with PWM 7: 0x0105 + 7 = 0x010c.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_READ, 9'd2, 9'd3, 1'b0, 1'b0, 1'b0, 8'd7),
              response, wait_cycles, error_wait_seen);
    wait_for_response("READ result");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_READ, 9'd3, 14'h010C),
               "READ result word");

    // RESET row 2, column 3, PWM 2.  Automatic readback reuses previous
    // read PWM 7: reset level 0x0022 + 7 = 0x0029.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_RESET, 9'd2, 9'd3,
                           1'b0, 1'b0, 1'b0, 8'd2),
              response, wait_cycles, error_wait_seen);
    wait_for_response("RESET readback");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_RESET, 9'd3, 14'h0029),
               "RESET automatic readback");

    $display("\n=== TEST 5: MULTI-ROW AND MULTI-COLUMN COMPUTE ===");
    // Program two cells used by a two-row COMPUTE burst.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd0, 9'd5,
                           1'b0, 1'b0, 1'b0, 8'd10),
              response, wait_cycles, error_wait_seen);
    wait_for_response("SET row 0 column 5");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_SET, 9'd5, 14'h0111),
               "SET row 0 readback");

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd1, 9'd5,
                           1'b0, 1'b0, 1'b0, 8'd20),
              response, wait_cycles, error_wait_seen);
    wait_for_response("SET row 1 column 5");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_SET, 9'd5, 14'h011B),
               "SET row 1 readback");

    // COMPUTE row 0 PWM 3, then row 1 PWM 4 with final marker bit 9.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd0, 9'd5,
                           1'b0, 1'b0, 1'b0, 8'd3),
              response, wait_cycles, error_wait_seen);
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd1, 9'd5,
                           1'b0, 1'b0, 1'b1, 8'd4),
              response, wait_cycles, error_wait_seen);
    wait_for_response("COMPUTE result");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_COMPUTE, 9'd5, 14'd7),
               "two-row COMPUTE result");

    // Add a programmed cell in a second column.  The following two COMPUTE
    // packets select rows 0 and 1 and unique columns 5 and 6.  Results are
    // returned in ascending global-column order.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd1, 9'd6,
                           1'b0, 1'b0, 1'b0, 8'd30),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "second-column SET command AHB response");
    wait_for_response("SET row 1 column 6");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "second-column SET result AHB response");
    check_word(read_data, expected_result(MODE_SET, 9'd6, 14'h0125),
               "SET row 1 column 6 readback");

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd0, 9'd5,
                           1'b0, 1'b0, 1'b0, 8'd3),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "multi-column COMPUTE packet 0 response");
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd1, 9'd6,
                           1'b0, 1'b0, 1'b1, 8'd4),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "multi-column COMPUTE final packet response");
    wait_for_response("two-column COMPUTE results");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "column 5 COMPUTE read response");
    check_word(read_data, expected_result(MODE_COMPUTE, 9'd5, 14'd7),
               "multi-column COMPUTE result column 5");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "column 6 COMPUTE read response");
    check_word(read_data, expected_result(MODE_COMPUTE, 9'd6, 14'd4),
               "multi-column COMPUTE result column 6");
    check_bit(dut.response_empty, 1'b1,
              "multi-column COMPUTE generated two results");

    $display("\n=== TEST 6: MAXIMUM 9-BIT ADDRESS ===");
    // Exercise the other end of the 9-bit address range.  SET PWM 15 creates
    // level 0x010F; automatic readback and explicit READ both add the retained
    // READ PWM 7, producing 0x0116.  A one-row COMPUTE returns PWM 8.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd511, 9'd511,
                           1'b0, 1'b0, 1'b0, 8'd15),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "maximum-address SET command AHB response");
    wait_for_response("SET row 511 column 511");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "maximum-address SET result AHB response");
    check_word(read_data, expected_result(MODE_SET, 9'd511, 14'h0116),
               "maximum-address SET readback");

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_READ, 9'd511, 9'd511,
                           1'b0, 1'b0, 1'b0, 8'd7),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "maximum-address READ command AHB response");
    wait_for_response("READ row 511 column 511");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "maximum-address READ result AHB response");
    check_word(read_data, expected_result(MODE_READ, 9'd511, 14'h0116),
               "maximum-address READ result");

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd511, 9'd511,
                           1'b0, 1'b0, 1'b1, 8'd8),
              response, wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "maximum-address COMPUTE command AHB response");
    wait_for_response("COMPUTE row 511 column 511");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_OKAY},
               "maximum-address COMPUTE result AHB response");
    check_word(read_data, expected_result(MODE_COMPUTE, 9'd511, 14'd8),
               "maximum-address COMPUTE result");
    check_bit(dut.response_empty, 1'b1,
              "maximum-address COMPUTE generated one result");

    $display("\n=== TEST 7: COMPUTE-ALL CBA BOUNDARIES ===");
    // Verify the exact horizontal CBA boundary: requested column 31 selects
    // global columns 0:31, while requested column 32 selects columns 32:63.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd0, 9'd31,
                           1'b0, 1'b1, 1'b1, 8'd2),
              response, wait_cycles, error_wait_seen);
    wait_for_response("compute-all bank selected by column 31");
    for (i = 0; i <= 31; i = i + 1) begin
      ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
               wait_cycles, error_wait_seen);
      check_word(read_data,
                 expected_result(MODE_COMPUTE, i[8:0],
                                 ((i == 0) || (i == 5)) ? 14'd2 : 14'd0),
                 "column 31 selects bank 0:31");
    end

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd0, 9'd32,
                           1'b0, 1'b1, 1'b1, 8'd2),
              response, wait_cycles, error_wait_seen);
    wait_for_response("compute-all bank selected by column 32");
    for (i = 32; i <= 63; i = i + 1) begin
      ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
               wait_cycles, error_wait_seen);
      check_word(read_data, expected_result(MODE_COMPUTE, i[8:0], 14'd0),
                 "column 32 selects bank 32:63");
    end
    check_bit(dut.response_empty, 1'b1,
              "boundary compute-all operations returned 32 results each");

    $display("\n=== TEST 8: MID-RANGE 9-BIT ADDRESS AND COMPUTE-ALL ===");
    // Exercise the widened address fields above the old 32x32 range.
    // Row 300 / column 68 belongs to vertical CBA 9 and horizontal CBA 2.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_SET, 9'd300, 9'd68,
                           1'b0, 1'b0, 1'b0, 8'd10),
              response, wait_cycles, error_wait_seen);
    wait_for_response("SET row 300 column 68");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_SET, 9'd68, 14'h0111),
               "9-bit row/column SET readback");

    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_READ, 9'd300, 9'd68,
                           1'b0, 1'b0, 1'b0, 8'd1),
              response, wait_cycles, error_wait_seen);
    wait_for_response("READ row 300 column 68");
    ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word(read_data, expected_result(MODE_READ, 9'd68, 14'h010B),
               "9-bit row/column READ result");

    // Compute-all for requested column 68 must select horizontal CBA bank 2
    // and return exactly the 32 global columns 64 through 95.  Only column 68
    // is programmed in selected row 300, so its compute count is 9.
    ahb_write(X2_ADDR, HSIZE_WORD,
              command_word(MODE_COMPUTE, 9'd300, 9'd68,
                           1'b0, 1'b1, 1'b1, 8'd9),
              response, wait_cycles, error_wait_seen);
    wait_for_response("CBA-bank compute-all results");
    for (i = 64; i <= 95; i = i + 1) begin
      ahb_read(X2_ADDR, HSIZE_WORD, read_data, response,
               wait_cycles, error_wait_seen);
      check_word(read_data,
                 expected_result(MODE_COMPUTE, i[8:0],
                                 (i == 68) ? 14'd9 : 14'd0),
                 "compute-all bank 64:95 result");
    end
    check_bit(dut.response_empty, 1'b1,
              "compute-all generated exactly 32 results");

    $display("\n=== TEST 9: AHB ERROR RESPONSES ===");
    // Unsupported sizes and addresses must generate the two-bit AHB ERROR
    // response, with the first ERROR cycle held in a wait state.
    ahb_read(X2_ADDR, HSIZE_BYTE, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_ERROR},
               "byte access ERROR response");
    check_bit(error_wait_seen, 1'b1, "byte access two-cycle ERROR");

    ahb_read(X2_ADDR + 32'd4, HSIZE_WORD, read_data, response,
             wait_cycles, error_wait_seen);
    check_word({30'b0, response}, {30'b0, HRESP_ERROR},
               "invalid address ERROR response");
    check_bit(error_wait_seen, 1'b1, "invalid address two-cycle ERROR");

    $display("\n=== TEST 10: COMMAND FIFO BACKPRESSURE ===");
    // Flood slow SET commands to prove that a full command FIFO stalls AHB
    // through HREADYOUT and subsequently resumes without dropping the write.
    max_wait_cycles = 0;
    for (i = 0; i < 40; i = i + 1) begin
      ahb_write(X2_ADDR, HSIZE_WORD,
                command_word(MODE_SET, (i & 9'h1ff),
                             ((i + 7) & 9'h1ff),
                             1'b0, 1'b0, 1'b0, (i & 8'hff)),
                response, wait_cycles, error_wait_seen);
      if (wait_cycles > max_wait_cycles)
        max_wait_cycles = wait_cycles;
      if (response != HRESP_OKAY) begin
        failures = failures + 1;
        $display("FAIL: backpressure write %0d response=%b", i, response);
      end
    end
    checks = checks + 1;
    if (max_wait_cycles <= 1) begin
      failures = failures + 1;
      $display("FAIL: FIFO backpressure was not observed; max wait=%0d",
               max_wait_cycles);
    end else begin
      $display("PASS: FIFO backpressure observed; max wait=%0d cycles",
               max_wait_cycles);
    end

    if (failures == 0) begin
      $display("TEST_PASS: %0d checks completed", checks);
    end else begin
      $display("TEST_FAIL: %0d failures across %0d checks", failures, checks);
    end

    $finish;
  end

endmodule
