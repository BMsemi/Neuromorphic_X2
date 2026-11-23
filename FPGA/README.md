# Shared-FIFO logical 512x512 PE

This is new synthesizable binary PE RTL implementing the requested sequence.
It is separate from the previous Qwen-named six-engine arithmetic-validation
package. The ZCU106 integration uses `pe512_axi` at PS address `0xA0000000`.

## Physical validation — 23 November 2026

The new bitstream was programmed over JTAG onto the connected ZCU106 and
tested through the running Linux PS. It remains loaded. This is physical
validation of this shared-FIFO RTL, separate from the earlier six-engine tests.

- All 256 tiles passed: 8192 packed responses and all 512 L2 sums matched.
- A queued next tile stayed blocked after 31 reads; read 32 released it.
- No responses were discarded during normal execution. Zero/max inputs,
  cell operations, automatic drain and explicit reset/scrub checks passed.
- The frozen 100-image MNIST baseline matched software exactly for first-layer
  sums, hidden bits, second-layer sums, final scores and all predictions.
  Classification accuracy was 93/100; hardware agreement was 100/100.
- An additional per-pixel scan of test image 8 (label 5) passed: FC0 performed
  3136 launches / 100352 response reads; FC1 performed four launches / 128 reads.
  Scores were `[46,33,42,30,49,52,51,32,42,42]`, whose argmax is digit 5.
- One physical PE was reused for all three model placements. No dot products
  fell back to the PS. PS combined the two FC0 placement vectors and performed
  thresholding, score offsets and argmax.

Full routed utilization: 2579 LUTs, 1443 registers, seven RAMB36 plus one
RAMB18, zero DSPs. At the 100 MHz constraint, setup slack is +4.443 ns and hold
slack +0.022 ns; no timing endpoints fail and DRC reports zero violations.
The live Linux clock report gives 99.99 MHz. Both core and AXI simulations pass.

Evidence is under `build/physical/` in the checkout and `reports/physical/`
in the ZIP. The package includes raw response vectors, L2 values, MNIST layer
outputs, reports, bit/HWH, tests, build/program scripts and SHA-256 manifests.
The programming log records successful startup followed by an unsupported
optional JTAG DONE-property query. That query was removed from the delivered
script; the new hardware ID and all subsequent physical tests passed.

## Architecture

One logical PE contains all 262,144 binary weights as 256 resident 32x32 tiles.
There is exactly one 32-word command FIFO and one 32-word response FIFO for
the entire PE. Tiles do not have individual FIFOs or individual compute engines.

1. Consume commands from the shared command FIFO and select one tile.
2. Compute that tile using 32 parallel binary accumulators, one per output column.
3. Write all 32 packed responses into the shared response FIFO.
4. Read those responses into the digital L2 accumulator on valid/ready handshakes.
5. Only after response FIFO occupancy reaches zero may another command execute.

A complete response bank is filled before reads are enabled. An unfinished
bank blocks all following commands, including the last unread response. New
commands may queue up to the command FIFO's capacity, but cannot execute early.
Backpressure preserves the response data. There is no unread-result flush path;
responses_discarded is always zero. Reset explicitly aborts pending work.

All 256 logical tiles use shared hardware. No PS tile arithmetic fallback is
needed by this implementation. The PS may schedule commands, program weights
and read the L2 sums. If a future integration moves L2 storage to the PS, use
pe512_core directly and acknowledge each response only when the PS accepts it.
The included pe512_system connects the response FIFO to an FPGA L2 accumulator.

## Source files

| File | Function |
| --- | --- |
| rtl/shared_fifo32.v | 32-bit-wide, depth-32 ready/valid FIFO; instantiated twice |
| rtl/pe512_core.v | Tile addressing, resident binary weight RAM, command decoder, compute and drain interlock |
| rtl/l2_accumulator.v | 512 32-bit digital sums, updated on accepted COMPUTE responses |
| rtl/pe512_system.v | Top-level core plus L2 consumer and monitoring ports |
| sim/tb_pe512_system.sv | Self-checking SystemVerilog testbench |

The design is single-clock with synchronous active-high reset. All host
interfaces must be synchronous to clk, or use an external CDC bridge.

## Host interface and reset

After reset, the weight RAM is cleared over 8192 clocks and L2 over 512 clocks.
Wait for init_done, then send three configuration words through cmd_data using
cmd_valid/cmd_ready. The configuration values are accepted for the Python
stream layout but have no analog timing effect. The usual words are
0xA203C40F, 0x0F030D43 and 0x42000C03. Wait for configured before programming.

Bulk programming uses prog_valid/prog_ready, prog_addr[12:0] and prog_data[31:0].
One accepted write supplies one row of one tile (32 binary column weights):

    prog_addr = (tile_row * 16 + tile_column) * 32 + local_row
    prog_data[j] = weight[tile_row*32 + local_row][tile_column*32 + j]

All tile indices are 0..15 and local row/column indices are 0..31. Bulk writes
are accepted only while the PE is configured, idle, and has no queued commands,
unfinished input burst or unread responses. Commands have priority over bulk writes.

On pe512_system, drain_enable controls L2 consumption. response_valid,
response_ready and response_data expose the actual read handshake for monitoring.
Do not treat response_valid alone as a read. Read completed sums through
l2_read_addr[8:0]/l2_read_data[31:0]. L2 data is an asynchronous read in this
implementation; sample it after the address has settled.

Request a new L2 accumulation epoch with l2_clear_valid/l2_clear_ready. Clear
requests are accepted only when the PE and both FIFOs are quiescent. Wait for
l2_clearing to deassert before using the cleared sums. Clear L2 between images
or layer epochs as required; weights remain programmed.

## Commands and responses

COMPUTE uses the same full-bank binary packet fields as the current Python scan:

| Command bits | Meaning |
| --- | --- |
| 31:30 | Mode: 00 RESET cell, 01 READ cell, 10 COMPUTE, 11 SET cell |
| 29:21 | Global row 0..511 |
| 20:12 | Global column; its upper four bits select the 32-column bank |
| 11 | Must be zero for COMPUTE; diagnostic-read selection is not implemented |
| 10 | Must be one for full-bank COMPUTE |
| 9 | Final packet / launch marker |
| 8 | Reserved; must be zero for COMPUTE |
| 7:0 | Binary activation for COMPUTE: 0 or 1 |

Within a compute burst, all packets must select the same 32-row tile and
32-column bank. Unspecified rows are zero. Repeated rows overwrite their prior
activation. A final marker or the 32nd packet launches exactly one tile.
For a zero vector, send one packet with activation zero and the final marker.
The 32 response columns are always bank_start through bank_start+31 in order,
including zero values. Error code 1 indicates an unsupported compute packet;
code 2 indicates a burst crossing tile boundaries. An invalid packet clears
the unfinished input burst and does not launch. Error status is sticky until reset.

Each response is:

    bits 31:25 = 0
    bits 24:23 = operation mode
    bits 22:14 = global column
    bits 13:0  = value

COMPUTE values are counts 0..32. SET/RESET/READ cell commands also use the
shared FIFO pair and return one response containing the binary cell state.
They are consumed without adding to L2. These cell responses do not emulate
the Python model's analog cell levels, programming pulse delays, PWM or TDC.
An intervening cell command clears an unfinished compute burst.

## RTL verification

Vivado Simulator 2022.2 checks:

- Full response-bank retention and command-FIFO backpressure.
- A complete next tile queued while the preceding bank remains unread.
- Draining 31 responses still blocks the next launch; the 32nd read releases it.
- All 256 tiles, 8192 ordered COMPUTE responses and all 512 L2 sums.
- Randomized response stalls and stable output under backpressure.
- Automatic launch on packet 32 and explicit final-marker launch.
- Zero input, duplicate-row overwrite, invalid cross-tile/nonbinary burst rejection.
- Cell SET/READ/RESET through the same FIFOs, excluded from L2 accumulation.
- All-one tile arithmetic: 32 in every column.
- Reset with unread responses, deterministic weight scrub and restart.

Run from this directory:

    powershell -File scripts/run_sim.ps1

Override -VivadoBin if Vivado is installed elsewhere. A successful run contains
ALL_SHARED_PE_TESTS_PASSED in build/simulation/simulation.log. The simulator
exit code alone is not used as proof of passing assertions.

Out-of-context synthesis for ZCU106:

    vivado -mode batch -source scripts/synthesize.tcl

The final delivery includes the simulation log, synthesis utilization and
estimated timing reports. Synthesis estimates are not routed timing closure.

The final 23 November 2026 run passed all testbench checks. Out-of-context
synthesis on xczu7ev-ffvc1156-2-e used 1666 total LUTs (802 logic and 864
LUTRAM), 463 flip-flops, seven RAMB36 blocks, one RAMB18 block and no DSPs.
The hierarchy report shows one command_fifo and one response_fifo instance.
The 8192x32 weight memory was inferred as block RAM. No tile compute fallback
to the PS is needed to accommodate this logical array's storage.

Synthesis completed with zero errors and zero critical warnings. Its warnings
include unused analog configuration storage, unused response header bits, and
an out-of-context clock-source warning. External input/output delays are not
constrained here; board-level integration must supply those constraints.

## ZCU106 integration

`pe512_axi.v` adds an AXI-Lite interface; it does not add command or response
FIFOs. Independent write-address/data arrivals and stalled read/write responses
are supported. Invalid, unaligned and partial writes return SLVERR. A command
write to a full FIFO and programming while busy also return SLVERR: poll the
ready status first. The CPU should map registers as device memory (`/dev/mem`
with O_SYNC on the tested Linux image). All accesses are aligned 32-bit words.
Use the driver's NumPy `uint32` memory view. The tested ARM Python's struct and
ctypes access paths produced incorrect FIFO writes or bus errors; byte-oriented
access is unsuitable for these side-effecting registers.

| Offset | Register | Meaning |
| --- | --- | --- |
| 0x00 | CONTROL | bit 0 soft reset; bit 1 automatic L2 drain; bit 2 L2 clear pulse; bit 3 consume exactly one response |
| 0x04 | STATUS | bits 0..8: initialized, configured, busy, command ready, program ready, complete response available, L2 clearing, L2 clear ready, automatic drain |
| 0x08 | COUNTS | command occupancy bits 5:0; response occupancy bits 13:8 |
| 0x0C | ERROR | sticky core error code |
| 0x10 | COMMAND | enqueue one packed command (write only) |
| 0x14 | PROGRAM_ADDRESS | 13-bit weight word index |
| 0x18 | PROGRAM_DATA | write 32 weight bits; address auto-increments |
| 0x1C | RESPONSE_PEEK | response head, without consuming |
| 0x20 | L2_ADDRESS | column 0..511 |
| 0x24 | L2_DATA | selected accumulated value |
| 0x28 | LAUNCH_COUNT | tile launches since reset |
| 0x2C | RESPONSES_READ | all response handshakes since reset |
| 0x30 | RESPONSES_DISCARDED | always zero; ordinary operation never flushes unread data |
| 0x34 | L2_WORDS | compute words accepted since reset or L2 clear |
| 0x38 | MAGIC | 0x53503531 |
| 0x3C | VERSION | 0x00010000 |
| 0x40 | LAST_RESPONSE | most recently consumed packed response |

CONTROL writes replace the automatic-drain bit. Use 1 for reset, 2 for automatic
drain, 0 to pause, 4 for L2 clear, or 8 for a single response step. Reset is a
standalone operation and deliberately aborts queued/unread work. Single-step
requires automatic drain disabled and a valid response. Clear L2 only when
STATUS bit 7 is set. Configure again after reset; reset scrubs weights and L2.

Build, simulate the bus adapter and program PL (Vivado 2022.2):

    powershell -File scripts/run_axi_sim.ps1
    vivado -mode batch -source scripts/build_zcu106.tcl
    vivado -mode batch -source scripts/program_zcu106.tcl
    python scripts/run_board.py

The validated ZIP also includes the built bit/HWH under
`reports/physical/overlay/`; the programming script uses that bitstream if a
local build is absent. `validation_inputs.npz` is the frozen 100-image baseline
included for reproducibility; upload it to the board and use `--inputs` if the
original cached board path is unavailable.

The build uses a fresh `D:/fpga_build/shared_pe512_v2` directory; set the
SHARED_PE_BUILD environment variable to another fresh directory for a rebuild.
The build supplies the ZCU106 board preset, PS HPM0 AXI master, SmartConnect,
reset controller and a 100 MHz PL clock. Setup and hold must pass after routing
before bit/HWH export. JTAG programming changes PL only; it does not initialize,
halt or reset the running Linux PS. The existing Linux PS must already enable
HPM0 and the 100 MHz PL clock, as on this tested board.

The runner uses COM17 at 115200 and sudo without a password on the connected
ZCU106. It checks transferred script/result hashes. `--prepare` uploads without
running; `--port`, `--remote` and `--inputs` override board-specific defaults.
The previous image remains available at
`/home/xilinx/qwen6_20261005/fpga/qwen6/overlay/qwen6.bit` on the board and
`D:/fpga_build/q6f/q6.runs/impl_1/q6_wrapper.bit` on the host. Pass the host bit
path after `-tclargs` to `program_zcu106.tcl` to restore it. Do not use the old
six-engine MMIO driver while the new image is loaded.

`board_validate.py` verifies the 31/32-read launch barrier, full command FIFO,
all 256 tiles (8192 raw responses and 512 L2 sums), zero/max dot products,
cell SET/READ/RESET, automatic drain and reset scrubbing. `board_mnist.py`
reuses one physical PE for FC0's two row placements and then FC1. Every dot
product and within-placement accumulation runs in PL; PS combines the two FC0
vectors and applies thresholds, score offsets and argmax. It groups 32 binary
input rows per tile for the 100-image batch, so that batch is arithmetic
validation rather than cycle-for-cycle replay of the Python scheduler. An
additional digit-5 test uses per-pixel FC0 full-bank compute/read operations:
3136 launches and 100352 responses, followed by four FC1 tiles. CPU scheduling
overhead is not intended to reproduce the simulator's cycle estimates.

Analog crossbar behavior and its energy/latency estimates are outside this
digital RTL validation. L2 arithmetic is unsigned 32-bit accumulation; clear
it before overflow on very long workloads. Core compute timing follows the
RTL state machine, not the simulator's fixed 288-cycle analog estimate.
