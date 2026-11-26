/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Reset Entry, PICOBIN IMAGE_DEF & Early Bring-Up
 * ============================================================================
 * .text.boot sits at 0x10000000 (lowest Flash address; default RP2350 RISC-V
 * Boot ROM entry). .picobin_block sits immediately after, well inside the
 * Boot ROM's 4 KB scan window (rp2350-datasheet.pdf §5.9.5, p. 390).
 *
 * Unlike Phase 2, zero BIOS state lives in Main SRAM (0x20000000-0x2007FFFF):
 *   - Core 0 boot/IRQ stack lives in Scratchpad Bank 8 (__core0_stack_top)
 *   - BIOS driver state lives in the 4 KB USB DPRAM (0x50100000-0x50100FFF)
 * ============================================================================
 */

#include "hw/rp2350_regs.h"
#include "bios_flash.h"
#include "bios_ram.h"

.section .text.boot, "ax"
.global _start
.type _start, @function
_start:
    la      sp, __core0_stack_top       /* Scratchpad Bank 8 top (0x20081000) */
    csrw    mscratch, sp                /* Reserve Bank 8 as Core 0 IRQ stack */
    j       bios_boot_init
.size _start, . - _start

/* Minimum viable RP2350 RISC-V IMAGE_DEF (rp2350-datasheet.pdf Table 504) */
.section .picobin_block, "a"
.p2align 2
picobin_image_def:
    .word   PICOBIN_MARKER_START
    .word   PICOBIN_IMAGE_TYPE_RISCV
    .word   PICOBIN_ITEM_LAST_1WORD
    .word   PICOBIN_NEXT_BLOCK_SELF
    .word   PICOBIN_MARKER_END

.section .text, "ax"
.type bios_boot_init, @function
bios_boot_init:
    /* 1. Bring up 12 MHz XOSC -> 126.000 MHz PLL_SYS (clk_sys, clk_peri, clk_hstx) */
    call    clocks_init_126mhz

    /* 2. Release active peripheral set from reset (including USBCTRL for 4 KB DPRAM
     *    and BUSCTRL/DMA/HSTX for Core 1 Video Coprocessor) */
    li      t0, RESETS_BASE + ATOMIC_CLR
    li      t1, (RESET_BIT_BUSCTRL | RESET_BIT_DMA | RESET_BIT_HSTX | RESET_BIT_IO_BANK0 | RESET_BIT_PADS_BANK0 | RESET_BIT_PWM | RESET_BIT_TIMER0 | RESET_BIT_UART0 | RESET_BIT_USBCTRL)
    sw      t1, RESETS_RESET_OFF(t0)

    li      t0, RESETS_BASE
1:
    lw      t2, RESETS_DONE_OFF(t0)
    and     t2, t2, t1
    bne     t2, t1, 1b

    /* 3. Zero-initialize the 4 KB BIOS-private USB DPRAM (0x50100000-0x50100FFF) */
    li      t0, BIOS_DPRAM_BASE
    li      t1, BIOS_DPRAM_BASE + BIOS_DPRAM_SIZE
2:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 2b

    /* 4. Initialize resident drivers (TIMER0, LEDs, Piezo, UART0, Core 1 Video) */
    call    timer_init
    call    leds_init
    call    piezo_init
    call    uart0_init
    call    video_init

    /* 5. Install Vectored mtvec trap table (ecall BIOS ABI + future IRQs) */
    la      t0, __mtvec_base
    ori     t0, t0, BIOS_MTVEC_MODE_VECTORED
    csrw    mtvec, t0

    /* 6. Enter BIOS main */
    j       bios_main
.size bios_boot_init, . - bios_boot_init
