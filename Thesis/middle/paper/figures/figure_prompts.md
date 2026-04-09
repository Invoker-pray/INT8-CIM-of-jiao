# AI Image Generation Prompts for CIM Thesis Figures

## Research Basis

Prompts are designed referencing the figure styles of the following top-tier publications:

- **ISSCC 2022–2025**: ReDCIM, TranCIM, MulTCIM (Fengbin Tu et al.)
- **JSSC 2022–2024**: Scalable CIM Inference Accelerator (Verma et al.), ReDCIM extended
- **Nature Electronics 2023**: "A full spectrum of computing-in-memory technologies" (Sebastian et al.)
- **Nature Electronics 2022**: 3D VRRAM-based nvCIM macro (Huo et al.)
- **JOS 2022**: "A review on SRAM-based computing in-memory" (comprehensive survey)
- **ISSCC 2024 Session 34**: Compute-in-Memory session overview papers

Common academic figure style characteristics observed:

- Clean vector graphics, white/light background
- Color-coded functional blocks (blue for compute, green for memory, orange for control, red/pink for I/O)
- Thin black outlines, sans-serif labels (Arial/Helvetica)
- Data flow arrows with bus width annotations (e.g., "128b", "32b")
- Consistent use of rounded-corner rectangles for modules
- Signal/bus names in monospace font
- Professional but not overly decorative

---

## Figure 1: Von Neumann vs. CIM Architecture Comparison

**Position**: Section 1.1 (选题背景), after discussing the memory wall problem
**LaTeX label**: `fig:vonneumann_vs_cim`

```
Academic technical diagram comparing von Neumann architecture versus Computing-in-Memory (CIM) architecture, side-by-side layout on white background, IEEE journal figure style.

LEFT SIDE labeled "(a) Traditional von Neumann Architecture": A CPU block (light blue rectangle with rounded corners) at top connected via a narrow double-headed arrow labeled "Data Bus (Bandwidth Bottleneck)" to a separate Memory block (light green rectangle) at bottom. The CPU contains sub-blocks "ALU" and "Control Unit". The Memory block contains "Weight Storage" and "Activation Storage". Red lightning bolt icon on the data bus indicating bottleneck. A curved red arrow around the bus labeled "Frequent Data Movement" with energy cost annotation "~200× energy vs. compute".

RIGHT SIDE labeled "(b) Computing-in-Memory Architecture": A single unified block with merged compute and storage. The block is a large green rectangle labeled "CIM Array" containing a grid pattern of small cells. Each cell has a tiny multiply symbol inside. Input vectors enter from the left side with blue arrows, output partial sums exit from the bottom with orange arrows. A small annotation "Compute happens HERE inside memory" with an arrow pointing to the array cells. The boundary between compute and memory is shown as a dashed line that is crossed out, indicating fusion.

Bottom comparison bar: left side shows high data movement with red bars, right side shows minimal data movement with green bars. Clean sans-serif font labels (Arial/Helvetica), thin black outlines, no decorative elements, professional technical illustration suitable for IEEE/Nature Electronics publication. Vector graphics style, sharp edges, consistent line weights.
```

---

## Figure 2: CIM Technology Roadmap / Classification

**Position**: Section 1.2 (国内外现状), showing taxonomy of CIM approaches
**LaTeX label**: `fig:cim_taxonomy`

```
Academic taxonomy diagram of Computing-in-Memory technologies, hierarchical tree structure on white background, IEEE conference paper style similar to ISSCC session overview figures.

Top-level root node: "Computing-in-Memory (CIM)" in a dark blue rounded rectangle.

FIRST LEVEL branches into two categories with connecting lines:
- "Analog CIM" (light orange block)
- "Digital CIM" (light blue block, highlighted with a subtle glow or thicker border to indicate this work's focus)

SECOND LEVEL under "Analog CIM":
- "RRAM/ReRAM Crossbar" (contains sub-labels: ISAAC, PRIME, PUMA)
- "SRAM Analog" (contains sub-labels: charge-domain, current-domain)
- "Other NVM" (contains sub-labels: PCM, MRAM, FeFET)

SECOND LEVEL under "Digital CIM":
- "Bit-serial DCIM" (contains sub-label: bitwise Boolean)
- "Multi-bit DCIM" (contains sub-labels: booth multiplier, shift-add)
- "Full-precision DCIM" (contains sub-labels: INT8/BF16 MAC, highlighted with a red dashed border and star marker labeled "This Work")

THIRD LEVEL characteristics shown as small tag labels beneath each category:
Analog: "High density, ADC needed, noise-sensitive"
Digital: "Exact computation, CMOS compatible, scalable precision"

A timeline arrow at the bottom spanning from left (2016) to right (2025) showing the evolution trend: "Low-bit analog → Multi-bit analog → Digital CIM → Reconfigurable FP/INT CIM processors"

Key representative works annotated with small citation markers: [ISSCC'20], [ISSCC'22 ReDCIM], [ISSCC'23 TranCIM], [ISSCC'24 3nm DCIM].

Clean vector style, white background, consistent rounded-corner rectangles, thin connecting lines with arrow tips, sans-serif font throughout, color-coded by category. Suitable for academic journal publication.
```

---

## Figure 3: 16×16 CIM Tile Internal Architecture

**Position**: Section 2.2 (CIM Tile设计), core contribution
**LaTeX label**: `fig:cim_tile`

```
Detailed academic block diagram of a 16x16 INT8 Computing-in-Memory Tile internal architecture, ISSCC/JSSC publication figure style, white background, vector graphics.

STRUCTURE: A 16-row by 16-column grid of small compute cells. Each cell is a tiny light blue square containing a multiplication symbol "×".

INPUT SIDE (left): A vertical column of 16 input registers labeled "x_eff[0]" through "x_eff[15]", each showing "9-bit unsigned" in small text. Each input broadcasts horizontally across its row via thin blue arrows spanning all 16 columns. The input source is labeled "Input Buffer (after zero-point subtraction)".

WEIGHT SIDE (top): 16 columns of weight values entering from the top, labeled "w[r][0]" through "w[r][15]" with "Signed INT8" annotation. These come from "Weight SRAM (16-bank)".

INTERNAL COMPUTATION: Within each row, a chain of adders connects the cells from left to right. Each cell computes "x_eff[c] × w[r][c]" and the results chain-accumulate: "row_acc[c+1] = row_acc[c] + x_eff[c] × w[r][c]". Show the chain accumulation with small "+" symbols between adjacent cells and thin arrows flowing left-to-right within each row.

OUTPUT SIDE (right): 16 partial sum outputs labeled "psum[0]" through "psum[15]", each "32-bit signed", flowing rightward into orange output arrows pointing to "Partial Sum Accumulator".

ANNOTATIONS:
- Top-right corner: "256 MACs / cycle (combinational)"
- Data width labels on arrows: "9b" for inputs, "8b" for weights, "32b" for outputs
- A magnified inset box showing one single cell's operation: "x_eff[c] (9b) × w[r][c] (s8b) → 17b product → accumulated to 32b"

Color scheme: light blue for compute cells, light green for weight storage, orange for output path, gray for accumulation chain. Clean thin black borders, Arial font labels, no shadows or 3D effects. Professional IEEE/JSSC quality vector diagram.
```

---

## Figure 4: Weight SRAM 16-Bank Split Architecture

**Position**: Section 2.3.1 (权重SRAM的BRAM推断问题), key engineering contribution
**LaTeX label**: `fig:weight_sram_bank`

```
Academic technical diagram showing the Weight SRAM bank-split architecture solution, side-by-side before/after comparison, IEEE journal figure style, white background.

LEFT SIDE labeled "(a) Original Design (Failed BRAM Inference)":
A single large green rectangle labeled "Weight SRAM" with "2048-bit wide" annotation. Inside shows a memory array grid. An AXI write arrow (32-bit, red) enters from the left with a "bit-select partial write" label. A large red "×" overlay and text "Vivado → Falls back to Registers" with "Resource Explosion!" warning. Below: resource count "~250K FFs (impossible on Zynq-7020)".

RIGHT SIDE labeled "(b) Bank-Split Design (Successful BRAM Inference)":
16 narrow green rectangles stacked vertically, each labeled "Bank 0" through "Bank 15", each "128-bit wide × 392 deep". Each bank has a small "BRAM ✓" checkmark icon.

Between the AXI interface and the banks, show a "Staging Register" mechanism:
- 4 sequential 32-bit AXI writes (labeled "chunk 0", "chunk 1", "chunk 2", "chunk 3") feed into a staging register block
- The staging register accumulates to 128 bits
- A single "whole-word write" arrow (128-bit, thick green) goes from the staging register to the selected bank
- A "Bank Select" decoder (small triangle/mux) routes the write to the correct bank based on "tile_row index"

READ PATH: On the right side of the banks, all 16 banks output simultaneously via "16 × 128b parallel read" arrows (blue), merging into a wide bus "2048b → CIM Tile" feeding the tile.

ANNOTATION: "Key insight: Vivado BRAM inference requires whole-word writes. Bit-select writes → register fallback."

Color scheme: green for memory, blue for read path, red/orange for write path, gray for control logic. Clean vector style, thin outlines, sans-serif labels, suitable for ISSCC/JSSC publication.
```

---

## Figure 5: INT8 Quantization Datapath

**Position**: Section 2.4 (量化与重定标), showing the complete quantization pipeline
**LaTeX label**: `fig:quant_datapath`

```
Academic horizontal dataflow diagram showing the complete INT8 quantization and inference pipeline, IEEE/JSSC publication figure style, white background, left-to-right flow.

PIPELINE STAGES shown as a horizontal chain of processing blocks connected by arrows:

STAGE 1 "Input Preparation" (light blue block):
- Input: "UINT8 pixel [0,255]" (8-bit, shown entering from left)
- Operation: "- input_zp (= -128)" shown inside block
- Output: "x_eff: UINT9 [128,383]"
- Arrow labeled "9b unsigned"

STAGE 2 "MAC (CIM Tile)" (medium blue block, largest block):
- Two inputs: x_eff (9b) from Stage 1, and "w[r][c]: INT8 [-128,127]" entering from top (from Weight SRAM, green)
- Operation: "Σ x_eff[c] × w[r][c]" shown inside
- Output arrow labeled "32b signed"
- Annotation: "16×16 = 256 MACs"

STAGE 3 "Bias Accumulation" (teal block):
- Two inputs: partial sum (32b) from Stage 2, and "bias: INT32" entering from top (from Bias SRAM, green)
- Operation: "psum + bias" shown inside
- Output arrow labeled "32b signed"

STAGE 4 "Activation (ReLU)" (orange block):
- Input: 32b from Stage 3
- Operation: "max(0, x)" or "clamp" or "none" shown with switch icon
- Output arrow labeled "32b signed"
- Small annotation: "ACT_MODE via CSR"

STAGE 5 "Requantization" (red/pink block):
- Input: 32b from Stage 4
- Operations shown in sub-stages inside:
  - "× requant_mult" → "64b intermediate"
  - ">> requant_shift (with rounding)" → "shift + round-half-up"
  - "clamp [-128, 127]"
- Output: "INT8 [-128,127]" arrow labeled "8b signed"

STAGE 6 "Output Buffer" (light gray block):
- Stores final INT8 results
- Small "argmax" logic shown as sub-block

Below the main pipeline, a thin horizontal bar shows BIT-WIDTH PROGRESSION: 8b → 9b → 17b (product) → 32b (accumulated) → 64b (requant multiply) → 32b (shifted) → 8b (output). Each width annotated at the corresponding stage.

Color gradient from cool blue (input) to warm orange/red (output). Clean vector graphics, consistent block heights, aligned arrows, sans-serif font. Publication-quality technical diagram.
```

---

## Figure 6: 7-Stage Pipeline FSM State Transition Diagram

**Position**: Section 2.6 (7级流水线状态机)
**LaTeX label**: `fig:fsm_states`

```
Academic finite state machine (FSM) diagram showing the 17-state CIM accelerator core state transitions, IEEE/JSSC publication figure style, white background.

LAYOUT: States arranged in a structured flow pattern (not random bubble placement), grouped into three visual regions with light colored background shading:

REGION 1 "Initialization" (light gray background):
- ST_IDLE (double-circled, start state): "Wait for start signal"
- ST_LOAD_CFG: "Load layer parameters from CSR"
- Arrow from IDLE to LOAD_CFG labeled "start=1"

REGION 2 "Compute Pipeline" (light blue background, labeled "Per Input-Block Iteration"):
- ST_FETCH: "Issue BRAM read address"
- ST_WAIT_SRAM: "Wait 1-cycle BRAM latency"
- ST_XEFF_REG: "Zero-point subtraction + latch x_eff"
- ST_MAC: "CIM Tile MAC + latch psum"
- ST_COMPUTE: "Accumulate partial sum"
- Sequential arrows connecting these 5 states
- A loop-back arrow from ST_COMPUTE to ST_FETCH labeled "ib_cnt < N_IB" (dashed blue)

REGION 3 "Output Pipeline" (light orange background, labeled "Per Output Neuron"):
- ST_BIAS_ADD: "Add bias"
- ST_ACTIVATE: "ReLU activation"
- ST_STORE: "64-bit requant multiply"
- ST_SHIFT_CLAMP: "Shift + round + clamp"
- ST_WRITE_OBUF: "Write to output buffer"
- Sequential arrows connecting these 5 states
- Loop-back from ST_WRITE_OBUF to ST_FETCH labeled "ob_cnt < N_OB" (dashed orange)

COMPLETION PATH:
- ST_ARGMAX: "Compute argmax prediction"
- ST_DONE: "Set done flag, optional IRQ"
- Arrow from DONE back to IDLE labeled "ack/reset"

Each state is a rounded rectangle with state name in bold and brief description in smaller text below. Transition arrows are labeled with conditions. Critical path annotations: "~10ns" on MAC, "~4ns" on COMPUTE.

Side annotation: Pipeline timing table showing:
| Stage | Operation | Critical Path |
| FETCH | BRAM addr | ~2ns |
| WAIT_SRAM | 1-cycle read | - |
| XEFF_REG | subtract+clamp | ~10ns |
| MAC | 16-element chain | ~10ns |
| COMPUTE | 32b addition | ~4ns |

Color-coded state circles: gray for idle/config, blue for compute pipeline, orange for output pipeline, green for completion. Clean vector graphics, consistent state sizes, clear arrow routing without crossings. Suitable for ISSCC/JSSC publication.
```

---

## Figure 7: Pipeline Timing Diagram

**Position**: Section 2.6, supplementary to the FSM diagram
**LaTeX label**: `fig:pipeline_timing`

```
Academic pipeline timing diagram showing the overlapping execution of CIM accelerator stages across multiple input-block iterations, horizontal timeline format, IEEE/JSSC publication figure style, white background.

FORMAT: Horizontal timeline (left to right = clock cycles), vertical axis shows pipeline stages.

Y-AXIS LABELS (top to bottom):
- "FETCH + WAIT_SRAM"
- "XEFF_REG"
- "MAC"
- "COMPUTE"
- "BIAS/ACT/REQUANT/WRITE"

X-AXIS: Clock cycle numbers 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, ...

CONTENT: Colored blocks showing the pipeline execution for consecutive input-block iterations:

IB iteration 0 (light blue blocks):
- FETCH at cycle 1-2
- XEFF_REG at cycle 3
- MAC at cycle 4
- COMPUTE at cycle 5

IB iteration 1 (medium blue blocks):
- FETCH at cycle 3-4
- XEFF_REG at cycle 5
- MAC at cycle 6
- COMPUTE at cycle 7

IB iteration 2 (dark blue blocks):
- Similar pattern shifted by 2 cycles

After all IB iterations complete:
- BIAS/ACT/REQUANT/WRITE stages shown as orange blocks in sequence

ANNOTATIONS:
- Bracket showing "4 cycles / IB iteration"
- Arrow showing "Pipeline bubble: 2 extra cycles vs. ideal"
- Total cycle count formula: "Total = N_IB × 4 + 5 (output pipeline) per output neuron"
- Small table: "FC1 (784→128): N_IB=49, cycles ≈ 49×4×8+overhead = 3136"

Clean grid lines, colored blocks with thin borders, no 3D effects. Standard CPU pipeline diagram format adapted for CIM accelerator. Sans-serif font labels.
```

---

## Figure 8: PicoRV32 + CIM SoC Architecture (replacing ASCII art)

**Position**: Section 3.2 (系统架构), replacing the current verbatim ASCII diagram
**LaTeX label**: `fig:rv32_arch`

```
Professional SoC block diagram showing PicoRV32 RISC-V soft-core integrated with CIM accelerator IP on PYNQ-Z2 (Zynq-7020) platform, IEEE/JSSC publication figure style, white background.

LAYOUT: Two main domains separated by a dashed vertical line:

LEFT DOMAIN labeled "PL (Programmable Logic)" with light blue background:

- "PicoRV32 RV32IM" block (dark blue rectangle, prominent): labeled "RISC-V Soft Core, ~1500 LUT, 50 MHz"
- Connected downward via "Wishbone Native Interface" bus to:
- "picorv32_cim_bridge" block (medium blue): "Address Decoder + Bus Bridge"

The bridge fans out to 4 targets via labeled buses:
1. → "FW BRAM (32KB)" (green rectangle, dual-port): "Port A: RV32 instruction/data fetch" shown on left port, "Port B: PS firmware loading" shown on right port with arrow going to PS domain
2. → "CIM Accelerator IP" (large orange rectangle, unchanged from Step 2): contains sub-blocks "AXI4-Lite Slave", "CIM Tile 16×16", "Weight SRAM", "FSM Engine". Bridge-to-CIM connection labeled "Mini AXI Master → identical AXI transactions"
3. → "UART TX" (small gray rectangle): "Debug output, 115200 baud"
4. → "Result BRAM (256B)" (small green rectangle, dual-port): "Port A: RV32 writes results" on left, "Port B: PS reads results" on right with arrow to PS domain

RIGHT DOMAIN labeled "PS (Processing System)" with light pink background:
- "ARM Cortex-A9" block (gray): "Dual-core 650MHz"
- Connected via "AXI Interconnect" to:
  - FW BRAM Port B (for firmware loading)
  - Result BRAM Port B (for reading results)
  - "AXI GPIO" block (small): "cpu_rst_n control signal" with arrow to PicoRV32

CONTROL FLOW annotation at bottom: "Boot sequence: PS holds reset → writes firmware.hex to FW BRAM → releases cpu_rst_n → RV32 runs autonomously"

BUS WIDTH annotations: "32b" on Wishbone, "32b" on AXI, "14b addr" on CIM CSR.

Color scheme: dark blue for RV32 core, orange for CIM IP (emphasizing it is UNMODIFIED), green for BRAMs, gray for PS/ARM, light colors for domain backgrounds. Clean vector style, rounded rectangle blocks, thin connecting lines with directional arrows, bus width labels in small monospace font. Publication-quality technical diagram suitable for JSSC/TCAS paper.
```

---

## Figure 9: PicoRV32 Address Space Map

**Position**: Section 3.3 (Bus Bridge与地址映射)
**LaTeX label**: `fig:rv32_addr_map`

```
Academic memory map / address space visualization diagram, vertical bar chart style, IEEE journal figure style, white background.

FORMAT: A tall vertical rectangular bar representing the full 32-bit address space of PicoRV32, with different colored segments for each mapped peripheral.

THE BAR (from bottom address 0x0 to top):

SEGMENT 1 (bottom, large, green):
- Address range: 0x0000_0000 — 0x0000_7FFF
- Size: 32 KB
- Label: "FW BRAM (Code + Data)"
- Sub-annotation: "C firmware + INT8 weights + biases + input data"
- Usage bar showing ~18.5KB used out of 32KB

SEGMENT 2 (middle, large, orange):
- Address range: 0x4000_0000 — 0x4000_3FFF
- Size: 16 KB
- Label: "CIM CSR + Storage Windows"
- Expanded sub-view showing internal layout:
  - 0x4000_0000–0x004C: "Control/Status/Config Registers"
  - 0x4000_0100–0x02FF: "Logits Readback"
  - 0x4000_1000–0x1FFF: "Input Buffer Write"
  - 0x4000_2000–0x2FFF: "Bias Buffer Write"
  - 0x4000_0044–0x004C: "Weight DMA Registers"

SEGMENT 3 (small, gray):
- Address range: 0x8000_0000 — 0x8000_0007
- Size: 8 B
- Label: "UART TX (Data + Status)"

SEGMENT 4 (small, light blue):
- Address range: 0xC000_0000 — 0xC000_00FF
- Size: 256 B
- Label: "Result BRAM"
- Sub-annotation: "prediction + logits + magic marker"

Gaps between segments shown as hatched/diagonal-lined regions labeled "Unmapped (bus fault)".

Right side: Bridge decode logic shown as a simple decision tree: "addr[31:30] = 00 → FW BRAM, 01 → CIM, 10 → UART, 11 → Result BRAM"

Clean vertical layout, color-coded segments, clear address labels in monospace font, thin black borders. Professional IEEE publication style.
```

---

## Figure 10: Three-Layer Verification Methodology

**Position**: Section 4.1 (验证方法学)
**LaTeX label**: `fig:verification_flow`

```
Academic verification methodology flow diagram showing the three-layer verification approach, top-to-bottom flow, IEEE/JSSC publication figure style, white background.

THREE HORIZONTAL LAYERS stacked vertically:

LAYER 1 "Python Golden Model" (top, light yellow background):
- Central block: "golden_model.py" (yellow rectangle with code icon)
- Description: "Pure integer arithmetic, bit-accurate reference"
- Inputs from left: "MNIST images", "INT8 weights", "Quantization params"
- Outputs flowing downward:
  - "hex test vectors" (arrow going to Layer 2)
  - "expected logits" (arrow going to Layer 3)
  - "reference predictions" (arrow going to Layer 3)
- Operations listed inside: "Zero-point sub → MVM → Bias → ReLU → Requant"

LAYER 2 "VCS RTL Simulation" (middle, light blue background):
- Three sub-blocks arranged horizontally:
  - "tb_cim_tile" (small): "Unit test: 103 random vectors"
  - "tb_cim_accel_core" (medium): "System MVM: random + boundary cases"
  - "tb_mnist_e2e" (large): "End-to-end: MLP 784→128→10"
- Input from Layer 1: hex test vectors
- Comparison block: "Element-wise comparison" with checkmark
- Output: "PASS/FAIL per test" + "Waveform dumps for debug"
- "run_regression.sh" annotation: "Automated one-click regression"

LAYER 3 "PYNQ-Z2 Board Verification" (bottom, light green background):
- Board icon/photo placeholder of PYNQ-Z2
- "CIMModel driver (Python)" block connected to board
- Two test configurations shown side by side:
  - "MLP: 20 images → 100% accuracy, 100% bit-exact"
  - "LeNet-5: 200 images → 99.5% accuracy, 100% bit-exact"
- Comparison: "vs. Python golden model logits" with green checkmark
- PicoRV32 path: "200 images → 96.5% accuracy, 100% bit-exact vs ARM path"

VERTICAL ARROWS between layers labeled:
- Layer 1→2: "hex vectors, expected outputs"
- Layer 2→3: "bitstream + hwh (Vivado synthesis)"
- Dashed consistency arrows: "Bit-exact match verified at every layer"

Annotation at right side: "Key principle: Same computation verified at three levels of abstraction with bit-exact consistency"

Clean flow diagram, color-coded layers, rounded rectangles, directional arrows with labels, sans-serif font throughout. Suitable for ISSCC/JSSC extended paper.
```

---

## Figure 11: FPGA Resource Utilization Bar Chart

**Position**: Section 4.2 (PYNQ-Z2综合结果)
**LaTeX label**: `fig:resource_util`

```
Academic bar chart showing FPGA resource utilization for the CIM SoC on PYNQ-Z2 (Zynq-7020), IEEE journal figure style, white background, clean and minimal.

FORMAT: Grouped vertical bar chart with 4 resource categories on X-axis.

X-AXIS categories: "LUT", "FF", "BRAM", "DSP"

Y-AXIS: "Utilization (%)" from 0% to 100%, with grid lines at 25% intervals.

TWO BARS per category (grouped):
- Blue bar: "ARM Control Mode (60 MHz)"
- Orange bar: "PicoRV32 Mode (50 MHz)"

VALUES:
- LUT: Blue = 20.84%, Orange = 23.90%
- FF: Blue = 5.06%, Orange = 5.89%
- BRAM: Blue = 24.29%, Orange = 31.43%
- DSP: Blue = 100%, Orange = 100%

ANNOTATIONS:
- On the DSP bars: "220/220 (fully utilized)" with a small note
- Delta labels between paired bars: "+1627 LUT", "+887 FF", "+9 BRAM", "+0 DSP" showing PicoRV32 overhead
- A horizontal dashed red line at 100% labeled "Device Limit"
- Small text below chart: "Platform: Zynq-7020 (xc7z020clg400-1) on PYNQ-Z2"

Clean minimal style, no 3D effects, thin bar borders, legend in top-right corner. Sans-serif font, professional IEEE/Nature journal quality.
```

---

## Figure 12: MNIST Classification Results Visualization

**Position**: Section 4.4 (LeNet-5 CNN推理验证)
**LaTeX label**: `fig:mnist_results`

```
Academic result visualization showing MNIST handwritten digit classification results from FPGA hardware inference, clean grid layout, IEEE/JSSC publication figure style, white background.

FORMAT: A grid of small MNIST digit images with prediction labels, showing representative results from the 200-image LeNet-5 test.

LAYOUT: 4 rows × 5 columns = 20 sample images.

Each cell contains:
- A 28×28 grayscale handwritten digit image (white digit on black background)
- Below the image: "Label: X" and "Pred: Y" in small text
- A colored border: GREEN for correct predictions, RED for the single misclassification

GRID CONTENTS (representative):
- 19 cells with green borders showing correctly classified digits (diverse digits 0-9)
- 1 cell (highlighted, slightly larger) with red border: "img_0018, Label: 3, Pred: 8" with annotation arrow: "Quantization precision loss (matches Python golden model)"

BELOW THE GRID, a summary statistics box:
- "Hardware Classification Accuracy: 199/200 = 99.5%"
- "Bit-exact Match vs. Golden Model: 200/200 = 100.0%"
- "Computation Errors: 0"
- "Note: The single misclassification is due to INT8 quantization, NOT hardware error"

RIGHT SIDE: A small confusion-style annotation showing the misclassified digit 3 that looks ambiguous and could be confused with 8, with an arrow explaining "Ambiguous handwriting + quantization → model classifies as 8 in both HW and SW"

Clean presentation, minimal decoration, professional academic figure. Grid borders thin and consistent. Sans-serif labels.
```

---

## Figure 13: Speedup Comparison Bar Chart

**Position**: Section 4.5 (加速比分析)
**LaTeX label**: `fig:speedup`

```
Academic grouped bar chart comparing software baseline latency versus CIM hardware inference latency, with speedup annotations, IEEE journal figure style, white background.

FORMAT: Grouped bar chart with logarithmic Y-axis.

X-AXIS categories: "MLP (784→128→10)", "LeNet-5 (Sequential)", "LeNet-5 (Batched BLAS)"

Y-AXIS (log scale): "Inference Latency (μs)" from 10 to 100,000.

TWO BARS per category:
- Light red/coral bar: "ARM Cortex-A9 SW Baseline (NumPy @ 650 MHz)"
- Dark blue bar: "CIM Hardware (@ 60 MHz)"

VALUES:
- MLP: SW = 1,410.8 μs, HW = 54.7 μs
- LeNet-5 Sequential: SW = 26,466.2 μs, HW = 1,267.2 μs
- LeNet-5 Batched: SW = 4,528.5 μs, HW = 1,267.2 μs

SPEEDUP ANNOTATIONS:
- Above each pair: bold speedup value in a rounded box
  - MLP: "25.8×" (large, bold, dark green)
  - LeNet-5 Seq: "20.9×" (large, bold, dark green)
  - LeNet-5 Batched: "3.6×" (smaller, blue, with note "optimized SW baseline")

ANNOTATIONS:
- Arrow pointing to sequential comparison: "Fair comparison: same per-pixel compute pattern"
- Arrow pointing to batched: "Upper bound: fully batched BLAS optimization"
- Note at bottom: "CIM @ 60 MHz vs. ARM Cortex-A9 @ 650 MHz (10.8× lower clock frequency)"

Clean bars, thin borders, no 3D effects. Log scale clearly labeled. Legend in upper-left corner. Professional IEEE/Nature journal style.
```

---

## Figure 14: ARM vs. PicoRV32 Control Mode Radar Chart

**Position**: Section 4.7 (两种控制模式对比)
**LaTeX label**: `fig:arm_vs_rv32`

```
Academic radar (spider) chart comparing ARM control mode versus PicoRV32 control mode across multiple dimensions, IEEE/JSSC publication figure style, white background.

FORMAT: Hexagonal radar chart with 6 axes.

AXES (clockwise from top):
1. "Clock Frequency" (normalized: ARM=60MHz=1.0, RV32=50MHz=0.83)
2. "Timing Closure" (ARM: WNS=-0.086ns=0.8, RV32: WNS=+0.204ns=1.0)
3. "LUT Efficiency" (inverse of usage: ARM=1.0, RV32=0.87 since it uses more)
4. "BRAM Efficiency" (inverse: ARM=1.0, RV32=0.80)
5. "Power Efficiency" (inverse of dynamic power: ARM=0.96, RV32=1.0 since lower power)
6. "Autonomy" (ARM=0.5 needs PS Python, RV32=1.0 pure PL)

TWO OVERLAPPING POLYGONS:
- Blue polygon with blue fill (semi-transparent): "ARM Control (60 MHz)"
- Orange polygon with orange fill (semi-transparent): "PicoRV32 Control (50 MHz)"

ANNOTATIONS on each axis showing actual values:
- Frequency: "60 MHz" / "50 MHz"
- Timing: "WNS -0.086ns" / "WNS +0.204ns ✓"
- LUT: "11,087 (20.84%)" / "12,714 (23.90%)"
- BRAM: "35 (25.0%)" / "44 (31.4%)"
- Power: "1.807W" / "1.745W"
- Autonomy: "Requires PS" / "Pure PL"

LEGEND in top-right corner.
TITLE: "Multi-dimensional Comparison of Control Modes"
SUBTITLE: "CIM IP identical in both modes — 100% bit-exact results"

Clean line art, semi-transparent fills, consistent line weights, sans-serif font. Professional but not overly decorative. Suitable for academic publication.
```

---

## Figure 15: Vivado Floorplan Layout Placeholder

**Position**: Section 4.2, after resource utilization table
**LaTeX label**: `fig:floorplan`

```
Academic FPGA floorplan diagram showing the physical placement of CIM SoC components on Zynq-7020 die, Vivado implementation view style, simplified and annotated for publication.

FORMAT: Rectangular chip die outline representing the Zynq-7020 PL fabric, with color-coded resource placement regions.

OVERALL LAYOUT:
- Die outline: dark gray border rectangle
- PS (ARM) region: solid gray block on the left side, labeled "PS7 (ARM Cortex-A9 + DDR Controller)" — non-programmable, shown as opaque

PL FABRIC (right portion, the main area):
- Background: light gray grid representing CLB fabric

COLOR-CODED REGIONS:
- BLUE scattered blocks: "LUT Logic (CIM FSM, Bridge, AXI)" — distributed across fabric
- GREEN vertical columns: "BRAM Columns" — two vertical stripes showing BRAM tile placement
  - Highlighted BRAMs labeled: "Weight SRAM (16 banks)", "Bias SRAM", "Input/Output Buffers", "FW BRAM (RV32)"
- RED/PINK regular grid: "DSP48E1 Columns" — two vertical columns FULLY OCCUPIED
  - Annotation: "220/220 DSP48 — 100% utilized"
  - Individual DSPs colored solid red indicating full usage

ANNOTATIONS with leader lines:
- Arrow to DSP columns: "CIM Tile MAC operations"
- Arrow to BRAM columns: "Weight + Bias + I/O storage"
- Arrow to logic area: "FSM + AXI + PicoRV32"
- Clock region boundaries shown as thin dashed lines

STATISTICS BOX in corner:
"Zynq-7020 (xc7z020clg400-1)"
"LUT: 20.84% | FF: 5.06%"
"BRAM: 25% | DSP: 100%"
"60 MHz (ARM) / 50 MHz (RV32)"

Clean technical illustration, colored blocks on light background, clear annotations, consistent labeling. Resembling a simplified Vivado Device view suitable for academic publication.
```

---

## Notes on Using These Prompts

### Recommended AI Image Generation Tools

1. **For technical block diagrams (Figs 1,3,4,5,6,8,9,10)**: Best generated with diagram tools like draw.io/Lucidchart, or SVG code generation. AI image generators may produce aesthetically pleasing but technically inaccurate diagrams. Consider using these prompts as specifications for manual drawing tools.

2. **For charts (Figs 11,13,14)**: Generate using matplotlib/Python with the style specifications, then export as vector PDF/SVG.

3. **For the MNIST visualization (Fig 12)**: Use actual MNIST test images from your experiments combined with matplotlib annotation.

4. **For the floorplan (Fig 15)**: Use a Vivado screenshot as base, then annotate and clean up for publication.

### Style Consistency Checklist

- [ ] All figures use the same font family (Arial or Helvetica)
- [ ] Color scheme is consistent across all figures (blue=compute, green=memory, orange=output/control)
- [ ] Line weights are consistent (0.5pt for thin lines, 1pt for borders, 1.5pt for emphasis)
- [ ] All text is readable at the final printed size (minimum 7pt)
- [ ] White background on all figures
- [ ] No 3D effects, shadows, or gradients (except where specified)
- [ ] Bus width annotations use monospace font
- [ ] All figures have proper (a), (b), (c) sub-labels where applicable
