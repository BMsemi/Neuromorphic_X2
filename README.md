<table>
  <tr>
    <td align="center"><img src="bm-lab-logo-white.jpg" alt="BM LABS Logo" width="200"/></td>
    <td align="center"><img src="chip_foundry_logo.png" alt="ChipFoundry Logo" width="200"/></td>
  </tr>
</table>

# Neuromorphic X2 – Analog In-Memory Compute IP Macro

Neuromorphic X2 is a **512 × 512 ReRAM compute-in-memory IP macro** combining **256 Kb non-volatile storage** with analog multiply–accumulate operations. It is controlled through a **32-bit Wishbone interface** for energy-efficient edge-AI acceleration.

---

## Key Features

- **512 × 512 ReRAM crossbar** with 256 Kb storage
- **SET, RESET, READ, and COMPUTE** operating modes
- FIFO-decoupled Wishbone command and response paths
- TDC-style read and compute-result output
- Runtime reconfiguration without a full reset
- Simulation-ready behavioral model and testbench

---

## Data Flow

```text
Wishbone Write
      ↓
Input / Command FIFO
      ↓
Configuration or SET / RESET / READ / COMPUTE
      ↓
512 × 512 ReRAM Crossbar
      ↓
TDC Read or MAC Result
      ↓
Output / Response FIFO
      ↓
Wishbone Read
```

Compute-mode commands are written to the **input FIFO**. The crossbar operation is then executed, and the resulting MAC data is returned through the **output FIFO**.

---

<p align="center">
  <img src="doc/reram_cim_process.jpg" alt="ReRAM CIM Process Flow" width="800"/>
</p>

---

## Behavioral Model

- Main model: `hdl/beh_model/Neuromorphic_X2_wb_beh.v`
- Testbench: `hdl/beh_model/tb_Neuromorphic_X2_wb_beh.v`
- Wishbone address: `0x3000_0004`
- The first three writes after reset configure the model.
- COMPUTE mode accepts three input packets and generates 32 queued result words.
- Wishbone reads complete only when response data is available.

### Command Modes

| Mode | Value | Operation |
|---|---:|---|
| RESET | `00` | Program reset state |
| READ | `01` | Read TDC result |
| COMPUTE | `10` | Perform MAC operation |
| SET | `11` | Program set state |

---