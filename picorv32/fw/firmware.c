// ============================================================================
// firmware.c — RISC-V firmware for CIM SoC MNIST inference (multi-image batch)
// ============================================================================
// Phase B/C optimizations: double-buffer ping-pong + layer fusion + weight_base
// Clock: 100 MHz (TILE_SPLIT_FACTOR=4)
//
// Multi-image handshake protocol (via Result BRAM port A/B):
//   FW sets  RES_WORD(0) = 0xC1AA0001 → "inference done, results ready"
//   PS reads results, writes RES_WORD(0) = 0x00000000 → "go for next image"
//   PS writes IMAGE_BUF in FW BRAM (0x6000) before signaling go
//   PS writes RES_WORD(0) = 0xDEADBEEF → "end of benchmark"
//
// FW BRAM image buffer layout (PS writes at 0x4000_6000):
//   [0..3]   expected_label (uint32 LE)
//   [4..787] image pixels (784 bytes uint8)
//
// Result BRAM layout (word-addressed from 0xC000_0000):
//   [0]  magic      = 0xC1AA_0001 (signals "inference complete")
//   [1]  predicted  = argmax class (0-9)
//   [2]  expected   = true label (from IMAGE_BUF)
//   [3]  match      = 1 if pred==label, 0 otherwise
//   [4..13] logits  = fc2 output[0..9], sign-extended INT8→INT32
// ============================================================================

#include <stdint.h>

// ============================================================================
// Hardware registers
// ============================================================================
#define CIM_BASE 0x40000000
#define CIM_CTRL (*(volatile uint32_t *)(CIM_BASE + 0x000))
#define CIM_STATUS (*(volatile uint32_t *)(CIM_BASE + 0x004))
#define CIM_IN_DIM (*(volatile uint32_t *)(CIM_BASE + 0x010))
#define CIM_OUT_DIM (*(volatile uint32_t *)(CIM_BASE + 0x014))
#define CIM_N_IB (*(volatile uint32_t *)(CIM_BASE + 0x018))
#define CIM_N_OB (*(volatile uint32_t *)(CIM_BASE + 0x01C))
#define CIM_REQUANT_MULT (*(volatile uint32_t *)(CIM_BASE + 0x020))
#define CIM_REQUANT_SHIFT (*(volatile uint32_t *)(CIM_BASE + 0x024))
#define CIM_INPUT_ZP (*(volatile uint32_t *)(CIM_BASE + 0x028))
#define CIM_ACT_MODE (*(volatile uint32_t *)(CIM_BASE + 0x02C))
#define CIM_PRED_CLASS (*(volatile uint32_t *)(CIM_BASE + 0x040))
#define CIM_WDMA_ADDR (*(volatile uint32_t *)(CIM_BASE + 0x044))
#define CIM_WDMA_DATA (*(volatile uint32_t *)(CIM_BASE + 0x048))
#define CIM_WDMA_CTRL (*(volatile uint32_t *)(CIM_BASE + 0x04C))
#define CIM_LOGIT(i) (*(volatile uint32_t *)(CIM_BASE + 0x100 + 4 * (i)))
#define CIM_INPUT(i) (*(volatile uint32_t *)(CIM_BASE + 0x1000 + 4 * (i)))
#define CIM_BIAS(i) (*(volatile uint32_t *)(CIM_BASE + 0x2800 + 4 * (i)))

#define CIM_PING_CTRL (*(volatile uint32_t *)(CIM_BASE + 0x06C))
#define CIM_FUSION_CTRL (*(volatile uint32_t *)(CIM_BASE + 0x070))
#define CIM_FUSION_LEN (*(volatile uint32_t *)(CIM_BASE + 0x074))
#define CIM_FUSION_STATUS (*(volatile uint32_t *)(CIM_BASE + 0x078))
#define CIM_WEIGHT_BASE (*(volatile uint32_t *)(CIM_BASE + 0x07C))
#define CIM_BIAS_BASE (*(volatile uint32_t *)(CIM_BASE + 0x080))

// Result BRAM (firmware side = 0xC000_0000, PS side = 0x4200_0000)
#define RES_BASE 0xC0000000
#define RES_WORD(i) (*(volatile uint32_t *)(RES_BASE + 4 * (i)))
#define RES_MAGIC 0xC1AA0001
#define RES_GO_SIGNAL 0x00000000
#define RES_STOP_SIGNAL 0xDEADBEEF

// PS-loaded image buffer in FW BRAM
// FW BRAM is at 0x0000_0000 (firmware side) = 0x4000_0000 (PS side)
// Buffer at offset 0x6000 — well after code+data (~15KB), before stack (0x7FFC)
#define IMAGE_BUF ((volatile uint8_t *)0x00006000)
#define IMAGE_BUF_SIZE (4 + 784) // label(uint32 LE) + pixels(784 × uint8)

// UART
#define UART_TX_DATA (*(volatile uint32_t *)0x80000000)
#define UART_TX_STATUS (*(volatile uint32_t *)0x80000004)

// ============================================================================
// UART output (minimal for debug)
// ============================================================================
static void uart_putc(char c) {
    while (!(UART_TX_STATUS & 1))
        ;
    UART_TX_DATA = (uint32_t)c;
}
static void uart_puts(const char *s) {
    while (*s)
        uart_putc(*s++);
}
static void uart_put_hex(uint32_t v) {
    for (int i = 7; i >= 0; i--) {
        uint8_t nib = (v >> (i * 4)) & 0xF;
        uart_putc(nib < 10 ? '0' + nib : 'A' + nib - 10);
    }
}

// ============================================================================
// CIM control
// ============================================================================
static void cim_soft_reset(void) { CIM_CTRL = 0x4; }

static void cim_configure(uint32_t in_dim, uint32_t out_dim, int32_t zp,
                          uint32_t mult, uint32_t shift, uint32_t relu) {
    CIM_IN_DIM = in_dim;
    CIM_OUT_DIM = out_dim;
    CIM_N_IB = (in_dim + 15) / 16;
    CIM_N_OB = (out_dim + 15) / 16;
    CIM_REQUANT_MULT = mult;
    CIM_REQUANT_SHIFT = shift;
    CIM_INPUT_ZP = (uint32_t)zp;
    CIM_ACT_MODE = relu ? 1 : 0;
}

static void cim_set_weight_base(uint32_t tile_offset) {
    CIM_WEIGHT_BASE = tile_offset;
}
static void cim_set_bias_base(uint32_t word_offset) {
    CIM_BIAS_BASE = word_offset;
}

static void cim_load_weights_burst(const uint32_t *chunks, uint32_t n) {
    CIM_WDMA_ADDR = 0;
    CIM_WDMA_CTRL = 0x02;
    for (uint32_t i = 0; i < n; i++)
        CIM_WDMA_DATA = chunks[i];
    CIM_WDMA_CTRL = 0x00;
}

static void cim_load_weights_at(const uint32_t *chunks, uint32_t n,
                                uint32_t start_tile) {
    CIM_WDMA_ADDR = start_tile;
    CIM_WDMA_CTRL = 0x02;
    for (uint32_t i = 0; i < n; i++)
        CIM_WDMA_DATA = chunks[i];
    CIM_WDMA_CTRL = 0x00;
}

static void cim_load_bias(const uint32_t *bias, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        CIM_BIAS(i) = bias[i];
}
// Load bias at a specific word offset (for multi-layer coexistence)
static void cim_load_bias_at(const uint32_t *bias, uint32_t n,
                             uint32_t base_addr) {
    for (uint32_t i = 0; i < n; i++)
        CIM_BIAS(base_addr + i) = bias[i];
}

static void cim_load_input(const uint8_t *data, uint32_t n) {
    uint32_t padded = ((n + 15) / 16) * 16;
    for (uint32_t i = 0; i < padded; i++)
        CIM_INPUT(i) = (i < n) ? data[i] : 0;
}

// Phase B: toggle IBUF/OBUF bank for ping-pong
static void cim_toggle_bank(void) { CIM_PING_CTRL = 1; }

static void cim_start_and_wait(void) {
    cim_toggle_bank(); // make DMA-loaded data the active compute bank
    CIM_CTRL = 0x2;
    CIM_CTRL = 0x1;
    while (!(CIM_STATUS & 0x2))
        ;
    cim_toggle_bank(); // make results accessible to DMA/fusion reads
}

static int cim_fusion_copy(uint32_t n_elements) {
    CIM_FUSION_LEN = n_elements;
    CIM_FUSION_CTRL = 1;
    for (volatile uint32_t t = 0; t < 100000; t++) {
        if (CIM_FUSION_STATUS & 0x2)
            return 0;
    }
    return 1;
}

// ============================================================================
// Data (from gen_fw_data.py)
// ============================================================================
extern const uint32_t fc1_weight_chunks[];
extern const uint32_t fc1_bias[];
extern const uint32_t fc2_weight_chunks[];
extern const uint32_t fc2_bias[];
extern const uint32_t fc1_n_chunks, fc2_n_chunks;
extern const uint32_t fc1_mult, fc1_shift, fc2_mult, fc2_shift;
extern const int32_t hw_zp1, hw_zp2;

// ============================================================================
// Inference helper — runs one image from IMAGE_BUF, writes result to RES
// ============================================================================
static void run_inference(uint32_t fc1_tiles, uint32_t fc1_bias_words) {
    uint32_t expected = *(volatile uint32_t *)&IMAGE_BUF[0];
    const uint8_t *pixels = &IMAGE_BUF[4];

    // Diagnostic: echo first 16 image bytes + expected to result BRAM[14..18]
    // RES_WORD(14) = expected_label, RES_WORD(15) = sum of first 16 pixels
    // RES_WORD(16..19) = first 16 pixels as 4x uint32
    uint32_t diag_sum = 0;
    for (int di = 0; di < 16; di++)
        diag_sum += (uint32_t)pixels[di];
    RES_WORD(14) = expected;
    RES_WORD(15) = diag_sum;
    RES_WORD(16) = *(volatile uint32_t *)&pixels[0];
    RES_WORD(17) = *(volatile uint32_t *)&pixels[4];
    RES_WORD(18) = *(volatile uint32_t *)&pixels[8];
    RES_WORD(19) = *(volatile uint32_t *)&pixels[12];

    // FC1: 784 → 16, ReLU
    cim_configure(784, 16, hw_zp1, fc1_mult, fc1_shift, 1);
    cim_set_weight_base(0);
    cim_set_bias_base(0);
    cim_load_input(pixels, 784);
    cim_start_and_wait();

    // FC2: 16 → 10, no activation (fusion + weight_base)
    cim_configure(16, 10, hw_zp2, fc2_mult, fc2_shift, 0);
    cim_set_weight_base(fc1_tiles);
    cim_set_bias_base(fc1_bias_words);

    if (cim_fusion_copy(16) != 0) {
        // Manual fallback: read OBUF bytes, write to IBUF
        for (int i = 0; i < 16; i++)
            CIM_INPUT(i) = (uint8_t)CIM_LOGIT(i);
    }
    cim_start_and_wait();

    uint32_t pred = CIM_PRED_CLASS;

    // Write results (magic LAST — signals to PS that all data is valid)
    RES_WORD(1) = pred;
    RES_WORD(2) = expected;
    RES_WORD(3) = (pred == expected) ? 1 : 0;
    for (int i = 0; i < 10; i++) {
        int8_t v = (int8_t)(CIM_LOGIT(i) & 0xFF);
        RES_WORD(4 + i) = (uint32_t)(int32_t)v;
    }
    RES_WORD(0) = RES_MAGIC;
}

// ============================================================================
// Main — load weights once, then loop on PS-loaded images
// ============================================================================
void main(void) {
    RES_WORD(0) = 0;

    uart_puts("\r\n=== CIM RISC-V Benchmark (100MHz, Phase B/C) ===\r\n");

    // Compute tile counts: FC1(784→16) → 49 tiles, bias=16 words
    uint32_t fc1_tiles = (784 / 16) * ((16 + 15) / 16); // 49
    uint32_t fc1_bias_words = 16;

    // --- Pre-load FC1 + FC2 weights (once for all images) ---
    uart_puts("Loading weights...\r\n");
    cim_soft_reset();
    cim_set_weight_base(0);
    cim_set_bias_base(0);
    cim_load_weights_burst(fc1_weight_chunks, fc1_n_chunks);
    cim_load_bias(fc1_bias, fc1_bias_words);
    cim_load_weights_at(fc2_weight_chunks, fc2_n_chunks, fc1_tiles);
    cim_load_bias_at(fc2_bias, 10, fc1_bias_words);
    uart_puts("Ready — waiting for images...\r\n");

    // --- Multi-image benchmark loop ---
    uint32_t n_images = 0;
    while (1) {
        // Wait for PS go signal
        uint32_t cmd = RES_WORD(0);
        if (cmd == RES_STOP_SIGNAL)
            break;
        // PS writes 0 to signal go; spin until non-zero (which is
        // either our own magic from a prior write, or a new signal)
        if (cmd != RES_GO_SIGNAL)
            continue;

        run_inference(fc1_tiles, fc1_bias_words);
        n_images++;
    }

    uart_puts("Benchmark done. Images: ");
    // Print n_images as hex
    uart_put_hex(n_images);
    uart_puts("\r\n=== Done ===\r\n");
    while (1)
        ;
}
