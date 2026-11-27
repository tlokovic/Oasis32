/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Main Entry Point & Interactive Boot Menu
 * ============================================================================
 * Displays the startup boot menu on the 80x60 DVI text display using the
 * resident BIOS_BLK_TEXT and BIOS_BLK_INPUT services, dispatching:
 *   - ENTER : Boot from SD Card                  (stubbed for now)
 *   - 1     : Boot disk image from serial        (stubbed for now)
 *   - 2     : Write disk image from serial to SD (stubbed for now)
 *   - 3     : Run built-in hardware demo
 *
 * Note: Because BIOS_TEXT_PUTS enforces User SRAM bounds on caller pointers,
 * Flash-resident BIOS strings are printed via a local BIOS_TEXT_PUTC loop.
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "abi/keycodes.h"

#define BOOT_SPLASH_WAIT_US         3000000 /* 3 s splash hold after tune */
#define BOOT_SPLASH_COL             36      /* (80 - 7) / 2 */
#define BOOT_SPLASH_ROW             29      /* ~60 / 2 */

.section .text, "ax"

.global bios_main
.type bios_main, @function
bios_main:
    /* Startup splash: 1-px outer border + centered "Oasis32" during tune & 3 s hold */
    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    li      a7, BIOS_TEXT_CLEAR
    ecall

    call    boot_draw_border

    li      a0, BOOT_SPLASH_COL
    li      a1, BOOT_SPLASH_ROW
    li      a7, BIOS_TEXT_SET_CURSOR_POS
    ecall

    la      a0, str_splash_title
    call    boot_text_puts

    call    play_startup_tune

    /* Hold splash for 3 seconds so displays/capture adapters lock cleanly */
    li      a7, BIOS_TIME_US
    ecall
    mv      s0, a0                      /* s0 = start_us */
    li      s1, BOOT_SPLASH_WAIT_US
1:
    li      a7, BIOS_TIME_US
    ecall
    sub     t0, a0, s0
    bltu    t0, s1, 1b

    /* Clear border from framebuffer before entering the clean boot menu */
    call    boot_clear_framebuf

boot_menu_draw:
    /* Clear text overlay, hide cursor while drawing, flush stale key events */
    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    li      a7, BIOS_TEXT_CLEAR
    ecall

    li      a7, BIOS_KEYBOARD_FLUSH
    ecall

    /* Print banner + live BIOS_SYS_VERSION (vMAJ.MIN.PAT) */
    la      a0, str_menu_top
    call    boot_text_puts

    li      a7, BIOS_SYS_VERSION
    ecall
    mv      s0, a0                      /* s0 = (maj << 16) | (min << 8) | pat */

    srli    a0, s0, 16
    andi    a0, a0, 0xFF
    call    boot_text_print_u8_dec

    li      a0, '.'
    li      a7, BIOS_TEXT_PUTC
    ecall

    srli    a0, s0, 8
    andi    a0, a0, 0xFF
    call    boot_text_print_u8_dec

    li      a0, '.'
    li      a7, BIOS_TEXT_PUTC
    ecall

    andi    a0, s0, 0xFF
    call    boot_text_print_u8_dec

    /* Print menu options and prompt */
    la      a0, str_menu_body
    call    boot_text_puts

    /* Show blinking cursor (30 frames = 0.5 s half-period) at prompt */
    li      a0, 1
    li      a1, 30
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

boot_menu_wait_key:
    li      a7, BIOS_KEYBOARD_READ
    ecall

    /* Ignore key-up and typematic repeat events */
    li      t0, KEY_EVENT_DOWN_BIT
    and     t0, a0, t0
    beqz    t0, boot_menu_wait_key

    li      t0, KEY_EVENT_REPEAT_BIT
    and     t0, a0, t0
    bnez    t0, boot_menu_wait_key

    andi    t1, a0, KEY_EVENT_CODE_MASK

    /* Option ENTER: Boot from SD Card (not yet implemented) */
    li      t0, KEY_ENTER
    beq     t1, t0, boot_menu_wait_key
    li      t0, KEY_KP_ENTER
    beq     t1, t0, boot_menu_wait_key

    /* Option 1: Boot from disk image over serial (not yet implemented) */
    li      t0, KEY_1
    beq     t1, t0, boot_menu_wait_key
    li      t0, KEY_KP_1
    beq     t1, t0, boot_menu_wait_key

    /* Option 2: Write disk image from serial to SD (not yet implemented) */
    li      t0, KEY_2
    beq     t1, t0, boot_menu_wait_key
    li      t0, KEY_KP_2
    beq     t1, t0, boot_menu_wait_key

    /* Option 3: Run built-in hardware demo */
    li      t0, KEY_3
    beq     t1, t0, boot_menu_run_demo
    li      t0, KEY_KP_3
    beq     t1, t0, boot_menu_run_demo

    j       boot_menu_wait_key

boot_menu_run_demo:
    li      a7, BIOS_TEXT_CLEAR
    ecall
    call    hardware_demo
    j       boot_menu_draw
.size bios_main, . - bios_main

/* ----------------------------------------------------------------------------
 * boot_text_puts(a0 = NUL-terminated string pointer in Flash or RAM)
 *   Prints a NUL-terminated string to the DVI text console via BIOS_TEXT_PUTC.
 * ---------------------------------------------------------------------------- */
.type boot_text_puts, @function
boot_text_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)

    mv      s0, a0
1:
    lbu     a0, 0(s0)
    beqz    a0, 2f
    li      a7, BIOS_TEXT_PUTC
    ecall
    addi    s0, s0, 1
    j       1b
2:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_text_puts, . - boot_text_puts

/* ----------------------------------------------------------------------------
 * boot_text_print_u8_dec(a0 = 0..255)
 *   Prints an unsigned 8-bit integer in decimal to the DVI text console.
 * ---------------------------------------------------------------------------- */
.type boot_text_print_u8_dec, @function
boot_text_print_u8_dec:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)

    mv      s0, a0                      /* s0 = remaining value */
    li      s1, 0                       /* s1 = printed_any flag */

    li      t0, 100
    bltu    s0, t0, 1f
    divu    a0, s0, t0
    remu    s0, s0, t0
    addi    a0, a0, '0'
    li      a7, BIOS_TEXT_PUTC
    ecall
    li      s1, 1
1:
    li      t0, 10
    bnez    s1, 2f
    bltu    s0, t0, 3f
2:
    divu    a0, s0, t0
    remu    s0, s0, t0
    addi    a0, a0, '0'
    li      a7, BIOS_TEXT_PUTC
    ecall
3:
    addi    a0, s0, '0'
    li      a7, BIOS_TEXT_PUTC
    ecall

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_text_print_u8_dec, . - boot_text_print_u8_dec

/* ----------------------------------------------------------------------------
 * boot_draw_border():
 *   Draws a 1-pixel white outer border (0,0)-(639,479) in VIDEO_FRAMEBUF_BASE.
 * ---------------------------------------------------------------------------- */
.type boot_draw_border, @function
boot_draw_border:
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + ((VIDEO_HEIGHT - 1) * VIDEO_STRIDE_BYTES)
    li      t2, VIDEO_STRIDE_WORDS
    li      t3, -1
1:
    sw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t2, t2, -1
    bnez    t2, 1b

    li      t0, VIDEO_FRAMEBUF_BASE + VIDEO_STRIDE_BYTES
    li      t1, VIDEO_FRAMEBUF_BASE + ((VIDEO_HEIGHT - 1) * VIDEO_STRIDE_BYTES)
    li      t2, 0x01
    li      t3, 0x80
2:
    sb      t2, 0(t0)
    sb      t3, (VIDEO_STRIDE_BYTES - 1)(t0)
    addi    t0, t0, VIDEO_STRIDE_BYTES
    bltu    t0, t1, 2b
    ret
.size boot_draw_border, . - boot_draw_border

/* ----------------------------------------------------------------------------
 * boot_clear_framebuf():
 *   Zero-fills VIDEO_FRAMEBUF_BASE (38,400 bytes).
 * ---------------------------------------------------------------------------- */
.type boot_clear_framebuf, @function
boot_clear_framebuf:
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + VIDEO_FRAMEBUF_SIZE
1:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b
    ret
.size boot_clear_framebuf, . - boot_clear_framebuf

.section .rodata

str_splash_title:
    .asciz  "Oasis32"

str_menu_top:
    .asciz  "\n  ============================================================================\n    Oasis32 System ROM v"

str_menu_body:
    .asciz  "\n  ============================================================================\n\n    [ENTER]  Boot from SD Card\n    [1]      Boot from disk image read from serial\n    [2]      Write disk image read from serial to SD Card\n    [3]      Run built-in hardware demo\n\n  Select an option: "
