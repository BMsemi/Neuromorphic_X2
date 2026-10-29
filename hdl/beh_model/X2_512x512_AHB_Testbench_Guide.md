# X2 512 by 512 AHB Behavioral Model Testbench Guide

This guide describes the self-checking SystemVerilog testbench used to verify the 512 by 512 X2 AHB behavioral model. The testbench drives protocol-correct AHB address and data phases, checks returned data and responses automatically, verifies the new 9-bit addressing and frame formats, and exercises the depth-32 FIFO behavior.

# Testbench deliverable

| File | Purpose |
| --- | --- |
| `tb_Neuromorphic_X2_ahb_beh.sv` | Complete self-checking generic AHB testbench |

The testbench expects `../RTL/Neuromorphic_X2_ahb_beh.v` when compiled from the `TB` directory.

# Verification environment

The testbench instantiates `Neuromorphic_X2_ahb_beh` with its production delay defaults:

| Parameter | Test value |
| --- | ---: |
| X2 fixed address | `32'hE000_0004` |
| `CONFIG_WRITES` | `3` |
| `INITIAL_CELL_LEVEL` | `14'h0E23` |
| `READ_DELAY` | Default `160` |
| `PROGRAM_DELAY` | Default `360` |
| `COMPUTE_DELAY` | Default `450` |

It uses a 10 ns clock period. For this single-subordinate verification bus, `HREADYOUT` is fed back to global `HREADY`, matching the selected-subordinate response path that an AHB bus mux provides.

The AHB bus-functional model is deliberately non-pipelined for clarity, but it preserves the required AHB address/data phase separation and drives the model's native two-bit `HRESP` interface. During a write address phase it drives `32'hDEAD_BEEF` on `HWDATA`; the real command is driven only in the data phase. This detects a design that incorrectly samples write data with the address phase.

# What is verified

The regression contains 172 self-checking checks. The console output is divided into ten named test groups so a new user can follow the verification from simple frame construction through FIFO backpressure.

| Area | Verification performed |
| --- | --- |
| Reset | `HREADYOUT` is ready and `HRESP` is OKAY after reset |
| Frame packing | Known command and result fields are checked against complete 32-bit hexadecimal words |
| Idle bus | An idle, unselected AHB bus does not create a command |
| Configuration | Exactly three configuration words are accepted and processed |
| Empty read | Empty result FIFO returns `32'hA000_0000` |
| Minimum address | SET, READ, and one-packet COMPUTE are checked at row 0, column 0 |
| SET | Cell programming, AHB response, and automatic readback frame |
| READ | Programmed cell count plus READ PWM and AHB response |
| RESET | Cell reset and automatic readback frame |
| Normal COMPUTE | One-row, two-row, and two-column COMPUTE operations |
| Result ordering | A two-column COMPUTE returns global columns 5 and 6 in ascending order |
| New frame format | Commands use row `29:21`, column `20:12`, compute-all bit 10, and start bit 9 |
| New result format | Results use mode `24:23`, global column `22:14`, and 14-bit count `13:0` |
| Nine-bit addressing | Row/column 511 and row 300/column 68 are programmed and read successfully |
| Bank boundary | Requested column 31 returns columns 0:31; column 32 returns columns 32:63 |
| Column-68 compute-all | Requested column 68 returns global columns 64:95 |
| Result FIFO depth | Each compute-all operation produces exactly 32 results and then reports empty after 32 reads |
| Compute-all ordering | Compute-all columns are returned in ascending global-column order |
| AHB error response | Byte access and invalid address produce the required two-cycle ERROR response |
| Command FIFO pressure | Forty slow SET writes demonstrate `HREADYOUT` backpressure and recovery |

# Test sequence

## Test 1: frame packing and idle bus

Before sending functional commands, the testbench demonstrates how the helper functions build complete words:

| Example | Packed word |
| --- | ---: |
| SET row 0, column 0, PWM 1 | `C0000001` |
| READ row 511, column 511, PWM 7 | `7FFFF007` |
| READ result, column 511, count `0x0116` | `00FFC116` |

It then leaves `HSEL=0` and `HTRANS=IDLE` for three clocks and confirms that the command FIFO remains empty. This is the most basic check that an unselected subordinate does not accept a transfer.

## Test 2: reset and configuration

The testbench applies reset and writes:

```text
configuration word 0 = 0x01000100
configuration word 1 = 0x00200020
configuration word 2 = 0x43F00401
```

These values set both SET targets to `0x0100`, both RESET targets to `0x0020`, and configure the timing fields used by the behavioral calculations.

After configuration, an AHB read is performed before any result exists. The access returns an OKAY response and the defined empty value `0xA0000000`.

## Test 3: minimum-address basic operations

This is the smallest complete customer example:

1. SET row 0, column 0 with PWM 1.
2. Read the automatic SET result `0x01800101`.
3. READ row 0, column 0 with PWM 0.
4. Read the READ result `0x00800101`.
5. Send a one-packet COMPUTE for row 0, column 0 with PWM 6 and `compute_start=1`.
6. Read the COMPUTE result `0x01000006` and confirm that the result FIFO is empty afterward.

For each command and result transfer, the testbench also checks that `HRESP` is OKAY. This sequence can be copied as a starting point for a software driver or a different bus-functional model.

## Test 4: SET, READ, and RESET sequence

The testbench performs:

1. SET row 2, column 3, PWM 5.
2. READ row 2, column 3, PWM 7.
3. RESET row 2, column 3, PWM 2.

The expected result words are `0x0180C105`, `0x0080C10C`, and `0x0000C029` respectively. The RESET automatic readback includes the most recent READ PWM value, matching the behavioral model's retained READ-PWM behavior.

## Test 5: multi-row and multi-column COMPUTE

The testbench programs:

1. Row 0, column 5 with SET PWM 10.
2. Row 1, column 5 with SET PWM 20.
3. Row 1, column 6 with SET PWM 30.

It first computes column 5 with row-0 PWM 3 and row-1 PWM 4. The result is count 7 because both selected cells in column 5 are programmed.

It then sends two COMPUTE packets selecting unique columns 5 and 6. The final packet sets bit 9. Two result words are returned in ascending global-column order:

| Global column | Count | Result word |
| ---: | ---: | ---: |
| 5 | 7 | `01014007` |
| 6 | 4 | `01018004` |

Column 6 returns 4 because only the row-1 cell is programmed in that column.

## Test 6: maximum 9-bit address

The maximum legal row and column values are both 511. The testbench performs SET, READ, and one-packet COMPUTE at row 511, column 511 and checks every command and result AHB response.

| Operation | Expected result |
| --- | ---: |
| SET automatic readback | `01FFC116` |
| READ | `00FFC116` |
| COMPUTE with PWM 8 | `017FC008` |

The SET and READ count is `0x0116`: the SET PWM 15 creates cell level `0x010F`, and the retained READ PWM 7 produces `0x0116` during readback.

## Test 7: CBA boundary verification

A compute-all request using column 31 must select bank 0 and return columns 0 through 31. The test checks all 32 result words and confirms that programmed columns 0 and 5 contain the expected count.

A second compute-all request using column 32 must select bank 1 and return columns 32 through 63. The test checks all 32 result words. This proves that `column[8:5]`, rather than only the low five column bits, selects the bank.

## Test 8: mid-range 9-bit address and column-68 compute-all

The testbench programs row 300, column 68 and reads it back. These addresses require the new 9-bit row and column fields and cannot alias into the old 32 by 32 space.

It then sends a COMPUTE command with:

```text
mode          = COMPUTE
row           = 300
column        = 68
compute all   = 1
compute start = 1
PWM           = 9
```

The testbench reads and checks exactly 32 results:

```text
64, 65, 66, 67, 68, ... 95
```

Column 68 has count 9 because that selected cell is programmed. The other cells in this bank are not programmed and therefore return count zero.

## Test 9: AHB error responses

The testbench intentionally performs:

1. A byte-sized access to the X2 address, although only 32-bit word accesses are supported.
2. A word access to `0xE0000008`, which does not match the fixed X2 address.

Both accesses must produce the two-cycle AHB ERROR behavior: an ERROR cycle with `HREADYOUT=0`, followed by ERROR with `HREADYOUT=1`.

## Test 10: command FIFO backpressure

Forty slow SET commands are written without draining their automatic result words. This fills the internal queues and proves that the model lowers `HREADYOUT` to apply backpressure, later resumes the transfer, and does not return an incorrect response. The observed maximum wait in the verified run was 360 clocks.

# Helper functions

The testbench constructs commands using:

```systemverilog
command_word = {mode, row_index, col_index, fsm_error_read,
                compute_all, compute_start, 1'b0, pwm};
```

Expected result words are constructed using:

```systemverilog
expected_result = {7'b0, mode, col_index, count};
```

Using these helpers ensures the test expectations directly reflect the requested frame definitions.

# Running with Icarus Verilog

Open PowerShell in the `TB` directory and run:

```powershell
& 'C:\iverilog\bin\iverilog.exe' `
  -g2012 -Wall `
  -s tb_Neuromorphic_X2_ahb_beh `
  -o '.\tb_Neuromorphic_X2_ahb_beh.vvp' `
  '..\RTL\Neuromorphic_X2_ahb_beh.v' `
  '.\tb_Neuromorphic_X2_ahb_beh.sv'

& 'C:\iverilog\bin\vvp.exe' '.\tb_Neuromorphic_X2_ahb_beh.vvp'
```

If Icarus Verilog is already in `PATH`, the shorter form is:

```powershell
iverilog -g2012 -Wall -s tb_Neuromorphic_X2_ahb_beh `
  -o tb_Neuromorphic_X2_ahb_beh.vvp `
  ..\RTL\Neuromorphic_X2_ahb_beh.v `
  .\tb_Neuromorphic_X2_ahb_beh.sv

vvp .\tb_Neuromorphic_X2_ahb_beh.vvp
```

# Running with another simulator

For simulators such as Questa, Xcelium, or VCS, compile the design Verilog first and the SystemVerilog testbench second. Enable SystemVerilog support and select `tb_Neuromorphic_X2_ahb_beh` as the simulation top.

The model uses behavioral tasks, unpacked memories, SystemVerilog `logic`, and clock-event waits. It is intended for simulation, not synthesis.

# Pass and fail criteria

Every comparison increments the check count. A mismatch prints `FAIL` with actual and expected values. A successful full regression ends with:

```text
TEST_PASS: 172 checks completed
```

The verified run completed with zero failures. Any `TEST_FAIL`, timeout message, response mismatch, result mismatch, or missing final `TEST_PASS` indicates a regression failure.

# Important expected values

| Check | Expected value |
| --- | --- |
| Empty result FIFO | `A0000000` |
| Basic SET row 0, column 0 | `01800101` |
| Basic READ row 0, column 0 | `00800101` |
| Basic COMPUTE row 0, column 0 | `01000006` |
| SET row 2, column 3 | `0180C105` |
| READ row 2, column 3 | `0080C10C` |
| RESET row 2, column 3 | `0000C029` |
| Two-row COMPUTE column 5 | `01014007` |
| Multi-column COMPUTE column 6 | `01018004` |
| SET row 511, column 511 | `01FFC116` |
| READ row 511, column 511 | `00FFC116` |
| COMPUTE row 511, column 511 | `017FC008` |
| SET row 300, column 68 | `01910111` |
| READ row 300, column 68 | `0091010B` |
| Compute-all column 68 result | `01110009` |

For the final line, `0x01110009` decodes to COMPUTE mode, global column 68, and count 9.

# Extending the testbench

Additional tests can reuse `ahb_write`, `ahb_read`, `command_word`, `expected_result`, `wait_for_response`, `check_word`, and `check_bit`.

When adding compute-all tests:

1. Drain earlier result entries before launching compute-all.
2. Read exactly 32 results.
3. Check the first and last global columns against `(requested_column >> 5) * 32` and that value plus 31.
4. Confirm `dut.response_empty` after the 32nd read.

When adding normal COMPUTE tests, terminate the packet sequence by setting command bit 9 or by providing exactly 32 COMPUTE packets.

# Scope of verification

The testbench drives the behavioral model's native AHB boundary directly: 32-bit address/data, two-bit response, address/data phases, and wait states at fixed address `0xE0000004`. It does not instantiate a processor or system interconnect. A final system-level regression should access this address through the customer's actual AHB manager, address decoder, and bus mux.
