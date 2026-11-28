/*
 * ============================================================================
 * Oasis32 Stage-2 Disk Example — Hello World (Display)
 * ============================================================================
 * Minimal bootable .oa32 payload that clears the bitmap framebuffer and text
 * overlay, prints "Hello world!\n" to the 80x60 DVI display via the resident
 * BIOS `ecall` ABI, and loops forever.
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"

.section .text.entry, "ax"
.global _start

_start:
    /* Clear 640x480 1 bpp bitmap framebuffer */
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + VIDEO_FRAMEBUF_SIZE
.Lclear_fb:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, .Lclear_fb

    /* Clear 80x60 text overlay and reset cursor to (0, 0) */
    li      a7, BIOS_TEXT_CLEAR
    ecall

    /* Print "Hello world!\n" to the display */
    la      a0, hello_msg
    li      a7, BIOS_TEXT_PUTS
    ecall

.Ldone:
    j       .Ldone

.section .rodata
hello_msg:
    .asciz  "Hello world!\n"
