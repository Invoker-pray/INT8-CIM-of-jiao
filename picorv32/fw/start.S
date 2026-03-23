    # ====================================================================
    # start.S — Minimal startup for PicoRV32 (RV32IM)
    # ====================================================================
    # Reset vector is at 0x00000000 (PROGADDR_RESET).
    # Sets up stack pointer and calls main().
    # ====================================================================

    .section .text.init, "ax"
    .global _start
    .global _pvec

_start:
    # Set stack pointer to top of BRAM (32KB = 0x8000)
    li      sp, 0x00007FFC

    # Clear BSS section
    la      a0, _bss_start
    la      a1, _bss_end
clear_bss:
    bge     a0, a1, bss_done
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       clear_bss
bss_done:

    # Jump to C main
    jal     ra, main

    # If main returns, loop forever
halt:
    j       halt

    # IRQ vector (at offset 0x10 if IRQ enabled)
    .balign 16
_pvec:
    j       _pvec
