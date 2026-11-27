/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Main Entry Point, Auto-Boot & Interactive Boot Menu
 * ============================================================================
 * Startup sequence (docs/BootBehavior.md §3.5):
 *   1. Display 640x480 splash bitmap with 5 px white border, play startup
 *      tune, hold 3 seconds, clear framebuffer.
 *   2. Attempt automatic SD boot (boot_auto_sd): if a card with a valid
 *      "OA32" header is seated, boot immediately; otherwise fall through to
 *      the interactive 80x60 DVI boot menu.
 *   3. In the boot menu, poll both keyboard (BIOS_KEYBOARD_TRY_READ) and SD
 *      card status (BIOS_SD_STATUS) continuously, dynamically updating
 *      disabled states for [ENTER] and [2] without re-reading LBA 0 while an
 *      invalid card stays seated:
 *        - ENTER : Boot from SD Card                  (valid OA32 disk only)
 *        - 1     : Boot disk image from serial        (always enabled)
 *        - 2     : Write disk image from serial to SD (any seated disk)
 *        - 3     : Run built-in hardware demo         (always enabled)
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

#define DISK_STATE_NONE             0
#define DISK_STATE_INVALID          1
#define DISK_STATE_VALID            2

.section .text, "ax"

.global bios_main
.type bios_main, @function
bios_main:
    /* 1. Startup splash: display embedded 640x480 bitmap, play tune, hold 3 s */
    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    li      a7, BIOS_TEXT_CLEAR
    ecall

    call    boot_draw_splash

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

    /* Clear splash bitmap from framebuffer before auto-boot / boot menu */
    call    boot_clear_framebuf

    /* 2. Post-splash automatic SD boot attempt.
     *    If a valid OA32 disk is inserted, boot_auto_sd boots and never returns.
     *    Otherwise it returns the initial menu disk state in a0 (NONE/INVALID). */
    call    boot_auto_sd
    mv      s2, a0                      /* s2 = current DISK_STATE_* */

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

    /* Divider + Option [ENTER] */
    la      a0, str_menu_div_enter
    call    boot_text_puts

    li      t0, DISK_STATE_NONE
    beq     s2, t0, 1f
    li      t0, DISK_STATE_INVALID
    beq     s2, t0, 2f
    j       3f
1:
    la      a0, str_dis_no_disk
    call    boot_text_puts
    j       3f
2:
    la      a0, str_dis_bad_hdr
    call    boot_text_puts
3:
    /* Option [1] and Option [2] */
    la      a0, str_menu_opt1_opt2
    call    boot_text_puts

    li      t0, DISK_STATE_NONE
    bne     s2, t0, 4f
    la      a0, str_dis_no_disk
    call    boot_text_puts
4:
    /* Option [3] and prompt */
    la      a0, str_menu_opt3_prompt
    call    boot_text_puts

    /* Show blinking cursor (30 frames = 0.5 s half-period) at prompt */
    li      a0, 1
    li      a1, 30
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

boot_menu_poll:
    /* 1. Poll SD card presence (GP6) for live menu state updates */
    li      a7, BIOS_SD_STATUS
    ecall
    mv      t0, a0                      /* t0 = SD_STATUS_* bitmask */
    andi    t1, t0, SD_STATUS_PRESENT

    li      t2, DISK_STATE_NONE
    beq     s2, t2, poll_sd_was_none

    /* Card was previously inserted (INVALID or VALID) */
    beqz    t1, poll_sd_removed         /* Card removed -> NONE + redraw */

    /* If previously VALID, check whether a fast card swap cleared READY */
    li      t2, DISK_STATE_VALID
    bne     s2, t2, poll_keyboard       /* INVALID & still seated: do NOT re-read LBA 0 */
    andi    t2, t0, SD_STATUS_READY
    bnez    t2, poll_keyboard
    j       poll_sd_reprobe

poll_sd_was_none:
    beqz    t1, poll_keyboard           /* Still no card */

poll_sd_reprobe:
    call    boot_probe_sd
    mv      s2, a0
    j       boot_menu_draw

poll_sd_removed:
    li      s2, DISK_STATE_NONE
    j       boot_menu_draw

poll_keyboard:
    /* 2. Non-blocking keyboard poll */
    li      a7, BIOS_KEYBOARD_TRY_READ
    ecall
    bltz    a0, boot_menu_poll

    /* Ignore key-up and typematic repeat events */
    li      t0, KEY_EVENT_DOWN_BIT
    and     t0, a0, t0
    beqz    t0, boot_menu_poll

    li      t0, KEY_EVENT_REPEAT_BIT
    and     t0, a0, t0
    bnez    t0, boot_menu_poll

    andi    t1, a0, KEY_EVENT_CODE_MASK

    /* Option ENTER: Boot from SD Card (enabled only when DISK_STATE_VALID) */
    li      t0, KEY_ENTER
    beq     t1, t0, boot_menu_try_sd
    li      t0, KEY_KP_ENTER
    beq     t1, t0, boot_menu_try_sd

    /* Option 1: Boot from disk image over serial (always enabled) */
    li      t0, KEY_1
    beq     t1, t0, boot_menu_serial_boot
    li      t0, KEY_KP_1
    beq     t1, t0, boot_menu_serial_boot

    /* Option 2: Write disk image from serial to SD (enabled when disk seated) */
    li      t0, KEY_2
    beq     t1, t0, boot_menu_try_write_sd
    li      t0, KEY_KP_2
    beq     t1, t0, boot_menu_try_write_sd

    /* Option 3: Run built-in hardware demo (always enabled) */
    li      t0, KEY_3
    beq     t1, t0, boot_menu_run_demo
    li      t0, KEY_KP_3
    beq     t1, t0, boot_menu_run_demo

    j       boot_menu_poll

boot_menu_try_sd:
    li      t0, DISK_STATE_VALID
    bne     s2, t0, boot_menu_poll
    call    boot_from_sd                /* Does not return */
    j       boot_menu_draw

boot_menu_serial_boot:
    call    boot_from_serial            /* Returns only on ESC/Ctrl-C cancel */
    j       boot_menu_draw

boot_menu_try_write_sd:
    li      t0, DISK_STATE_NONE
    beq     s2, t0, boot_menu_poll
    call    boot_write_sd               /* Returns on cancel or write complete */
    call    boot_probe_sd               /* Re-evaluate card header after write */
    mv      s2, a0
    j       boot_menu_draw

boot_menu_run_demo:
    li      a7, BIOS_TEXT_CLEAR
    ecall
    call    hardware_demo
    call    boot_probe_sd
    mv      s2, a0
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
 * boot_draw_splash():
 *   Copies the 38,400-byte (9,600-word) Flash-resident splash bitmap
 *   (`bios_splash_fb` from `bios/src/splash.S`) into VIDEO_FRAMEBUF_BASE,
 *   then overlays a 5-pixel white outer border (0,0)-(639,479) to aid
 *   DVI monitor/capture-card active-frame lock-on after reset.
 * ---------------------------------------------------------------------------- */
#define BOOT_SPLASH_BORDER_PX       5
#define BOOT_SPLASH_BORDER_LEFT     0x1F    /* LSB-left x = 0..4   (bits 0..4) */
#define BOOT_SPLASH_BORDER_RIGHT    0xF8    /* LSB-left x = 635..639 (bits 3..7) */

.type boot_draw_splash, @function
boot_draw_splash:
    /* 1. Copy 38,400-byte splash bitmap from XIP Flash to VIDEO_FRAMEBUF_BASE */
    la      t0, bios_splash_fb
    li      t1, VIDEO_FRAMEBUF_BASE
    li      t2, VIDEO_FRAMEBUF_BASE + VIDEO_FRAMEBUF_SIZE
1:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    bltu    t1, t2, 1b

    /* 2. Top 5 rows (y = 0..4) and bottom 5 rows (y = 475..479): all white */
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + ((VIDEO_HEIGHT - BOOT_SPLASH_BORDER_PX) * VIDEO_STRIDE_BYTES)
    li      t2, BOOT_SPLASH_BORDER_PX * VIDEO_STRIDE_WORDS
    li      t3, -1
2:
    sw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t2, t2, -1
    bnez    t2, 2b

    /* 3. Left 5 px (0x1F) and right 5 px (0xF8) across middle rows (y = 5..474) */
    li      t0, VIDEO_FRAMEBUF_BASE + (BOOT_SPLASH_BORDER_PX * VIDEO_STRIDE_BYTES)
    li      t1, VIDEO_FRAMEBUF_BASE + ((VIDEO_HEIGHT - BOOT_SPLASH_BORDER_PX) * VIDEO_STRIDE_BYTES)
3:
    lbu     t2, 0(t0)
    ori     t2, t2, BOOT_SPLASH_BORDER_LEFT
    sb      t2, 0(t0)
    lbu     t2, (VIDEO_STRIDE_BYTES - 1)(t0)
    ori     t2, t2, BOOT_SPLASH_BORDER_RIGHT
    sb      t2, (VIDEO_STRIDE_BYTES - 1)(t0)
    addi    t0, t0, VIDEO_STRIDE_BYTES
    bltu    t0, t1, 3b
    ret
.size boot_draw_splash, . - boot_draw_splash

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

str_menu_top:
    .asciz  "\n  ============================================================================\n    Oasis32 System ROM v"

str_menu_div_enter:
    .asciz  "\n  ============================================================================\n\n  [ENTER]  Boot from SD Card"

str_menu_opt1_opt2:
    .asciz  "\n  [1]      Boot from disk image read from serial\n  [2]      Write disk image from serial to SD Card"

str_menu_opt3_prompt:
    .asciz  "\n  [3]      Run built-in hardware demo\n\n  Select an option: "

str_dis_no_disk:
    .asciz  " [disabled, no disk inserted]"

str_dis_bad_hdr:
    .asciz  " [disabled, not a valid OA32 header]"
