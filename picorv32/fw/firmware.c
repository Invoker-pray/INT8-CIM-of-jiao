// ============================================================================
// firmware.c — RISC-V firmware for CIM SoC MNIST inference
// ============================================================================
// After inference, writes results to Result BRAM (0xC000_0000) so PS can
// read them via MMIO without needing UART/pyserial.
//
// Result BRAM layout (word-addressed from 0xC000_0000):
//   [0]  magic      = 0xC1AA_0001 (signals "inference complete")
//   [1]  predicted  = argmax class (0-9)
//   [2]  expected   = true label
//   [3]  match      = 1 if pred==label, 0 otherwise
//   [4..13] logits  = fc2 output[0..9], sign-extended INT8→INT32
// ============================================================================

#include <stdint.h>

// ============================================================================
// Hardware registers
// ============================================================================
#define CIM_BASE        0x40000000
#define CIM_CTRL        (*(volatile uint32_t*)(CIM_BASE + 0x000))
#define CIM_STATUS      (*(volatile uint32_t*)(CIM_BASE + 0x004))
#define CIM_IN_DIM      (*(volatile uint32_t*)(CIM_BASE + 0x010))
#define CIM_OUT_DIM     (*(volatile uint32_t*)(CIM_BASE + 0x014))
#define CIM_N_IB        (*(volatile uint32_t*)(CIM_BASE + 0x018))
#define CIM_N_OB        (*(volatile uint32_t*)(CIM_BASE + 0x01C))
#define CIM_REQUANT_MULT  (*(volatile uint32_t*)(CIM_BASE + 0x020))
#define CIM_REQUANT_SHIFT (*(volatile uint32_t*)(CIM_BASE + 0x024))
#define CIM_INPUT_ZP    (*(volatile uint32_t*)(CIM_BASE + 0x028))
#define CIM_ACT_MODE    (*(volatile uint32_t*)(CIM_BASE + 0x02C))
#define CIM_PRED_CLASS  (*(volatile uint32_t*)(CIM_BASE + 0x040))
#define CIM_WDMA_ADDR   (*(volatile uint32_t*)(CIM_BASE + 0x044))
#define CIM_WDMA_DATA   (*(volatile uint32_t*)(CIM_BASE + 0x048))
#define CIM_WDMA_CTRL   (*(volatile uint32_t*)(CIM_BASE + 0x04C))
#define CIM_LOGIT(i)    (*(volatile uint32_t*)(CIM_BASE + 0x100 + 4*(i)))
#define CIM_INPUT(i)    (*(volatile uint32_t*)(CIM_BASE + 0x1000 + 4*(i)))
#define CIM_BIAS(i)     (*(volatile uint32_t*)(CIM_BASE + 0x2000 + 4*(i)))

// Result BRAM
#define RES_BASE        0xC0000000
#define RES_WORD(i)     (*(volatile uint32_t*)(RES_BASE + 4*(i)))
#define RES_MAGIC       0xC1AA0001

// UART
#define UART_TX_DATA    (*(volatile uint32_t*)0x80000000)
#define UART_TX_STATUS  (*(volatile uint32_t*)0x80000004)

// ============================================================================
// UART output
// ============================================================================
static void uart_putc(char c) {
    while (!(UART_TX_STATUS & 1));
    UART_TX_DATA = (uint32_t)c;
}
static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}
static void uart_put_dec(int val) {
    if (val < 0) { uart_putc('-'); val = -val; }
    if (val >= 10) uart_put_dec(val / 10);
    uart_putc('0' + (val % 10));
}

// ============================================================================
// CIM control
// ============================================================================
static void cim_soft_reset(void)    { CIM_CTRL = 0x4; }

static void cim_configure(uint32_t in_dim, uint32_t out_dim,
                           int32_t zp, uint32_t mult, uint32_t shift, uint32_t relu) {
    CIM_IN_DIM  = in_dim;  CIM_OUT_DIM = out_dim;
    CIM_N_IB = (in_dim+15)/16;  CIM_N_OB = (out_dim+15)/16;
    CIM_REQUANT_MULT = mult;  CIM_REQUANT_SHIFT = shift;
    CIM_INPUT_ZP = (uint32_t)zp;  CIM_ACT_MODE = relu ? 1 : 0;
}

static void cim_load_weights_burst(const uint32_t *chunks, uint32_t n) {
    CIM_WDMA_ADDR = 0;  CIM_WDMA_CTRL = 0x02;
    for (uint32_t i = 0; i < n; i++) CIM_WDMA_DATA = chunks[i];
    CIM_WDMA_CTRL = 0x00;
}

static void cim_load_bias(const uint32_t *bias, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) CIM_BIAS(i) = bias[i];
}

static void cim_load_input(const uint8_t *data, uint32_t n) {
    uint32_t padded = ((n+15)/16)*16;
    for (uint32_t i = 0; i < padded; i++)
        CIM_INPUT(i) = (i < n) ? data[i] : 0;
}

static void cim_start_and_wait(void) {
    CIM_CTRL = 0x2;  CIM_CTRL = 0x1;
    while (!(CIM_STATUS & 0x2));
}

// ============================================================================
// Data (from gen_fw_data.py)
// ============================================================================
extern const uint32_t fc1_weight_chunks[];
extern const uint32_t fc1_bias[];
extern const uint32_t fc2_weight_chunks[];
extern const uint32_t fc2_bias[];
extern const uint8_t  test_image[];
extern const uint32_t fc1_n_chunks, fc2_n_chunks;
extern const uint32_t fc1_mult, fc1_shift, fc2_mult, fc2_shift;
extern const int32_t  hw_zp1, hw_zp2;
extern const uint32_t expected_label;

// ============================================================================
// Main
// ============================================================================
void main(void) {
    // Clear result BRAM magic (signals "not done yet")
    RES_WORD(0) = 0;

    uart_puts("\r\n=== CIM SoC RISC-V MNIST ===\r\n");

    // FC1: 784 → 16, ReLU
    uart_puts("FC1...\r\n");
    cim_soft_reset();
    cim_configure(784, 16, hw_zp1, fc1_mult, fc1_shift, 1);
    cim_load_weights_burst(fc1_weight_chunks, fc1_n_chunks);
    cim_load_bias(fc1_bias, 16);
    cim_load_input(test_image, 784);
    cim_start_and_wait();

    uint8_t fc1_output[16];
    for (int i = 0; i < 16; i++)
        fc1_output[i] = (uint8_t)CIM_LOGIT(i);

    // FC2: 16 → 10, no activation
    uart_puts("FC2...\r\n");
    cim_configure(16, 10, hw_zp2, fc2_mult, fc2_shift, 0);
    cim_load_weights_burst(fc2_weight_chunks, fc2_n_chunks);
    cim_load_bias(fc2_bias, 10);
    cim_load_input(fc1_output, 16);
    cim_start_and_wait();

    uint32_t pred = CIM_PRED_CLASS;

    // Write results to Result BRAM
    RES_WORD(1) = pred;
    RES_WORD(2) = expected_label;
    RES_WORD(3) = (pred == expected_label) ? 1 : 0;
    for (int i = 0; i < 10; i++) {
        int8_t v = (int8_t)(CIM_LOGIT(i) & 0xFF);
        RES_WORD(4 + i) = (uint32_t)(int32_t)v;  // sign-extend
    }
    // Write magic LAST (signals to PS that all data is valid)
    RES_WORD(0) = RES_MAGIC;

    // Also UART for debug
    uart_puts("Pred: "); uart_put_dec(pred);
    uart_puts(" Exp: "); uart_put_dec(expected_label);
    uart_puts(pred == expected_label ? " OK\r\n" : " WRONG\r\n");

    uart_puts("=== Done ===\r\n");
    while (1);
}
