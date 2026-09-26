# Digital Design & Edge AI Hardware Projects

A collection of RTL and machine-learning projects — from foundational digital-logic building blocks to full accelerator systems: FPGA-accelerated vision transformers, edge-TPU deployment, RISC-V processor design, and systolic-array acceleration. Work spans the full stack — model quantization and training, hardware-aware co-design, RTL implementation, and synthesis/verification on real silicon (Zynq, Edge TPU).

**Stack:** Verilog / SystemVerilog · Python · PyTorch / TensorFlow / Keras · Vivado · XSim · Edge TPU Compiler

---

## Major Projects

### 1. FPGA-Accelerated INT8 Swin Vision Transformer for Thermal Object Detection
`/rtl`

An edge-deployable thermal object detector (CNN backbone + Swin Transformer attention + YOLOX-style decoupled head), quantized to INT8 via QAT, with synthesizable Verilog RTL for the Swin-attention backbone.

**Architecture**

```mermaid
flowchart TD
    A[Thermal Input Frame] --> B["INT8 CNN Backbone"]
    B --> C["Swin Transformer Attention Block"]
    C --> D["Split-wise INT8 Q / K / V Projection"]
    D --> E["Attention RTL Core (Verilog, FPGA)"]
    E --> F["YOLOX-style Decoupled Head"]
    F --> G["Bounding Boxes + Class Scores"]

    style E fill:#2d6cdf,color:#fff,stroke:#1a3d7a
    style B fill:#1e293b,color:#fff
    style C fill:#1e293b,color:#fff
    style D fill:#1e293b,color:#fff
```

- Split-wise INT8 quantization for Q/K/V projections; layer-wise fixed-point inference simulator to validate hardware accuracy pre-RTL
- 0.9084 mean IoU, 0.000976 box MAE, 100% class-match accuracy (QAT vs. strict-INT8 fidelity)
- Full-model golden-pass RTL verification at 200 MHz (14,992,460 cycles, 74.96 ms/frame, 13.34 FPS, 0 error vs. software reference)
- Clean timing closure: WNS +0.059 ns / WHS +0.006 ns across 487,447 setup/hold endpoints, 0 failing paths
- Synthesis: 66.69% LUT, 17.17% FF, 81.80% BRAM, 54.72% DSP, ~2.29 W estimated on-chip power

**Tools:** Python, TensorFlow, Keras, Verilog, RTL, Vivado, XSim

---

### 2. Hardware-Aware INT8 TAESD Decoder Deployment on Google Coral Edge TPU
`/Hardware-Aware INT8 TAESD Decoder Deployment on Google Coral Edge TPU`

An INT8 QAT-trained TAESD decoder for latent-to-image reconstruction, deployed end-to-end through PyTorch → TensorFlow → TFLite → Edge TPU.

**Architecture**

```mermaid
flowchart LR
    A["PyTorch INT8 QAT Model"] --> B["TensorFlow Conversion"]
    B --> C["TFLite Conversion"]
    C --> D["Edge TPU Compiler"]
    D --> P1["Graph Partition 1"]
    D --> P2["Graph Partition 2"]
    D --> P3["Graph Partition 3"]
    D --> P4["Graph Partition 4"]
    P1 --> E["Google Coral Edge TPU"]
    P2 --> E
    P3 --> E
    P4 --> E
    E --> F["Reconstructed Image (120 dB PSNR)"]

    style E fill:#2d6cdf,color:#fff,stroke:#1a3d7a
    style D fill:#1e293b,color:#fff
```

- Redesigned as four independently calibrated graph partitions — 100% Edge TPU operator mapping (53/53 ops), vs. ~58% for the monolithic graph
- 120 dB PSNR, ~740 ms average hardware latency
- Replaced Edge TPU-incompatible residual-add connections with concatenation + 1×1 convolution blocks, eliminating CPU fallback

**Tools:** PyTorch, TensorFlow, TensorFlow Lite, Edge TPU Compiler, INT8 Quantization

---

### 3. Five-Stage RISC-V Pipelined Processor (RV32I)
`/riscv`

A classic 5-stage (IF–ID–EX–MEM–WB) pipelined implementation of the RV32I ISA in Verilog HDL.

**Architecture**

```mermaid
flowchart LR
    IF["IF: Instruction Fetch"] --> ID["ID: Decode / Reg Read"]
    ID --> EX["EX: ALU Execute"]
    EX --> MEM["MEM: Data Memory Access"]
    MEM --> WB["WB: Register Write-Back"]

    EX -. "EX/MEM Forward" .-> EX
    MEM -. "MEM/WB Forward" .-> EX
    ID -. "Hazard Detect → Stall" .-> IF
    EX -. "Branch/Jump → Flush" .-> ID

    style IF fill:#1e293b,color:#fff
    style ID fill:#1e293b,color:#fff
    style EX fill:#2d6cdf,color:#fff
    style MEM fill:#1e293b,color:#fff
    style WB fill:#1e293b,color:#fff
```

- Hazard-detection unit for load-use and memory hazards
- EX/MEM and MEM/WB data forwarding to resolve RAW hazards
- Pipeline-flush logic for branch/jump control hazards

**Tools:** Verilog, RTL, Vivado, XSim

---

### 4. INT8 Output-Stationary Systolic Array Accelerator — PYNQ-Z2
`/systolic4x4ws`

A 4×4 (16-PE) INT8 output-stationary systolic array for matrix multiplication, implemented in Verilog RTL and deployed on the PYNQ-Z2 (Zynq-7020).

**Architecture**

```mermaid
flowchart TD
    AXI["AXI4-Lite Wrapper (9 pins ext I/O)"] --> PE00
    subgraph SA [" 4x4 INT8 Output-Stationary PE Array "]
        PE00((PE00)) --> PE01((PE01)) --> PE02((PE02)) --> PE03((PE03))
        PE10((PE10)) --> PE11((PE11)) --> PE12((PE12)) --> PE13((PE13))
        PE20((PE20)) --> PE21((PE21)) --> PE22((PE22)) --> PE23((PE23))
        PE30((PE30)) --> PE31((PE31)) --> PE32((PE32)) --> PE33((PE33))
        PE00 --> PE10 --> PE20 --> PE30
        PE01 --> PE11 --> PE21 --> PE31
        PE02 --> PE12 --> PE22 --> PE32
        PE03 --> PE13 --> PE23 --> PE33
    end
    PE03 --> OUT["Output Accumulators"]
    PE13 --> OUT
    PE23 --> OUT
    PE33 --> OUT

    style AXI fill:#2d6cdf,color:#fff
    style OUT fill:#2d6cdf,color:#fff
```

- 1.6 GMAC/s (3.2 GOPS) at 100 MHz
- 100% functional match against a software golden model across four test cases; timing closure achieved (WNS +0.425 ns)
- Synthesis: 3.15% LUT / 0.85% FF / 0% DSP / 0% BRAM on Zynq-7020
- Custom AXI4-Lite wrapper reducing external I/O from ~590 pins to 9

**Tools:** Verilog, RTL, Vivado, XSim, FPGA

---

## Digital Logic Building Blocks

Foundational Verilog modules — combinational and sequential building blocks used as reference implementations and reusable components across the larger projects above.

| Module | Folder |
|---|---|
| Booth Multiplier | `/booth multiplier` |
| Array Multiplier | `/arraymultiplier` |
| Carry Lookahead Adder (32-bit) | `/CLA32` |
| Carry Lookahead Adder (4-bit) | `/cla4bit` |
| Carry Save Adder | `/csa` |
| 1-bit Adder | `/1bitadder` |
| 8-bit Adder | `/8BITADDER` |
| 8-bit Ripple Carry Adder | `/8BITRCA` |
| BCD Encoder | `/bcd encoder` |
| Priority Encoder | `/priority encoder` |
| Gray Encoder | `/gray encoder` |
| Encoder | `/ENCODER` |
| Decoder | `/decoder` |
| Demux | `/DEMUX` |
| Mux | `/MUX` |
| Comparator | `/COMPARATOR` |
| Registers | `/registers` |
| LUT RAM | `/lut ram` |
| FIFO | `/fifo` |
| Mealy/Moore FSM | `/mealy moore fsm` |
| ALU | `/alu` |
| Verilog Tasks/Functions | `/task`, `/Functions` |

---

## Repository Structure

```
.
├── thermal/
├── Hardware-Aware INT8 TAESD Decoder Deployment on Google Coral Edge TPU/
├── riscv/
├── systolic4x4ws/
├── booth multiplier/
├── arraymultiplier/
├── CLA32/
├── cla4bit/
├── csa/
├── 1bitadder/
├── 8BITADDER/
├── 8BITRCA/
├── bcd encoder/
├── priority encoder/
├── gray encoder/
├── ENCODER/
├── decoder/
├── DEMUX/
├── MUX/
├── COMPARATOR/
├── registers/
├── lut ram/
├── fifo/
├── mealy moore fsm/
├── alu/
├── task/
├── Functions/
└── README.md
```

## Author

**Dhruv Das** — B.Tech ECE, Sardar Vallabhbhai National Institute of Technology, Surat
[LinkedIn](https://linkedin.com/in/dhruvdassvnit)
