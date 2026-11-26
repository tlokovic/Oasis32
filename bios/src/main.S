/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Minimal Bring-Up Main (Splash + Serial Echo)
 * ============================================================================
 * Verifies XIP Flash boot, 126 MHz clocks, Scratchpad Bank 8 stack, USB DPRAM
 * un-gating, and UART0 115200 8N1 driver by printing a splash banner and
 * echoing received characters in dec/hex/bin format.
 * ============================================================================
 */

.section .text, "ax"

.global bios_main
.type bios_main, @function
bios_main:
    la      a0, str_splash
    call    uart0_puts

echo_loop:
    call    uart0_read                  /* a0 = received byte (0..255) */
    mv      s0, a0                      /* Save byte in s0 */

    la      a0, str_rx_prefix
    call    uart0_puts

    /* Print decimal (0..255) */
    mv      a0, s0
    call    print_u8_dec

    la      a0, str_hex_sep
    call    uart0_puts

    /* Print 2-digit uppercase hex */
    mv      a0, s0
    call    print_u8_hex

    la      a0, str_bin_sep
    call    uart0_puts

    /* Print 8-bit binary */
    mv      a0, s0
    call    print_u8_bin

    la      a0, str_crlf
    call    uart0_puts

    j       echo_loop
.size bios_main, . - bios_main

/* ----------------------------------------------------------------------------
 * print_u8_dec(a0 = 0..255): Prints unsigned byte in base 10
 * ---------------------------------------------------------------------------- */
.type print_u8_dec, @function
print_u8_dec:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)

    mv      s0, a0                      /* Remaining value */
    li      s1, 0                       /* Printed-digit flag */

    /* Hundreds digit */
    li      t0, 100
    divu    t1, s0, t0
    beqz    t1, 1f
    addi    a0, t1, '0'
    call    uart0_write
    li      t0, 100
    remu    s0, s0, t0
    li      s1, 1
1:
    /* Tens digit */
    li      t0, 10
    divu    t1, s0, t0
    bnez    t1, 2f
    beqz    s1, 3f                      /* Skip leading zero */
2:
    addi    a0, t1, '0'
    call    uart0_write
    li      t0, 10
    remu    s0, s0, t0
3:
    /* Ones digit (always printed) */
    addi    a0, s0, '0'
    call    uart0_write

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size print_u8_dec, . - print_u8_dec

/* ----------------------------------------------------------------------------
 * print_u8_hex(a0 = 0..255): Prints two uppercase hex digits
 * ---------------------------------------------------------------------------- */
.type print_u8_hex, @function
print_u8_hex:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0

    srli    a0, s0, 4
    andi    a0, a0, 0x0F
    call    print_hex_nibble

    andi    a0, s0, 0x0F
    call    print_hex_nibble

    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size print_u8_hex, . - print_u8_hex

.type print_hex_nibble, @function
print_hex_nibble:
    li      t0, 10
    bltu    a0, t0, 1f
    addi    a0, a0, ('A' - 10)
    j       uart0_write
1:
    addi    a0, a0, '0'
    j       uart0_write
.size print_hex_nibble, . - print_hex_nibble

/* ----------------------------------------------------------------------------
 * print_u8_bin(a0 = 0..255): Prints 8 binary digits MSB -> LSB
 * ---------------------------------------------------------------------------- */
.type print_u8_bin, @function
print_u8_bin:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)
    mv      s0, a0
    li      s1, 7
1:
    srl     a0, s0, s1
    andi    a0, a0, 1
    addi    a0, a0, '0'
    call    uart0_write
    addi    s1, s1, -1
    bgez    s1, 1b

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size print_u8_bin, . - print_u8_bin

/* ============================================================================
 * Read-Only Strings (.rodata in XIP Flash)
 * ============================================================================ */
.section .rodata, "a"
str_splash:
    .asciz "\r\n========================================\r\n  Oasis32 System ROM (BIOS) v0.1\r\n  Minimal Bring-Up (126 MHz, UART0)\r\n========================================\r\nReady. Type characters to echo:\r\n"
str_rx_prefix:
    .asciz "Serial character received: dec="
str_hex_sep:
    .asciz " hex=0x"
str_bin_sep:
    .asciz " bin=0b"
str_crlf:
    .asciz "\r\n"
