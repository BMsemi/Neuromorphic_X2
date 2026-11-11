`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Behavioral model for the September 2026 V2 RTL.
//
// This model keeps the external interface of the previous
// Neuromorphic_X2_wb_beh model, but follows the firmware-visible behavior of
// the RTL in this directory:
//
//   * Wishbone data register address is 32'h3000_0004.
//   * The first three accepted writes after reset are configuration words.
//   * There is no runtime configuration-restart packet in the V2 RTL.
//   * Command format after configuration:
//       [31:30] mode: 00=RESET, 01=READ, 10=COMPUTE, 11=SET
//       [29:25] row
//       [24:20] column
//       [19]    return FSM error/status on Wishbone reads
//       [18]    COMPUTE: request all 32 result columns
//       [17]    COMPUTE: final packet / launch marker
//       [16:8]  reserved
//       [7:0]   PWM value
//   * COMPUTE accumulates 1 through 32 packets.  It launches when bit 17 is
//     set or when packet 32 is accepted.  A non-COMPUTE command discards a
//     partial COMPUTE burst, matching Wb_slave.sv.
//   * Result FIFO words match the V2 21-bit TDC result format:
//       [31:21] 11'b0
//       [20:19] operation mode
//       [18:14] column/channel
//       [13:0]  coarse/fine TDC value
//   * An empty Wishbone read returns 32'hA000_0000 immediately.
//   * SET and RESET each generate one automatic readback result.
//   * COMPUTE returns one result for each unique selected column, in ascending
//     column order.  Bit 18 changes the result mask to all 32 columns.
//
// The analog memory/TDC response is represented deterministically by
// cell_level[] and array_state[].  It is suitable for digital/AMS control-path
// verification; extracted post-layout TDC accuracy must still be verified with
// the physical implementation and extracted parasitics.
// -----------------------------------------------------------------------------

module Neuromorphic_X2_wb_beh #(
  parameter logic [31:0] ADDR_MATCH         = 32'h3000_0004,
  parameter integer      READ_DELAY         = 160,
  parameter integer      PROGRAM_DELAY      = 360,
  parameter integer      COMPUTE_DELAY      = 450,
  parameter integer      CONFIG_WRITES      = 3,
  parameter logic [13:0] INITIAL_CELL_LEVEL = 14'h0E23
)(
  input  logic        wb_clk_i,
  input  logic        wb_rst_i,
  input  logic        wbs_stb_i,
  input  logic        wbs_cyc_i,
  input  logic        wbs_we_i,
  input  logic [3:0]  wbs_sel_i,
  input  logic [31:0] wbs_dat_i,
  input  logic [31:0] wbs_adr_i,
  output logic [31:0] wbs_dat_o,
  output logic        wbs_ack_o,

  input  logic        i_scan_si1,
  input  logic        i_scan_se1,
  input  logic        i_TM,
  output wire         o_TM,
  output logic [1:0]  o_mux_sel,
  output logic [31:0] o_sl_float,
  output logic [31:0] o_sl_addr,
  output logic [31:0] o_sl_data,
  output logic [31:0] o_bl_addr,
  output logic [31:0] o_bl_data,
  output logic [31:0] o_bl_float,
  output logic [31:0] o_wl_float,
  output logic [31:0] o_wl_addr,
  output logic [31:0] o_wl_data
);

  localparam logic [1:0] MODE_RESET   = 2'b00;
  localparam logic [1:0] MODE_READ    = 2'b01;
  localparam logic [1:0] MODE_COMPUTE = 2'b10;
  localparam logic [1:0] MODE_SET     = 2'b11;

  localparam logic [2:0] STATUS_OK              = 3'b000;
  localparam logic [2:0] STATUS_READ_TIMEOUT    = 3'b001;
  localparam logic [2:0] STATUS_SET_FAILED      = 3'b011;
  localparam logic [2:0] STATUS_COMPUTE_TIMEOUT = 3'b100;
  localparam logic [2:0] STATUS_RESET_FAILED    = 3'b101;

  integer r;
  integer c;
  integer scan_i;

  // Abstract 32x32 memory state.
  logic [31:0] array_state [0:31];
  logic [13:0] cell_level  [0:1023];

  // Wishbone command FIFO and result FIFO.  Pointer plus wrap-bit behavior
  // mirrors the depth-32 synchronous FIFOs in Wb_slave.sv.
  logic [31:0] command_q  [0:31];
  logic [31:0] response_q [0:31];

  logic [4:0] command_wr_idx;
  logic       command_wr_wrap;
  logic [4:0] command_rd_idx;
  logic       command_rd_wrap;

  logic [4:0] response_wr_idx;
  logic       response_wr_wrap;
  logic [4:0] response_rd_idx;
  logic       response_rd_wrap;

  // Configuration registers from the first three packets.
  logic [15:0] target_set1;
  logic [15:0] target_set2;
  logic [15:0] target_reset1;
  logic [15:0] target_reset2;
  logic [9:0]  no_of_clk_cycles;
  logic [9:0]  counter_value;
  logic [6:0]  tdc_time_out;
  logic [1:0]  tdc_dead_time;
  integer      config_count;

  // Error/status read selection follows Wb_slave.rd_err_addr.
  logic [2:0] status_code;
  logic       error_read_enable;
  logic [7:0] previous_read_pwm;

  // V2 variable-length COMPUTE packet accumulator.
  logic [31:0] compute_row_mask;
  logic [31:0] compute_col_mask;
  logic        compute_full_column;
  logic [7:0]  compute_pwm_by_row [0:31];
  integer      compute_packet_count;

  // A compact approximation of the active functional decoder controls.
  logic        functional_active;
  logic [1:0]  functional_mode;
  logic [31:0] functional_row_mask;
  logic [31:0] functional_col_mask;

  // Scan/debug state copied from the current top_module.sv/ScanDebug.v flow.
  logic [15:0] scan_shift;
  logic [15:0] scan_word;
  logic        scan_word_valid;
  logic        scan_in_progress;
  logic [4:0]  scan_bit_count;
  logic        scan_op_set;
  logic [4:0]  scan_sl_sel;
  logic [4:0]  scan_bl_sel;
  logic [4:0]  scan_wl_sel;
  logic        scan_op_set_d;
  logic [4:0]  scan_sl_sel_d;
  logic [4:0]  scan_bl_sel_d;
  logic [4:0]  scan_wl_sel_d;

  wire selected;
  wire scan_test_mode;
  wire command_empty;
  wire command_full;
  wire response_empty;
  wire response_full;

  assign selected = wbs_stb_i && wbs_cyc_i &&
                    (wbs_sel_i == 4'hF) &&
                    (wbs_adr_i == ADDR_MATCH);

  // Case equality makes omitted named ports safely inactive.
  assign scan_test_mode = (i_TM === 1'b1);
  assign o_TM = scan_test_mode;

  assign command_empty = (command_wr_idx == command_rd_idx) &&
                         (command_wr_wrap == command_rd_wrap);
  assign command_full  = (command_wr_idx == command_rd_idx) &&
                         (command_wr_wrap != command_rd_wrap);

  assign response_empty = (response_wr_idx == response_rd_idx) &&
                          (response_wr_wrap == response_rd_wrap);
  assign response_full  = (response_wr_idx == response_rd_idx) &&
                          (response_wr_wrap != response_rd_wrap);

  function automatic [9:0] cell_index;
    input logic [4:0] row_index;
    input logic [4:0] col_index;
    begin
      cell_index = {row_index, col_index};
    end
  endfunction

  function automatic [31:0] onehot5;
    input logic [4:0] index;
    begin
      onehot5 = 32'b0;
      onehot5[index] = 1'b1;
    end
  endfunction

  function automatic [13:0] target_midpoint;
    input logic [15:0] target_a;
    input logic [15:0] target_b;
    logic [16:0] sum;
    begin
      sum = {1'b0, target_a} + {1'b0, target_b};
      target_midpoint = sum[14:1];
    end
  endfunction

  function automatic [13:0] programmed_level;
    input logic       set_cell;
    input logic [7:0] program_value;
    logic [14:0] value;
    begin
      if (set_cell)
        value = {1'b0, target_midpoint(target_set1, target_set2)} +
                {7'd0, program_value};
      else
        value = {1'b0, target_midpoint(target_reset1, target_reset2)} +
                {7'd0, program_value};

      programmed_level = value[13:0];
    end
  endfunction

  function automatic [13:0] timeout_ceiling;
    begin
      timeout_ceiling = {tdc_time_out[5:0], 8'hFF};
    end
  endfunction

  function automatic [13:0] clamp_count;
    input logic [16:0] raw_count;
    logic [13:0] ceiling;
    begin
      ceiling = timeout_ceiling();
      if (raw_count > {3'b0, ceiling})
        clamp_count = ceiling;
      else
        clamp_count = raw_count[13:0];
    end
  endfunction

  function automatic [13:0] cell_value;
    input logic [4:0] row_index;
    input logic [4:0] col_index;
    input logic [7:0] pwm_value;
    logic [16:0] raw_count;
    begin
      raw_count = {3'b0, cell_level[cell_index(row_index, col_index)]} +
                  {9'b0, pwm_value};
      cell_value = clamp_count(raw_count);
    end
  endfunction

  // Exact V2 Wishbone result layout: zero extension of cnt_top.o_tdc_cnt.
  function automatic [31:0] result_word;
    input logic [1:0]  mode;
    input logic [4:0]  col_index;
    input logic [13:0] value;
    begin
      result_word = {11'b0, mode, col_index, value};
    end
  endfunction

  task automatic wait_cycles_or_reset;
    input integer cycles;
    integer n;
    begin
      n = 0;
      while ((n < cycles) && !wb_rst_i) begin
        @(posedge wb_clk_i or posedge wb_rst_i);
        if (!wb_rst_i)
          n = n + 1;
      end
    end
  endtask

  task automatic advance_command_read;
    begin
      if (command_rd_idx == 5'd31) begin
        command_rd_idx  = 5'd0;
        command_rd_wrap = ~command_rd_wrap;
      end else begin
        command_rd_idx = command_rd_idx + 5'd1;
      end
    end
  endtask

  task automatic advance_response_write;
    begin
      if (response_wr_idx == 5'd31) begin
        response_wr_idx  = 5'd0;
        response_wr_wrap = ~response_wr_wrap;
      end else begin
        response_wr_idx = response_wr_idx + 5'd1;
      end
    end
  endtask

  task automatic push_response;
    input logic [31:0] value;
    begin
      while (response_full && !wb_rst_i)
        @(posedge wb_clk_i or posedge wb_rst_i);

      if (!wb_rst_i) begin
        response_q[response_wr_idx] = value;
        advance_response_write();
      end
    end
  endtask

  task automatic clear_compute_state;
    integer row;
    begin
      compute_row_mask     = 32'b0;
      compute_col_mask     = 32'b0;
      compute_full_column  = 1'b0;
      compute_packet_count = 0;
      for (row = 0; row < 32; row = row + 1)
        compute_pwm_by_row[row] = 8'b0;
    end
  endtask

  task automatic apply_config;
    input logic [31:0] packet;
    begin
      case (config_count)
        0: begin
          target_set1 = packet[15:0];
          target_set2 = packet[31:16];
        end

        1: begin
          target_reset1 = packet[15:0];
          target_reset2 = packet[31:16];
        end

        2: begin
          no_of_clk_cycles = packet[9:0];
          counter_value    = packet[19:10];
          tdc_time_out     = packet[26:20];
          tdc_dead_time    = packet[31:30];
        end

        default: begin
        end
      endcase

      config_count = config_count + 1;

      // Establish a deterministic reset-state read level after the complete
      // configuration triplet.  The physical array remains an analog model.
      if (config_count == CONFIG_WRITES) begin
        for (r = 0; r < 32; r = r + 1) begin
          for (c = 0; c < 32; c = c + 1)
            cell_level[cell_index(r[4:0], c[4:0])] =
                programmed_level(1'b0, 8'h00);
        end
      end

      status_code = STATUS_OK;
    end
  endtask

  task automatic execute_read;
    input logic [31:0] packet;
    logic [4:0] row_index;
    logic [4:0] col_index;
    begin
      row_index = packet[29:25];
      col_index = packet[24:20];

      clear_compute_state();
      previous_read_pwm  = packet[7:0];
      error_read_enable  = packet[19];
      functional_active  = 1'b1;
      functional_mode    = MODE_READ;
      functional_row_mask = onehot5(row_index);
      functional_col_mask = onehot5(col_index);

      wait_cycles_or_reset(READ_DELAY);

      if (!wb_rst_i) begin
        push_response(result_word(MODE_READ,
                                  col_index,
                                  cell_value(row_index,
                                             col_index,
                                             packet[7:0])));
        status_code = STATUS_OK;
      end

      functional_active = 1'b0;
    end
  endtask

  task automatic execute_program;
    input logic [31:0] packet;
    input logic        set_cell;
    logic [4:0] row_index;
    logic [4:0] col_index;
    logic [1:0] response_mode;
    begin
      row_index    = packet[29:25];
      col_index    = packet[24:20];
      response_mode = set_cell ? MODE_SET : MODE_RESET;

      clear_compute_state();
      error_read_enable   = packet[19];
      functional_active   = 1'b1;
      functional_mode     = response_mode;
      functional_row_mask = onehot5(row_index);
      functional_col_mask = onehot5(col_index);

      wait_cycles_or_reset(PROGRAM_DELAY + int'(no_of_clk_cycles));

      if (!wb_rst_i) begin
        array_state[row_index][col_index] = set_cell;
        cell_level[cell_index(row_index, col_index)] =
            programmed_level(set_cell, packet[7:0]);

        // The RTL automatically enters a READ phase after SET/RESET and writes
        // exactly one TDC result for the programmed column.
        push_response(result_word(response_mode,
                                  col_index,
                                  cell_value(row_index,
                                             col_index,
                                             previous_read_pwm)));
        status_code = STATUS_OK;
      end

      functional_active = 1'b0;
    end
  endtask

  task automatic push_compute_column;
    input logic [4:0] col_index;
    integer row;
    logic [16:0] accumulated_value;
    begin
      accumulated_value = 17'b0;

      for (row = 0; row < 32; row = row + 1) begin
        if (compute_row_mask[row] && array_state[row][col_index])
          accumulated_value = accumulated_value +
                              {9'b0, compute_pwm_by_row[row]};
      end

      push_response(result_word(MODE_COMPUTE,
                                col_index,
                                clamp_count(accumulated_value)));
    end
  endtask

  task automatic launch_compute;
    integer col;
    logic [31:0] result_mask;
    begin
      result_mask = compute_full_column ? 32'hFFFF_FFFF : compute_col_mask;

      functional_active   = 1'b1;
      functional_mode     = MODE_COMPUTE;
      functional_row_mask = compute_row_mask;
      functional_col_mask = result_mask;

      wait_cycles_or_reset(COMPUTE_DELAY);

      if (!wb_rst_i) begin
        // cnt_top returns the lowest-numbered valid channel first.  Clearing
        // each channel produces ascending unique-column order.
        for (col = 0; col < 32; col = col + 1) begin
          if (result_mask[col])
            push_compute_column(col[4:0]);
        end
        status_code = STATUS_OK;
      end

      functional_active = 1'b0;
      clear_compute_state();
    end
  endtask

  task automatic accept_compute_packet;
    input logic [31:0] packet;
    logic [4:0] row_index;
    logic [4:0] col_index;
    logic       launch_now;
    begin
      row_index = packet[29:25];
      col_index = packet[24:20];
      launch_now = packet[17] || (compute_packet_count == 31);

      error_read_enable = packet[19];
      compute_row_mask[row_index] = 1'b1;
      compute_pwm_by_row[row_index] = packet[7:0];

      if (packet[18]) begin
        compute_full_column = 1'b1;
        compute_col_mask = 32'hFFFF_FFFF;
      end else if (!compute_full_column) begin
        compute_col_mask[col_index] = 1'b1;
      end

      if (launch_now) begin
        compute_packet_count = compute_packet_count + 1;
        launch_compute();
      end else begin
        compute_packet_count = compute_packet_count + 1;
        status_code = STATUS_OK;
      end
    end
  endtask

  task automatic execute_packet;
    input logic [31:0] packet;
    begin
      if (config_count < CONFIG_WRITES) begin
        apply_config(packet);
      end else begin
        case (packet[31:30])
          MODE_READ:    execute_read(packet);
          MODE_SET:     execute_program(packet, 1'b1);
          MODE_RESET:   execute_program(packet, 1'b0);
          MODE_COMPUTE: accept_compute_packet(packet);
          default: begin
            status_code = STATUS_READ_TIMEOUT;
          end
        endcase
      end
    end
  endtask

  task automatic reset_model_state;
    begin
      for (r = 0; r < 32; r = r + 1) begin
        array_state[r] = 32'b0;
        compute_pwm_by_row[r] = 8'b0;
        for (c = 0; c < 32; c = c + 1)
          cell_level[cell_index(r[4:0], c[4:0])] = INITIAL_CELL_LEVEL;
      end

      command_rd_idx      = 5'd0;
      command_rd_wrap     = 1'b0;
      response_wr_idx     = 5'd0;
      response_wr_wrap    = 1'b0;

      target_set1         = 16'hC40F;
      target_set2         = 16'hA203;
      target_reset1       = 16'h0D43;
      target_reset2       = 16'h0F03;
      no_of_clk_cycles    = 10'd3;
      counter_value       = 10'd3;
      tdc_time_out        = 7'd32;
      tdc_dead_time       = 2'b01;
      config_count        = 0;

      status_code         = STATUS_OK;
      error_read_enable   = 1'b0;
      previous_read_pwm   = 8'b0;

      compute_row_mask     = 32'b0;
      compute_col_mask     = 32'b0;
      compute_full_column  = 1'b0;
      compute_packet_count = 0;

      functional_active    = 1'b0;
      functional_mode      = MODE_RESET;
      functional_row_mask  = 32'b0;
      functional_col_mask  = 32'b0;
    end
  endtask

  // Wishbone slave interface.
  always_ff @(posedge wb_clk_i or posedge wb_rst_i) begin
    if (wb_rst_i) begin
      wbs_ack_o        <= 1'b0;
      wbs_dat_o        <= 32'b0;
      command_wr_idx   <= 5'd0;
      command_wr_wrap  <= 1'b0;
      response_rd_idx  <= 5'd0;
      response_rd_wrap <= 1'b0;
    end else begin
      wbs_ack_o <= 1'b0;

      if (selected && wbs_we_i && !wbs_ack_o) begin
        if (!command_full) begin
          command_q[command_wr_idx] <= wbs_dat_i;

          if (command_wr_idx == 5'd31) begin
            command_wr_idx  <= 5'd0;
            command_wr_wrap <= ~command_wr_wrap;
          end else begin
            command_wr_idx <= command_wr_idx + 5'd1;
          end

          wbs_ack_o <= 1'b1;
        end
      end else if (selected && !wbs_we_i && !wbs_ack_o) begin
        if (error_read_enable) begin
          wbs_dat_o <= {29'b0, status_code};
          wbs_ack_o <= 1'b1;
        end else if (response_empty) begin
          wbs_dat_o <= 32'hA000_0000;
          wbs_ack_o <= 1'b1;
        end else begin
          wbs_dat_o <= response_q[response_rd_idx];

          if (response_rd_idx == 5'd31) begin
            response_rd_idx  <= 5'd0;
            response_rd_wrap <= ~response_rd_wrap;
          end else begin
            response_rd_idx <= response_rd_idx + 5'd1;
          end

          wbs_ack_o <= 1'b1;
        end
      end
    end
  end

  // Sequential command executor.  The Wishbone command FIFO remains able to
  // accept writes while an operation delay is in progress.
  initial begin
    reset_model_state();

    forever begin
      @(posedge wb_clk_i or posedge wb_rst_i);

      if (wb_rst_i) begin
        reset_model_state();
      end else if (!command_empty) begin
        execute_packet(command_q[command_rd_idx]);
        if (!wb_rst_i)
          advance_command_read();
      end
    end
  end

  // Scan shift/capture behavior from the latest top_module.sv.
  always_ff @(posedge wb_clk_i) begin
    if (wb_rst_i) begin
      scan_shift       <= 16'b0;
      scan_word        <= 16'b0;
      scan_word_valid  <= 1'b0;
      scan_in_progress <= 1'b0;
      scan_bit_count   <= 5'd0;
    end else begin
      scan_word_valid <= 1'b0;

      if ((i_scan_se1 === 1'b0) && !scan_test_mode) begin
        scan_in_progress <= 1'b0;
        scan_bit_count   <= 5'd0;
      end else if ((i_scan_se1 === 1'b0) && scan_test_mode) begin
        scan_shift <= {i_scan_si1, scan_shift[15:1]};

        if (!scan_in_progress) begin
          scan_in_progress <= 1'b1;
          scan_bit_count   <= 5'd0;
        end else begin
          scan_bit_count <= scan_bit_count + 5'd1;
        end

        if (scan_bit_count == 5'd16) begin
          scan_word        <= scan_shift;
          scan_word_valid  <= 1'b1;
          scan_in_progress <= 1'b0;
          scan_bit_count   <= 5'd0;
        end
      end
    end
  end

  always_ff @(posedge wb_clk_i) begin
    if (wb_rst_i) begin
      scan_op_set   <= 1'b0;
      scan_sl_sel   <= 5'd0;
      scan_bl_sel   <= 5'd0;
      scan_wl_sel   <= 5'd0;
      scan_op_set_d <= 1'b0;
      scan_sl_sel_d <= 5'd0;
      scan_bl_sel_d <= 5'd0;
      scan_wl_sel_d <= 5'd0;
    end else begin
      if (scan_word_valid) begin
        scan_op_set <= scan_word[15];
        scan_sl_sel <= scan_word[14:10];
        scan_bl_sel <= scan_word[9:5];
        scan_wl_sel <= scan_word[4:0];
      end

      scan_op_set_d <= scan_op_set;
      scan_sl_sel_d <= scan_sl_sel;
      scan_bl_sel_d <= scan_bl_sel;
      scan_wl_sel_d <= scan_wl_sel;
    end
  end

  // Decoder-control abstraction.  Test mode exactly follows ScanDebug.v.
  // Functional mode exposes the selected row/column masks while an abstract
  // operation is active, without attempting transistor-level array behavior.
  always_comb begin
    o_wl_float = 32'hFFFF_FFFF;
    o_bl_float = 32'hFFFF_FFFF;
    o_sl_float = 32'hFFFF_FFFF;
    o_wl_data  = 32'b0;
    o_bl_data  = 32'b0;
    o_sl_data  = 32'b0;
    o_wl_addr  = 32'b0;
    o_bl_addr  = 32'b0;
    o_sl_addr  = 32'b0;
    o_mux_sel  = 2'b00;

    if (scan_test_mode) begin
      for (scan_i = 0; scan_i < 32; scan_i = scan_i + 1) begin
        o_wl_addr[scan_i]  = (scan_i == int'(scan_wl_sel_d));
        o_wl_float[scan_i] = ~o_wl_addr[scan_i];
        o_wl_data[scan_i]  = o_wl_addr[scan_i];

        o_bl_addr[scan_i]  = (scan_i == int'(scan_bl_sel_d));
        o_bl_float[scan_i] = ~o_bl_addr[scan_i];
        o_bl_data[scan_i]  = o_bl_addr[scan_i] ? scan_op_set_d : 1'b0;

        o_sl_addr[scan_i]  = (scan_i == int'(scan_sl_sel_d));
        o_sl_float[scan_i] = ~o_sl_addr[scan_i];
        o_sl_data[scan_i]  = o_sl_addr[scan_i] ? ~scan_op_set_d : 1'b0;
      end
    end else if (functional_active) begin
      o_wl_addr  = functional_row_mask;
      o_sl_addr  = functional_row_mask;
      o_bl_addr  = functional_col_mask;
      o_wl_float = ~functional_row_mask;
      o_sl_float = ~functional_row_mask;
      o_bl_float = ~functional_col_mask;

      case (functional_mode)
        MODE_READ,
        MODE_COMPUTE: begin
          o_mux_sel = 2'b11;
          o_sl_data = functional_row_mask;
          o_bl_data = functional_col_mask;
        end

        MODE_SET: begin
          o_mux_sel = 2'b01;
          o_wl_data = functional_row_mask;
          o_bl_data = functional_col_mask;
        end

        MODE_RESET: begin
          o_mux_sel = 2'b10;
          o_wl_data = functional_row_mask;
          o_sl_data = functional_row_mask;
        end

        default: begin
          o_mux_sel = 2'b00;
        end
      endcase
    end
  end

endmodule

// Optional compatibility wrapper matching the old behavioral-model delivery.
// Define NEUROMORPHIC_X2_WB_BEH_AS_RTL only when the behavioral model should
// replace the RTL module named Neuromorphic_X2_wb.
`ifdef NEUROMORPHIC_X2_WB_BEH_AS_RTL
module Neuromorphic_X2_wb #(
  parameter logic [31:0] ADDR_MATCH         = 32'h3000_0004,
  parameter integer      READ_DELAY         = 160,
  parameter integer      PROGRAM_DELAY      = 360,
  parameter integer      COMPUTE_DELAY      = 450,
  parameter integer      CONFIG_WRITES      = 3,
  parameter logic [13:0] INITIAL_CELL_LEVEL = 14'h0E23
)(
  input  logic        wb_clk_i,
  input  logic        wb_rst_i,
  input  logic        wbs_stb_i,
  input  logic        wbs_cyc_i,
  input  logic        wbs_we_i,
  input  logic [3:0]  wbs_sel_i,
  input  logic [31:0] wbs_dat_i,
  input  logic [31:0] wbs_adr_i,
  output logic [31:0] wbs_dat_o,
  output logic        wbs_ack_o,
  input  logic        i_scan_si1,
  input  logic        i_scan_se1,
  input  logic        i_TM,
  output wire         o_TM,
  output logic [1:0]  o_mux_sel,
  output logic [31:0] o_sl_float,
  output logic [31:0] o_sl_addr,
  output logic [31:0] o_sl_data,
  output logic [31:0] o_bl_addr,
  output logic [31:0] o_bl_data,
  output logic [31:0] o_bl_float,
  output logic [31:0] o_wl_float,
  output logic [31:0] o_wl_addr,
  output logic [31:0] o_wl_data
);

  Neuromorphic_X2_wb_beh #(
    .ADDR_MATCH(ADDR_MATCH),
    .READ_DELAY(READ_DELAY),
    .PROGRAM_DELAY(PROGRAM_DELAY),
    .COMPUTE_DELAY(COMPUTE_DELAY),
    .CONFIG_WRITES(CONFIG_WRITES),
    .INITIAL_CELL_LEVEL(INITIAL_CELL_LEVEL)
  ) wb_black_box_i (
    .wb_clk_i(wb_clk_i),
    .wb_rst_i(wb_rst_i),
    .wbs_stb_i(wbs_stb_i),
    .wbs_cyc_i(wbs_cyc_i),
    .wbs_we_i(wbs_we_i),
    .wbs_sel_i(wbs_sel_i),
    .wbs_dat_i(wbs_dat_i),
    .wbs_adr_i(wbs_adr_i),
    .wbs_dat_o(wbs_dat_o),
    .wbs_ack_o(wbs_ack_o),
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

endmodule
`endif
