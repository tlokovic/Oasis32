/*
 * ============================================================================
 * Oasis32 Public ABI — Memory Map Contract
 * ============================================================================
 * Single source of truth for all public SRAM and Video Memory addresses.
 * Consumed by both RISC-V assembly (.S) and preprocessed linker scripts (.ld.S).
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *       No GAS .equ directives, no C types, and no U/UL integer suffixes.
 *
 * Reference: docs/MemoryMap.md §2.1, docs/VideoArchitecture.md §2
 * ============================================================================
 */

#ifndef OASIS32_ABI_MEMORY_MAP_H
#define OASIS32_ABI_MEMORY_MAP_H

/* ----------------------------------------------------------------------------
 * Contiguous User SRAM (456 KB = 466,944 bytes)
 * ----------------------------------------------------------------------------
 * Stage-2 payloads are loaded and executed inside this window.
 * USER_STACK_TOP is 16-byte aligned per the RISC-V ILP32 psABI and grows
 * downward into User SRAM.
 */
#define USER_RAM_BASE           0x20000000
#define USER_RAM_SIZE           0x00072000
#define USER_RAM_END            0x20071FFF
#define USER_STACK_TOP          0x20072000

/* ----------------------------------------------------------------------------
 * Public Video Memory Block (56 KB = 57,344 bytes: 0x20072000 - 0x2007FFFF)
 * ----------------------------------------------------------------------------
 * Directly readable/writable by Stage-2 software; continuously scanned and
 * composited by the Video Coprocessor (no mode switching).
 */
#define VIDEO_RAM_BASE          0x20072000
#define VIDEO_RAM_SIZE          0x0000E000
#define VIDEO_RAM_END           0x2007FFFF

/* 640x480 @ 1 bpp monochrome framebuffer (80 bytes/scanline x 480 lines) */
#define VIDEO_FRAMEBUF_BASE     0x20072000
#define VIDEO_FRAMEBUF_SIZE     0x00009600      /* 38,400 bytes */
#define VIDEO_FRAMEBUF_END      0x2007B5FF

/* 256 glyphs x 8 bytes, glyph-major: FONT_RAM[ch * 8 + row] (glyph 0 = empty) */
#define VIDEO_FONT_RAM_BASE     0x2007B600
#define VIDEO_FONT_RAM_SIZE     0x00000800      /* 2,048 bytes */
#define VIDEO_FONT_RAM_END      0x2007BDFF

/* 80x60 character overlay grid: TEXT_BUF[row * 80 + col] (OR-composited) */
#define VIDEO_TEXT_BUF_BASE     0x2007BE00
#define VIDEO_TEXT_BUF_SIZE     0x000012C0      /* 4,800 bytes */
#define VIDEO_TEXT_BUF_END      0x2007D0BF

/* 80x60 per-cell text attributes: TEXT_ATTR[row * 80 + col] (bit 0 = reverse) */
#define VIDEO_TEXT_ATTR_BASE    0x2007D0C0
#define VIDEO_TEXT_ATTR_SIZE    0x000012C0      /* 4,800 bytes */
#define VIDEO_TEXT_ATTR_END     0x2007E37F

/* Public video control/status block (LATCH_OAM, future scroll/cursor fields) */
#define VIDEO_CTRL_BASE         0x2007E380
#define VIDEO_CTRL_SIZE         0x00000040      /* 64 bytes */
#define VIDEO_CTRL_END          0x2007E3BF

/* 16 simultaneous hardware sprite slots (8 bytes each; slot 0 = mouse cursor) */
#define VIDEO_SPRITE_OAM_BASE   0x2007E3C0
#define VIDEO_SPRITE_OAM_SIZE   0x00000080      /* 128 bytes */
#define VIDEO_SPRITE_OAM_END    0x2007E43F

/* 111 masked 16x16 2-plane sprite patterns (64 bytes each: 32 B px + 32 B mask) */
#define VIDEO_SPRITE_PAT_BASE   0x2007E440
#define VIDEO_SPRITE_PAT_SIZE   0x00001BC0      /* 7,104 bytes */
#define VIDEO_SPRITE_PAT_END    0x2007FFFF

#endif /* OASIS32_ABI_MEMORY_MAP_H */
