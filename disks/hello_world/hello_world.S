/*
 * ============================================================================
 * Oasis32 Stage-2 Disk Example — Hello World (Serial)
 * ============================================================================
 * Minimal bootable .oa32 payload that prints "Hello world!\r\n" to the debug
 * serial port via the resident BIOS `ecall` ABI and then loops forever.
 * ============================================================================
 */

#include "abi/bios_abi.h"

.section .text.entry, "ax"
.global _start

_start:
    la      s0, hello_msg

.Lprint_loop:
    lbu     a0, 0(s0)
    beqz    a0, .Ldone
    li      a7, BIOS_SERIAL_WRITE
    ecall
    addi    s0, s0, 1
    j       .Lprint_loop

.Ldone:
    j       .Ldone

.section .rodata
hello_msg:
    .asciz  "Hello world!\r\n"
