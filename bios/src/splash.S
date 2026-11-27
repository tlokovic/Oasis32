/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Embedded Startup Splash Screen (640x480 1 bpp)
 * ============================================================================
 * Embeds `splash.bin` (38,400 bytes, top-down, LSB-left, 1=white) generated
 * at build time from `images/splash.bmp` by `cmake/bmp_to_fb.py`.
 *
 * Placed in XIP Flash `.rodata` (4-byte aligned for word-copy into
 * VIDEO_FRAMEBUF_BASE by `boot_draw_splash` in `bios/src/main.S`).
 * ============================================================================
 */

.section .rodata, "a"
.balign 4

.global bios_splash_fb
.type bios_splash_fb, @object
bios_splash_fb:
    .incbin "splash.bin"
.size bios_splash_fb, . - bios_splash_fb
