# X2 512 by 512 AHB Behavioral Model Design Guide

This guide describes the simulation-only X2 behavioral model in `Neuromorphic_X2_ahb_beh.v`. The model represents a 512 by 512 neuromorphic array, accepts commands through an AHB subordinate interface, retains depth-32 command and result FIFOs, and preserves the existing abstract SET, RESET, READ, COMPUTE, scan, timing, and status behavior.

The 512 by 512 space is logically divided into a 16 by 16 grid of 32 by 32 crossbar-array tiles. A normal command can address any global row and column. A compute-all command returns only the 32-column horizontal bank containing the requested global column, so its 32 results fit exactly in the result FIFO.

# Design deliverable

| File | Purpose |
| --- | --- |
| `Neuromorphic_X2_ahb_beh.v` | Complete 512 by 512 generic AHB behavioral model and optional same-interface wrapper |

The main module is `Neuromorphic_X2_ahb_beh`. An optional wrapper named `Neuromorphic_X2_ahb` is included at the end of the same source file and is enabled by defining `NEUROMORPHIC_X2_AHB_BEH_AS_RTL` during compilation.

# Functional architecture

The model contains five major behavioral blocks:

1. The AHB subordinate captures the address and control phase, then consumes or returns data during the AHB data phase.
2. A depth-32 command FIFO decouples AHB writes from long-running array operations.
3. A sequential command executor decodes configuration and functional command words.
4. A 512 by 512 abstract cell model stores programmed state and deterministic count values.
5. A depth-32 result FIFO supplies SET, RESET, READ, and COMPUTE results to AHB reads.

The command path is:

```text
32-bit AHB manager
        |
        v
AHB subordinate -> 32-word command FIFO -> command executor
                                                |
                                                v
                                      512 x 512 cell model
                                                |
                                                v
AHB read data <- 32-word result FIFO <- result formatter
```

# Parameters

| Parameter | Default | Meaning |
| --- | ---: | --- |
| `ADDR_MATCH` | `32'hE000_0004` | Fixed/default X2 AHB word address |
| `READ_DELAY` | `160` | Simulated clock cycles for READ |
| `PROGRAM_DELAY` | `360` | Base simulated clock cycles for SET or RESET |
| `COMPUTE_DELAY` | `450` | Simulated clock cycles for COMPUTE |
| `CONFIG_WRITES` | `3` | Number of configuration writes expected after reset |
| `INITIAL_CELL_LEVEL` | `14'h0E23` | Initial deterministic count for every cell before configuration completes |

The delivered model fixes the X2 register at `0xE0000004`. The upstream address decoder must assert `HSEL` and route the model's response signals when a manager accesses this address. Software, the decoder, and the behavioral model must all use this same address.

# Interface signals

## AHB subordinate interface

| Signal | Direction | Width | Use |
| --- | --- | ---: | --- |
| `HCLK` | Input | 1 | AHB and model clock |
| `HRESETn` | Input | 1 | Active-low reset |
| `HSEL` | Input | 1 | Subordinate select |
| `HADDR` | Input | 32 | Address phase address |
| `HTRANS` | Input | 2 | `NONSEQ` and `SEQ` are accepted when `HTRANS[1]` is high |
| `HWRITE` | Input | 1 | High for write, low for read |
| `HSIZE` | Input | 3 | Only 32-bit word access, `3'b010`, is accepted |
| `HBURST` | Input | 3 | Present for AHB interface compatibility; not used by the behavioral operation |
| `HPROT` | Input | 4 | Present for interface compatibility |
| `HMASTER` | Input | 4 | Present for interface compatibility |
| `HMASTLOCK` | Input | 1 | Present for interface compatibility |
| `HWDATA` | Input | 32 | Write data sampled in the AHB data phase |
| `HREADY` | Input | 1 | Global upstream AHB ready indication |
| `HRDATA` | Output | 32 | Read result, status, or empty-FIFO value |
| `HREADYOUT` | Output | 1 | Subordinate ready and wait-state control |
| `HRESP` | Output | 2 | `2'b00` for OKAY and `2'b01` for ERROR |

The model uses the full two-bit AHB response encoding: `HRESP=2'b00` for OKAY and `HRESP=2'b01` for ERROR. Connect the native interface to a compatible AHB interconnect or manager. Any platform-specific address decoding or signal-width conversion belongs in the customer's integration logic and is intentionally outside this behavioral-model package.

## Scan and decoder abstraction

| Signal group | Direction | Purpose |
| --- | --- | --- |
| `i_scan_si1`, `i_scan_se1`, `i_TM` | Input | Legacy 16-bit scan/debug shifting and test-mode control |
| `o_TM` | Output | Active scan test-mode indication |
| `o_mux_sel[1:0]` | Output | Abstract operation mux selection |
| `o_wl_*[511:0]` | Output | Word-line address, data, and float abstraction |
| `o_bl_*[511:0]` | Output | Bit-line address, data, and float abstraction |
| `o_sl_*[511:0]` | Output | Source-line address, data, and float abstraction |

Functional operation can select all 512 global lines. The retained scan word contains 5-bit selectors, so scan mode directly controls only local lines 0 through 31; lines 32 through 511 remain floating in scan mode.

# Reset and configuration

Assert `HRESETn=0` to reset the bus state, FIFO pointers, configuration state, compute accumulator, status, and all abstract cells. After reset is released, the first three accepted AHB writes are configuration words, not array commands.

## Configuration word 0

| Bits | Field |
| --- | --- |
| `31:16` | `target_set2` |
| `15:0` | `target_set1` |

## Configuration word 1

| Bits | Field |
| --- | --- |
| `31:16` | `target_reset2` |
| `15:0` | `target_reset1` |

## Configuration word 2

| Bits | Field |
| --- | --- |
| `31:30` | TDC dead time |
| `29:27` | Unused |
| `26:20` | TDC timeout |
| `19:10` | Counter value |
| `9:0` | Number of extra program clock cycles |

After the complete configuration triplet is processed, all cell count levels are initialized deterministically from the configured RESET targets. Functional commands can then be issued.

# Functional command frame

Every functional command is one 32-bit AHB write.

| Bits | Field | Meaning |
| --- | --- | --- |
| `31:30` | Mode | `00` RESET, `01` READ, `10` COMPUTE, `11` SET |
| `29:21` | Row | Nine-bit global row, 0 through 511 |
| `20:12` | Column | Nine-bit global column, 0 through 511 |
| `11` | FSM error read | When set, subsequent AHB reads return status instead of consuming result FIFO data |
| `10` | Compute all columns | For COMPUTE, select the 32-column bank containing the requested column |
| `9` | Compute start | Final COMPUTE packet and launch marker |
| `8` | Reserved | Drive zero |
| `7:0` | PWM | Program, read, or compute PWM value |

The command can be constructed as:

```systemverilog
command = {mode, row[8:0], column[8:0], fsm_error_read,
           compute_all, compute_start, 1'b0, pwm[7:0]};
```

# Result frame

Every non-status result uses this 32-bit format:

| Bits | Field | Meaning |
| --- | --- | --- |
| `31:25` | Reserved | Always zero |
| `24:23` | Mode | Operation that generated the result |
| `22:14` | Column | Nine-bit global result column |
| `13:8` | Coarse count | Upper six bits of the 14-bit count |
| `7:0` | Fine count | Lower eight bits of the 14-bit count |

## Differential signed-column convention

Signed weights are represented using adjacent physical-column pairs `(2*n, 2*n+1)`.

- TDC result `2*n` represents `column[2*n] - column[2*n+1]`.
- TDC result `2*n+1` represents `column[2*n+1] - column[2*n]`.

For example:

- TDC0 = column 0 - column 1
- TDC1 = column 1 - column 0

Result bits `[22:14]` identify the minuend column. Result bits `[13:0]` contain the signed differential count encoded as 14-bit two's complement.

The full count is reconstructed as `result[13:0]`. The global result column is `result[22:14]`.

When the result FIFO is empty and status mode is not selected, an AHB read returns `32'hA000_0000` without consuming any entry.

# Global addressing and tile mapping

The global array contains 512 rows and 512 columns. Each address is divided into a tile number and a local 32-line address:

```text
vertical tile    = row[8:5]       range 0 to 15
local row        = row[4:0]       range 0 to 31
horizontal tile  = column[8:5]    range 0 to 15
local column     = column[4:0]    range 0 to 31
```

Examples:

| Global address | Tile selection | Local selection |
| --- | --- | --- |
| Row 2, column 3 | Vertical tile 0, horizontal tile 0 | Row 2, column 3 |
| Row 300, column 68 | Vertical tile 9, horizontal tile 2 | Row 12, column 4 |
| Column 31 | Horizontal tile 0 | Local column 31 |
| Column 32 | Horizontal tile 1 | Local column 0 |
| Column 511 | Horizontal tile 15 | Local column 31 |

# Operation behavior

## SET

SET marks the selected cell as programmed, calculates its deterministic level from the midpoint of the two SET targets plus the command PWM, and waits `PROGRAM_DELAY + no_of_clk_cycles`. It then places one automatic readback word in the result FIFO. The automatic readback applies the most recent READ PWM, matching the existing model behavior.

## RESET

RESET clears the selected cell's programmed state, calculates its level from the midpoint of the two RESET targets plus the command PWM, waits `PROGRAM_DELAY + no_of_clk_cycles`, and places one automatic readback word in the result FIFO.

## READ

READ selects one global cell, waits `READ_DELAY`, and returns its deterministic cell level plus the READ PWM. The PWM is saved as the most recent READ PWM for later SET or RESET automatic readback.

## Normal COMPUTE

A compute sequence contains one through 32 COMPUTE command words. Each packet selects a global row, a global column, and a PWM contribution. The model retains a row mask, the PWM for each selected row, and a unique-column mask.

The sequence launches when either:

- Bit 9 is set in a COMPUTE packet, or
- The 32nd COMPUTE packet is accepted.

After `COMPUTE_DELAY`, one result is generated for each unique selected column in ascending global-column order. For a result column, the model adds the PWM values of selected rows whose cell at that column is currently programmed. The accumulated result is limited by the configured timeout ceiling.

A SET, RESET, or READ command clears any unfinished COMPUTE accumulation.

## COMPUTE all columns

When bit 10 is set, the requested column chooses one horizontal 32-column CBA bank:

```text
bank number = column[8:5]
first column = bank number * 32
last column = first column + 31
```

Exactly 32 results are generated in ascending global-column order. This fills, but does not exceed, the depth-32 result FIFO.

For requested column 68:

```text
bank number  = 68 >> 5 = 2
first column = 2 * 32 = 64
last column  = 64 + 31 = 95
```

The result FIFO therefore receives columns 64 through 95, with their global column addresses encoded in result bits `22:14`.

# FIFO and backpressure behavior

Both FIFOs remain depth 32.

- If the command FIFO is full, an AHB write is held by keeping `HREADYOUT` low until space is available. The write is not discarded.
- If the result FIFO is full, the command executor waits until the AHB manager reads at least one result.
- A compute-all operation writes exactly 32 entries. The AHB manager should drain these results before expecting another result-producing command to finish.
- Result FIFO entries are returned in generation order.

# AHB transfer behavior

The model observes the pipelined AHB phase relationship:

1. `HADDR`, `HTRANS`, `HWRITE`, and `HSIZE` are captured in the address phase when `HSEL`, `HTRANS[1]`, and `HREADY` are high.
2. For a write, `HWDATA` is consumed in the following data phase.
3. A successful access inserts one subordinate wait state.
4. An invalid address or a non-word `HSIZE` returns the two-cycle AHB ERROR response: first `HREADYOUT=0` with ERROR, then `HREADYOUT=1` with ERROR.

Only `ADDR_MATCH` with `HSIZE=3'b010` is accepted.

# Status reads

If command bit 11 is set, subsequent valid AHB reads return `{29'b0, status_code}` instead of reading the result FIFO. A later command with bit 11 clear returns the interface to normal result-FIFO reads.

Defined status values are:

| Status | Encoding |
| --- | --- |
| OK | `3'b000` |
| READ timeout | `3'b001` |
| SET failed | `3'b011` |
| COMPUTE timeout | `3'b100` |
| RESET failed | `3'b101` |

The current deterministic behavioral operations normally complete with OK. These encodings preserve the expected control interface for fault-oriented extensions.

# Integration example

Instantiate the behavioral module as an AHB subordinate and route its response through the SoC bus mux:

```systemverilog
Neuromorphic_X2_ahb_beh #(
  .ADDR_MATCH        (32'hE000_0004),
  .READ_DELAY        (160),
  .PROGRAM_DELAY     (360),
  .COMPUTE_DELAY     (450),
  .CONFIG_WRITES     (3),
  .INITIAL_CELL_LEVEL(14'h0E23)
) x2_model (
  .HCLK       (HCLK),
  .HRESETn    (HRESETn),
  .HSEL       (x2_hsel),
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
  .HRDATA     (x2_hrdata),
  .HREADYOUT  (x2_hreadyout),
  .HRESP      (x2_hresp),
  .i_scan_si1 (i_scan_si1),
  .i_scan_se1 (i_scan_se1),
  .i_TM       (i_TM),
  .o_TM       (o_TM),
  .o_mux_sel  (o_mux_sel),
  .o_sl_float (o_sl_float),
  .o_sl_addr  (o_sl_addr),
  .o_sl_data  (o_sl_data),
  .o_bl_addr  (o_bl_addr),
  .o_bl_data  (o_bl_data),
  .o_bl_float (o_bl_float),
  .o_wl_float (o_wl_float),
  .o_wl_addr  (o_wl_addr),
  .o_wl_data  (o_wl_data)
);
```

# Recommended software sequence

1. Assert and release system reset.
2. Write the three configuration words to `ADDR_MATCH` using 32-bit AHB transfers.
3. Submit SET, RESET, READ, or COMPUTE command words.
4. For SET, RESET, and READ, poll or wait long enough for one result, then perform one AHB read.
5. For normal COMPUTE, read one result per unique requested column.
6. For compute-all, read exactly 32 results and decode each global column from bits `22:14`.
7. Treat `32'hA000_0000` as an empty result FIFO indication.

# Behavioral-model limitations

This is a simulation behavioral model, not synthesizable X2 array RTL. It uses behavioral tasks, clock waits, and a large abstract cell store. It verifies digital control, addressing, FIFO, frame formatting, and AHB interaction, but it does not model transistor-level conductance, physical TDC variation, parasitics, power behavior, or post-layout timing.

The model was verified directly with a generic AHB bus-functional manager using the full interface, correct address/data phase behavior, wait states, OKAY responses, and ERROR responses. No processor or system interconnect is instantiated by the supplied testbench. Customers should also run a system-level regression with their own AHB manager, address decoder, and bus mux.
