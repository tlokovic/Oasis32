/*
 * ============================================================================
 * Oasis32 Hardware Demo — ABI Validation Harness (Temporary BIOS Payload)
 * ============================================================================
 * Reconstructs the Phase 2 test harness behaviors strictly through the public
 * Oasis32 BIOS ecall ABI (`include/abi/bios_abi.h`, `include/abi/devices.h`),
 * with ZERO direct hardware register access or `bios/internal/` includes.
 *
 * Currently exercises:
 *   - Serial Console (BIOS_SERIAL_TRY_READ, BIOS_SERIAL_WRITE): splash + echo
 *   - Monotonic Timer (BIOS_TIME_US): non-blocking cooperative scheduling
 *   - Status LEDs (BIOS_LED_WRITE): Red -> Green -> Blue cycle (1/s)
 *   - Piezo Audio (BIOS_AUDIO_TONE): 100 ms @ 1 kHz beep every 3 s
 * ============================================================================
 */

#include "abi/bios_abi.h"
#include "abi/devices.h"

#define DEMO_LED_INTERVAL_US        1000000
#define DEMO_PIEZO_PERIOD_US        3000000
#define DEMO_PIEZO_DURATION_US      100000
#define DEMO_PIEZO_FREQ_HZ          1000

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * hardware_demo(): Non-blocking cooperative demo loop called from bios_main
 *   s0 = scratch / received byte / current now_us snapshot
 *   s1 = next_led_us    (32-bit low microsecond deadline)
 *   s2 = active LED idx (0=Red, 1=Green, 2=Blue)
 *   s3 = next_piezo_us  (next 3 s beep start deadline)
 *   s4 = piezo_stop_us  (100 ms stop deadline while active)
 *   s5 = piezo_active   (0=silent, 1=beeping)
 * ---------------------------------------------------------------------------- */
.global hardware_demo
.type hardware_demo, @function
hardware_demo:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)
    sw      s4, 8(sp)
    sw      s5, 4(sp)

    la      a0, str_splash
    call    demo_puts

    /* Snapshot initial timestamp */
    li      a7, BIOS_TIME_US
    ecall
    mv      s0, a0                      /* s0 = now_us */

    /* Start on LED_RED (0) and schedule first step in 1 second */
    li      s2, LED_RED
    mv      a0, s2
    li      a1, 1
    li      a7, BIOS_LED_WRITE
    ecall
    li      t0, DEMO_LED_INTERVAL_US
    add     s1, s0, t0                  /* s1 = next_led_us */

    /* Trigger initial 100 ms @ 1 kHz beep on boot, then repeat every 3 s */
    li      a0, DEMO_PIEZO_FREQ_HZ
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 1
    li      t0, DEMO_PIEZO_DURATION_US
    add     s4, s0, t0                  /* s4 = piezo_stop_us */
    li      t0, DEMO_PIEZO_PERIOD_US
    add     s3, s0, t0                  /* s3 = next_piezo_us */

demo_loop:
    /* 1. Non-blocking serial echo (BIOS_SERIAL_TRY_READ) */
    li      a7, BIOS_SERIAL_TRY_READ
    ecall
    bltz    a0, check_timers            /* ERR_EMPTY (-3) -> no byte waiting */

    mv      s0, a0                      /* Save received byte */
    la      a0, str_rx_prefix
    call    demo_puts
    mv      a0, s0
    call    demo_print_u8_dec
    la      a0, str_hex_sep
    call    demo_puts
    mv      a0, s0
    call    demo_print_u8_hex
    la      a0, str_bin_sep
    call    demo_puts
    mv      a0, s0
    call    demo_print_u8_bin
    la      a0, str_crlf
    call    demo_puts

check_timers:
    /* Snapshot current monotonic timestamp once per iteration */
    li      a7, BIOS_TIME_US
    ecall
    mv      s0, a0                      /* s0 = now_us */

    /* 2. Non-blocking 1-second LED cycle (BIOS_LED_WRITE) */
    sub     t0, s0, s1                  /* Wrap-safe signed delta */
    bltz    t0, check_piezo

    mv      a0, s2
    li      a1, 0
    li      a7, BIOS_LED_WRITE
    ecall

    addi    s2, s2, 1
    li      t0, LED_COUNT
    bltu    s2, t0, 1f
    li      s2, LED_RED
1:
    mv      a0, s2
    li      a1, 1
    li      a7, BIOS_LED_WRITE
    ecall

    li      t0, DEMO_LED_INTERVAL_US
    add     s1, s1, t0

check_piezo:
    /* 3. Non-blocking 100 ms @ 1 kHz beep every 3 s (BIOS_AUDIO_TONE) */
    beqz    s5, check_piezo_start

    sub     t0, s0, s4                  /* Active: wait for stop deadline */
    bltz    t0, demo_loop
    li      a0, AUDIO_FREQ_OFF
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 0
    j       demo_loop

check_piezo_start:
    sub     t0, s0, s3                  /* Silent: wait for next 3 s period */
    bltz    t0, demo_loop
    li      a0, DEMO_PIEZO_FREQ_HZ
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 1
    li      t0, DEMO_PIEZO_DURATION_US
    add     s4, s0, t0
    li      t0, DEMO_PIEZO_PERIOD_US
    add     s3, s3, t0
    j       demo_loop
.size hardware_demo, . - hardware_demo

/* ----------------------------------------------------------------------------
 * demo_putc(a0 = byte): Transmit one byte via BIOS_SERIAL_WRITE ecall
 * ---------------------------------------------------------------------------- */
.type demo_putc, @function
demo_putc:
    li      a7, BIOS_SERIAL_WRITE
    ecall
    ret
.size demo_putc, . - demo_putc

/* ----------------------------------------------------------------------------
 * demo_puts(a0 = NUL-terminated string): Print string via BIOS_SERIAL_WRITE
 * ---------------------------------------------------------------------------- */
.type demo_puts, @function
demo_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0
1:
    lbu     a0, 0(s0)
    beqz    a0, 2f
    li      a7, BIOS_SERIAL_WRITE
    ecall
    addi    s0, s0, 1
    j       1b
2:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_puts, . - demo_puts

/* ----------------------------------------------------------------------------
 * demo_print_u8_dec(a0 = 0..255): Prints unsigned byte in base 10
 * ---------------------------------------------------------------------------- */
.type demo_print_u8_dec, @function
demo_print_u8_dec:
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
    call    demo_putc
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
    call    demo_putc
    li      t0, 10
    remu    s0, s0, t0
3:
    /* Ones digit (always printed) */
    addi    a0, s0, '0'
    call    demo_putc

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_print_u8_dec, . - demo_print_u8_dec

/* ----------------------------------------------------------------------------
 * demo_print_u8_hex(a0 = 0..255): Prints two uppercase hex digits
 * ---------------------------------------------------------------------------- */
.type demo_print_u8_hex, @function
demo_print_u8_hex:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0

    srli    a0, s0, 4
    andi    a0, a0, 0x0F
    call    demo_print_hex_nibble

    andi    a0, s0, 0x0F
    call    demo_print_hex_nibble

    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_print_u8_hex, . - demo_print_u8_hex

.type demo_print_hex_nibble, @function
demo_print_hex_nibble:
    li      t0, 10
    bltu    a0, t0, 1f
    addi    a0, a0, ('A' - 10)
    j       demo_putc
1:
    addi    a0, a0, '0'
    j       demo_putc
.size demo_print_hex_nibble, . - demo_print_hex_nibble

/* ----------------------------------------------------------------------------
 * demo_print_u8_bin(a0 = 0..255): Prints 8 binary digits MSB -> LSB
 * ---------------------------------------------------------------------------- */
.type demo_print_u8_bin, @function
demo_print_u8_bin:
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
    call    demo_putc
    addi    s1, s1, -1
    bgez    s1, 1b

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_print_u8_bin, . - demo_print_u8_bin

/* ============================================================================
 * Read-Only Strings (.rodata in XIP Flash)
 * ============================================================================ */
.section .rodata, "a"
str_splash:
    .asciz "\r\n========================================\r\n  Oasis32 System ROM (BIOS) v0.1\r\n  Hardware Demo (UART0 + TIMER0 + LEDs + Piezo)\r\n========================================\r\nReady. LEDs 1/s, Piezo 1kHz/3s; type to echo:\r\n"
str_rx_prefix:
    .asciz "Serial character received: dec="
str_hex_sep:
    .asciz " hex=0x"
str_bin_sep:
    .asciz " bin=0b"
str_crlf:
    .asciz "\r\n"
