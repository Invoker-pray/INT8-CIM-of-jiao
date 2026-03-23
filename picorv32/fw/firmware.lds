/* ====================================================================
 * firmware.lds — Linker script for PicoRV32 CIM SoC firmware
 * ====================================================================
 * Memory: 32KB BRAM at 0x0000_0000
 * Stack grows downward from 0x0000_7FFC
 * ====================================================================
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    BRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS {
    /* Code — starts at reset vector */
    .text : {
        *(.text.init)    /* startup code first */
        *(.text*)
    } > BRAM

    /* Read-only data (const arrays: weights, bias, images) */
    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > BRAM

    /* Initialized data */
    .data : {
        *(.data*)
        *(.sdata*)
    } > BRAM

    /* BSS (zero-initialized) */
    .bss : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        _bss_end = .;
    } > BRAM

    /* Stack at top of BRAM */
    _stack_top = 0x00007FFC;
}
