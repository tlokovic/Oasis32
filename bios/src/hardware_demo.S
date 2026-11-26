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
 *   - DVI Framebuffer (VIDEO_FRAMEBUF_BASE): 1 px border + 20x15 grid +
 *     bouncing 32x32 XOR box (~60 px/s) scanned out by Core 1
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"

#define DEMO_LED_INTERVAL_US        1000000
#define DEMO_PIEZO_PERIOD_US        3000000
#define DEMO_PIEZO_DURATION_US      100000
#define DEMO_PIEZO_FREQ_HZ          1000
#define DEMO_VIDEO_STEP_US          16667   /* ~60 px/s (1 px per 60 Hz frame) */

#define DEMO_BOX_SIZE_PX            32
#define DEMO_BOX_MIN_X              1
#define DEMO_BOX_MAX_X              (VIDEO_WIDTH - 1 - DEMO_BOX_SIZE_PX)
#define DEMO_BOX_MIN_Y              1
#define DEMO_BOX_MAX_Y              (VIDEO_HEIGHT - 1 - DEMO_BOX_SIZE_PX)

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * hardware_demo(): Non-blocking cooperative demo loop called from bios_main
 *   s0  = scratch / received byte / current now_us snapshot
 *   s1  = next_led_us    (32-bit low microsecond deadline)
 *   s2  = active LED idx (0=Red, 1=Green, 2=Blue)
 *   s3  = next_piezo_us  (next 3 s beep start deadline)
 *   s4  = piezo_stop_us  (100 ms stop deadline while active)
 *   s5  = piezo_active   (0=silent, 1=beeping)
 *   s6  = next_video_us  (16,667 us bouncing box step deadline)
 *   s7  = box_x          (1..607)
 *   s8  = box_y          (1..447)
 *   s9  = box_dx         (+1 or -1)
 *   s10 = box_dy         (+1 or -1)
 * ---------------------------------------------------------------------------- */
.global hardware_demo
.type hardware_demo, @function
hardware_demo:
    addi    sp, sp, -48
    sw      ra, 44(sp)
    sw      s0, 40(sp)
    sw      s1, 36(sp)
    sw      s2, 32(sp)
    sw      s3, 28(sp)
    sw      s4, 24(sp)
    sw      s5, 20(sp)
    sw      s6, 16(sp)
    sw      s7, 12(sp)
    sw      s8, 8(sp)
    sw      s9, 4(sp)
    sw      s10, 0(sp)

    la      a0, str_splash
    call    demo_puts

    /* Draw static 1 px outer border + 20x15 (32x32) grid and initial XOR box */
    call    demo_fb_draw_grid_and_border
    li      s7, 16                      /* box_x = 16 */
    li      s8, 16                      /* box_y = 16 */
    li      s9, 1                       /* box_dx = +1 */
    li      s10, 1                      /* box_dy = +1 */
    mv      a0, s7
    mv      a1, s8
    call    demo_fb_xor_box

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

    /* Schedule first bouncing-box step in 16.67 ms (~60 px/s) */
    li      t0, DEMO_VIDEO_STEP_US
    add     s6, s0, t0                  /* s6 = next_video_us */

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
    bltz    t0, check_video
    li      a0, AUDIO_FREQ_OFF
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 0
    j       check_video

check_piezo_start:
    sub     t0, s0, s3                  /* Silent: wait for next 3 s period */
    bltz    t0, check_video
    li      a0, DEMO_PIEZO_FREQ_HZ
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 1
    li      t0, DEMO_PIEZO_DURATION_US
    add     s4, s0, t0
    li      t0, DEMO_PIEZO_PERIOD_US
    add     s3, s3, t0

check_video:
    /* 4. Non-blocking ~60 px/s bouncing 32x32 XOR box on VIDEO_FRAMEBUF_BASE */
    sub     t0, s0, s6
    bltz    t0, demo_loop

    /* Erase old box */
    mv      a0, s7
    mv      a1, s8
    call    demo_fb_xor_box

    /* Bounce X in [DEMO_BOX_MIN_X, DEMO_BOX_MAX_X] */
    blez    s9, 1f
    li      t0, DEMO_BOX_MAX_X
    blt     s7, t0, 2f
    neg     s9, s9
    j       2f
1:
    li      t0, DEMO_BOX_MIN_X
    bgt     s7, t0, 2f
    neg     s9, s9
2:
    add     s7, s7, s9

    /* Bounce Y in [DEMO_BOX_MIN_Y, DEMO_BOX_MAX_Y] */
    blez    s10, 3f
    li      t0, DEMO_BOX_MAX_Y
    blt     s8, t0, 4f
    neg     s10, s10
    j       4f
3:
    li      t0, DEMO_BOX_MIN_Y
    bgt     s8, t0, 4f
    neg     s10, s10
4:
    add     s8, s8, s10

    /* Draw new box and advance deadline */
    mv      a0, s7
    mv      a1, s8
    call    demo_fb_xor_box

    li      t0, DEMO_VIDEO_STEP_US
    add     s6, s6, t0
    j       demo_loop
.size hardware_demo, . - hardware_demo

/* ----------------------------------------------------------------------------
 * demo_fb_draw_grid_and_border:
 *   Draws 1-pixel outer border (0,0)-(639,479) and word-aligned 20x15 grid
 *   of 32x32-pixel cells into VIDEO_FRAMEBUF_BASE (38,400 bytes).
 * ---------------------------------------------------------------------------- */
.type demo_fb_draw_grid_and_border, @function
demo_fb_draw_grid_and_border:
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, 0                       /* y = 0..479 */
    li      t2, VIDEO_HEIGHT
    li      t3, (VIDEO_HEIGHT - 1)      /* y = 479 */
    li      t4, 0x80000000              /* Rightmost pixel bit (x = 639) */
1:
    andi    t5, t1, 31
    beqz    t5, 2f
    beq     t1, t3, 2f
    li      t5, 0x00000001              /* Vertical grid line on bit 0 */
    j       3f
2:
    li      t5, -1                      /* 0xFFFFFFFF horizontal line */
3:
    li      t6, 0                       /* w = 0..19 */
    li      a0, (VIDEO_STRIDE_WORDS - 1)
    li      a2, VIDEO_STRIDE_WORDS
4:
    mv      a1, t5
    bne     t6, a0, 5f
    or      a1, a1, t4                  /* Right outer border at w == 19 */
5:
    sw      a1, 0(t0)
    addi    t0, t0, 4
    addi    t6, t6, 1
    bltu    t6, a2, 4b

    addi    t1, t1, 1
    bltu    t1, t2, 1b
    ret
.size demo_fb_draw_grid_and_border, . - demo_fb_draw_grid_and_border

/* ----------------------------------------------------------------------------
 * demo_fb_xor_box(a0 = x, a1 = y):
 *   XORs a 32x32-pixel solid square at (x, y) in VIDEO_FRAMEBUF_BASE.
 *   Each row spans at most two adjacent 32-bit words.
 * ---------------------------------------------------------------------------- */
.type demo_fb_xor_box, @function
demo_fb_xor_box:
    srli    t0, a0, 5                   /* word_idx = x >> 5 */
    andi    t1, a0, 31                  /* bit_shift = x & 31 */
    li      t2, -1
    sll     t3, t2, t1                  /* mask_lo = 0xFFFFFFFF << bit_shift */
    li      t4, 0                       /* mask_hi = 0 if bit_shift == 0 */
    beqz    t1, 1f
    li      t5, 32
    sub     t5, t5, t1
    srl     t4, t2, t5                  /* mask_hi = 0xFFFFFFFF >> (32 - shift) */
1:
    /* row_ptr = VIDEO_FRAMEBUF_BASE + y * 80 + word_idx * 4 */
    li      t5, VIDEO_STRIDE_BYTES
    mul     t5, a1, t5
    slli    t0, t0, 2
    add     t5, t5, t0
    li      t0, VIDEO_FRAMEBUF_BASE
    add     t0, t0, t5

    li      t1, DEMO_BOX_SIZE_PX        /* 32 rows */
2:
    lw      t5, 0(t0)
    xor     t5, t5, t3
    sw      t5, 0(t0)
    beqz    t4, 3f
    lw      t5, 4(t0)
    xor     t5, t5, t4
    sw      t5, 4(t0)
3:
    addi    t0, t0, VIDEO_STRIDE_BYTES
    addi    t1, t1, -1
    bnez    t1, 2b
    ret
.size demo_fb_xor_box, . - demo_fb_xor_box

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
    .asciz "\r\n========================================\r\n  Oasis32 System ROM (BIOS) v0.1\r\n  Hardware Demo (UART0 + TIMER0 + LEDs + Piezo + DVI)\r\n========================================\r\nReady. LEDs 1/s, Piezo 1kHz/3s, DVI 640x480; type to echo:\r\n"
str_rx_prefix:
    .asciz "Serial character received: dec="
str_hex_sep:
    .asciz " hex=0x"
str_bin_sep:
    .asciz " bin=0b"
str_crlf:
    .asciz "\r\n"
