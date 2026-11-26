/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Default 8x8 CP437 Bitmap Font & RAM Loader
 * ============================================================================
 * Public-domain IBM Code Page 437 (256 glyphs x 8 bytes = 2,048 bytes) stored
 * in XIP Flash (.rodata) in glyph-major order: font[char * 8 + row].
 *
 * Human-Editable Visual Format:
 *   Each `font_row 0bXXXXXXXX` literal is written visually LEFT-TO-RIGHT
 *   (leftmost bit = leftmost pixel). At assemble time, the `font_row` macro
 *   bit-reverses each byte into Oasis32 native HSTX LSB-left order (bit 0 =
 *   leftmost pixel, bit 7 = rightmost pixel) so Core 1 scanline compositing
 *   is a single zero-overhead bitwise OR with FRAMEBUF.
 *
 * References:
 *   - docs/VideoArchitecture.md §2-§3
 *   - include/abi/memory_map.h (VIDEO_FONT_RAM_BASE = 0x2007D600, 2,048 B)
 * ============================================================================
 */

#include "abi/memory_map.h"

/* Assemble-time 8-bit reversal: MSB-left visual literal -> LSB-left HSTX byte */
.macro font_row b
    .byte (((\b) & 0x01) << 7) | (((\b) & 0x02) << 5) | \
          (((\b) & 0x04) << 3) | (((\b) & 0x08) << 1) | \
          (((\b) & 0x10) >> 1) | (((\b) & 0x20) >> 3) | \
          (((\b) & 0x40) >> 5) | (((\b) & 0x80) >> 7)
.endm

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * font_load_default(): Copy default CP437 8x8 Flash font into VIDEO_FONT_RAM
 * ---------------------------------------------------------------------------- */
.global font_load_default
.type font_load_default, @function
font_load_default:
    la      a0, font_cp437_8x8
    j       font_load
.size font_load_default, . - font_load_default

/* ----------------------------------------------------------------------------
 * font_load(a0 = 4-byte-aligned 2,048 B font table):
 *   Copies 2,048 bytes (512 words) from a0 into VIDEO_FONT_RAM_BASE.
 * ---------------------------------------------------------------------------- */
.global font_load
.type font_load, @function
font_load:
    li      t0, VIDEO_FONT_RAM_BASE
    li      t1, VIDEO_FONT_RAM_BASE + VIDEO_FONT_RAM_SIZE
1:
    lw      t2, 0(a0)
    sw      t2, 0(t0)
    addi    a0, a0, 4
    addi    t0, t0, 4
    bltu    t0, t1, 1b
    ret
.size font_load, . - font_load

/* ============================================================================
 * IBM Code Page 437 8x8 Font Table (256 glyphs x 8 bytes = 2,048 bytes)
 * ============================================================================ */
.section .rodata, "a"
.p2align 2
.global font_cp437_8x8
font_cp437_8x8:

    /* 0x00 (0) NUL (empty/transparent) */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x01 (1) smiley hollow */
    font_row 0b01111110
    font_row 0b10000001
    font_row 0b10100101
    font_row 0b10000001
    font_row 0b10100101
    font_row 0b10011001
    font_row 0b10000001
    font_row 0b01111110

    /* 0x02 (2) smiley filled */
    font_row 0b01111110
    font_row 0b11111111
    font_row 0b11011011
    font_row 0b11111111
    font_row 0b11011011
    font_row 0b11100111
    font_row 0b11111111
    font_row 0b01111110

    /* 0x03 (3) heart */
    font_row 0b01101100
    font_row 0b11111110
    font_row 0b11111110
    font_row 0b11111110
    font_row 0b01111100
    font_row 0b00111000
    font_row 0b00010000
    font_row 0b00000000

    /* 0x04 (4) diamond */
    font_row 0b00010000
    font_row 0b00111000
    font_row 0b01111100
    font_row 0b11111110
    font_row 0b01111100
    font_row 0b00111000
    font_row 0b00010000
    font_row 0b00000000

    /* 0x05 (5) club */
    font_row 0b00111000
    font_row 0b01111100
    font_row 0b00111000
    font_row 0b11111110
    font_row 0b11111110
    font_row 0b00010000
    font_row 0b00010000
    font_row 0b01111100

    /* 0x06 (6) spade */
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b01111110
    font_row 0b11111111
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b01111110

    /* 0x07 (7) bullet */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x08 (8) inverse bullet */
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11100111
    font_row 0b11000011
    font_row 0b11000011
    font_row 0b11100111
    font_row 0b11111111
    font_row 0b11111111

    /* 0x09 (9) circle */
    font_row 0b00000000
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b01000010
    font_row 0b01000010
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00000000

    /* 0x0A (10) inverse circle */
    font_row 0b11111111
    font_row 0b11000011
    font_row 0b10011001
    font_row 0b10111101
    font_row 0b10111101
    font_row 0b10011001
    font_row 0b11000011
    font_row 0b11111111

    /* 0x0B (11) male */
    font_row 0b00001111
    font_row 0b00000111
    font_row 0b00001111
    font_row 0b01111101
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b01111000

    /* 0x0C (12) female */
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00011000

    /* 0x0D (13) eighth note */
    font_row 0b00111111
    font_row 0b00110011
    font_row 0b00111111
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b01110000
    font_row 0b11110000
    font_row 0b11100000

    /* 0x0E (14) beamed eighth notes */
    font_row 0b01111111
    font_row 0b01100011
    font_row 0b01111111
    font_row 0b01100011
    font_row 0b01100011
    font_row 0b01100111
    font_row 0b11100110
    font_row 0b11000000

    /* 0x0F (15) sun */
    font_row 0b10011001
    font_row 0b01011010
    font_row 0b00111100
    font_row 0b11100111
    font_row 0b11100111
    font_row 0b00111100
    font_row 0b01011010
    font_row 0b10011001

    /* 0x10 (16) right triangle */
    font_row 0b10000000
    font_row 0b11100000
    font_row 0b11111000
    font_row 0b11111110
    font_row 0b11111000
    font_row 0b11100000
    font_row 0b10000000
    font_row 0b00000000

    /* 0x11 (17) left triangle */
    font_row 0b00000010
    font_row 0b00001110
    font_row 0b00111110
    font_row 0b11111110
    font_row 0b00111110
    font_row 0b00001110
    font_row 0b00000010
    font_row 0b00000000

    /* 0x12 (18) up-down arrow */
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00111100
    font_row 0b00011000

    /* 0x13 (19) double exclamation */
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b01100110
    font_row 0b00000000

    /* 0x14 (20) pilcrow */
    font_row 0b01111111
    font_row 0b11011011
    font_row 0b11011011
    font_row 0b01111011
    font_row 0b00011011
    font_row 0b00011011
    font_row 0b00011011
    font_row 0b00000000

    /* 0x15 (21) section */
    font_row 0b00111111
    font_row 0b01100000
    font_row 0b01111100
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00111110
    font_row 0b00000110
    font_row 0b11111100

    /* 0x16 (22) black rectangle */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b01111110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x17 (23) up-down arrow with base */
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b11111111

    /* 0x18 (24) up arrow */
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x19 (25) down arrow */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b00000000

    /* 0x1A (26) right arrow */
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b11111110
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x1B (27) left arrow */
    font_row 0b00000000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b11111110
    font_row 0b01100000
    font_row 0b00110000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x1C (28) right angle */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111110
    font_row 0b00000000
    font_row 0b00000000

    /* 0x1D (29) left-right arrow */
    font_row 0b00000000
    font_row 0b00100100
    font_row 0b01100110
    font_row 0b11111111
    font_row 0b01100110
    font_row 0b00100100
    font_row 0b00000000
    font_row 0b00000000

    /* 0x1E (30) up triangle */
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b01111110
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000

    /* 0x1F (31) down triangle */
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b01111110
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x20 (32) SPACE */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x21 (33) '!' */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x22 (34) '"' */
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x23 (35) '#' */
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b11111110
    font_row 0b01101100
    font_row 0b11111110
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b00000000

    /* 0x24 (36) '$' */
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b11111100
    font_row 0b00011000
    font_row 0b00000000

    /* 0x25 (37) '%' */
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x26 (38) '&' */
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b00111000
    font_row 0b01110110
    font_row 0b11011100
    font_row 0b11001100
    font_row 0b01110110
    font_row 0b00000000

    /* 0x27 (39) ''' */
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x28 (40) '(' */
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b00000000

    /* 0x29 (41) ')' */
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b00000000

    /* 0x2A (42) '*' (asterisk) */
    font_row 0b00000000
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b11111111
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b00000000

    /* 0x2B (43) '+' */
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x2C (44) ',' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00110000

    /* 0x2D (45) '-' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x2E (46) '.' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x2F (47) '/' */
    font_row 0b00000110
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b11000000
    font_row 0b10000000
    font_row 0b00000000

    /* 0x30 (48) '0' */
    font_row 0b01111100
    font_row 0b11001110
    font_row 0b11011110
    font_row 0b11110110
    font_row 0b11100110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x31 (49) '1' */
    font_row 0b00011000
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00000000

    /* 0x32 (50) '2' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b00000110
    font_row 0b01111100
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111110
    font_row 0b00000000

    /* 0x33 (51) '3' */
    font_row 0b11111100
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00111100
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b11111100
    font_row 0b00000000

    /* 0x34 (52) '4' */
    font_row 0b00001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11111110
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00000000

    /* 0x35 (53) '5' */
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b11111100
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x36 (54) '6' */
    font_row 0b01111100
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x37 (55) '7' */
    font_row 0b11111110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00000000

    /* 0x38 (56) '8' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x39 (57) '9' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x3A (58) ':' */
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x3B (59) ';' */
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00110000

    /* 0x3C (60) '<' */
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b00000000

    /* 0x3D (61) '=' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x3E (62) '>' */
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b00000110
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b00000000

    /* 0x3F (63) '?' */
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x40 (64) '@' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11011110
    font_row 0b11011110
    font_row 0b11011110
    font_row 0b11000000
    font_row 0b01111110
    font_row 0b00000000

    /* 0x41 (65) 'A' */
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x42 (66) 'B' */
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111100
    font_row 0b00000000

    /* 0x43 (67) 'C' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x44 (68) 'D' */
    font_row 0b11111000
    font_row 0b11001100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11001100
    font_row 0b11111000
    font_row 0b00000000

    /* 0x45 (69) 'E' */
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111110
    font_row 0b00000000

    /* 0x46 (70) 'F' */
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b00000000

    /* 0x47 (71) 'G' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11001110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x48 (72) 'H' */
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x49 (73) 'I' */
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00000000

    /* 0x4A (74) 'J' */
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x4B (75) 'K' */
    font_row 0b11000110
    font_row 0b11001100
    font_row 0b11011000
    font_row 0b11110000
    font_row 0b11011000
    font_row 0b11001100
    font_row 0b11000110
    font_row 0b00000000

    /* 0x4C (76) 'L' */
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111110
    font_row 0b00000000

    /* 0x4D (77) 'M' */
    font_row 0b11000110
    font_row 0b11101110
    font_row 0b11111110
    font_row 0b11111110
    font_row 0b11010110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x4E (78) 'N' */
    font_row 0b11000110
    font_row 0b11100110
    font_row 0b11110110
    font_row 0b11011110
    font_row 0b11001110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x4F (79) 'O' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x50 (80) 'P' */
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111100
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b00000000

    /* 0x51 (81) 'Q' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11010110
    font_row 0b11011110
    font_row 0b01111100
    font_row 0b00000110

    /* 0x52 (82) 'R' */
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111100
    font_row 0b11011000
    font_row 0b11001100
    font_row 0b11000110
    font_row 0b00000000

    /* 0x53 (83) 'S' */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x54 (84) 'T' */
    font_row 0b11111111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x55 (85) 'U' */
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b00000000

    /* 0x56 (86) 'V' */
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00111000
    font_row 0b00000000

    /* 0x57 (87) 'W' */
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11010110
    font_row 0b11111110
    font_row 0b01101100
    font_row 0b00000000

    /* 0x58 (88) 'X' */
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01101100
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x59 (89) 'Y' */
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b11100000
    font_row 0b00000000

    /* 0x5A (90) 'Z' */
    font_row 0b11111110
    font_row 0b00000110
    font_row 0b00001100
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b11111110
    font_row 0b00000000

    /* 0x5B (91) '[' */
    font_row 0b00111100
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b00111100
    font_row 0b00000000

    /* 0x5C (92) '\\' (backslash) */
    font_row 0b11000000
    font_row 0b01100000
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b00000110
    font_row 0b00000010
    font_row 0b00000000

    /* 0x5D (93) ']' */
    font_row 0b00111100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00111100
    font_row 0b00000000

    /* 0x5E (94) '^' */
    font_row 0b00010000
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b11000110
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x5F (95) '_' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111

    /* 0x60 (96) '`' */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x61 (97) 'a' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x62 (98) 'b' */
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111100
    font_row 0b00000000

    /* 0x63 (99) 'c' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x64 (100) 'd' */
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x65 (101) 'e' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000000

    /* 0x66 (102) 'f' */
    font_row 0b00011100
    font_row 0b00110110
    font_row 0b00110000
    font_row 0b01111000
    font_row 0b00110000
    font_row 0b00110000
    font_row 0b01111000
    font_row 0b00000000

    /* 0x67 (103) 'g' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000110
    font_row 0b11111100

    /* 0x68 (104) 'h' */
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x69 (105) 'i' */
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00000000

    /* 0x6A (106) 'j' */
    font_row 0b00000110
    font_row 0b00000000
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b00000110
    font_row 0b11000110
    font_row 0b01111100

    /* 0x6B (107) 'k' */
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11001100
    font_row 0b11011000
    font_row 0b11111000
    font_row 0b11001100
    font_row 0b11000110
    font_row 0b00000000

    /* 0x6C (108) 'l' */
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00000000

    /* 0x6D (109) 'm' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11001100
    font_row 0b11111110
    font_row 0b11111110
    font_row 0b11010110
    font_row 0b11010110
    font_row 0b00000000

    /* 0x6E (110) 'n' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x6F (111) 'o' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x70 (112) 'p' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111100
    font_row 0b11000000
    font_row 0b11000000

    /* 0x71 (113) 'q' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000110
    font_row 0b00000110

    /* 0x72 (114) 'r' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b00000000

    /* 0x73 (115) 's' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b11111100
    font_row 0b00000000

    /* 0x74 (116) 't' */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00001110
    font_row 0b00000000

    /* 0x75 (117) 'u' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x76 (118) 'v' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00111000
    font_row 0b00000000

    /* 0x77 (119) 'w' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11010110
    font_row 0b11111110
    font_row 0b01101100
    font_row 0b00000000

    /* 0x78 (120) 'x' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b01101100
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b11000110
    font_row 0b00000000

    /* 0x79 (121) 'y' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000110
    font_row 0b11111100

    /* 0x7A (122) 'z' */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b00001100
    font_row 0b00111000
    font_row 0b01100000
    font_row 0b11111110
    font_row 0b00000000

    /* 0x7B (123) '{' */
    font_row 0b00001110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01110000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00001110
    font_row 0b00000000

    /* 0x7C (124) '|' */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0x7D (125) '}' */
    font_row 0b01110000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00001110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01110000
    font_row 0b00000000

    /* 0x7E (126) '~' */
    font_row 0b01110110
    font_row 0b11011100
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0x7F (127) house / DEL */
    font_row 0b00000000
    font_row 0b00010000
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b00000000

    /* 0x80 (128) CP437 0x80 */
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11010110
    font_row 0b01111100
    font_row 0b00110000

    /* 0x81 (129) CP437 0x81 */
    font_row 0b11000110
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x82 (130) CP437 0x82 */
    font_row 0b00001110
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000000

    /* 0x83 (131) CP437 0x83 */
    font_row 0b01111110
    font_row 0b10000001
    font_row 0b00111100
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x84 (132) CP437 0x84 */
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x85 (133) CP437 0x85 */
    font_row 0b11100000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x86 (134) CP437 0x86 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x87 (135) CP437 0x87 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11010110
    font_row 0b01111100
    font_row 0b00110000

    /* 0x88 (136) CP437 0x88 */
    font_row 0b01111110
    font_row 0b10000001
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000000

    /* 0x89 (137) CP437 0x89 */
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000000

    /* 0x8A (138) CP437 0x8A */
    font_row 0b11100000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b01111100
    font_row 0b00000000

    /* 0x8B (139) CP437 0x8B */
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00000000

    /* 0x8C (140) CP437 0x8C */
    font_row 0b01111100
    font_row 0b10000010
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00000000

    /* 0x8D (141) CP437 0x8D */
    font_row 0b01110000
    font_row 0b00000000
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00000000

    /* 0x8E (142) CP437 0x8E */
    font_row 0b11000110
    font_row 0b00010000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x8F (143) CP437 0x8F */
    font_row 0b00111000
    font_row 0b00111000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b11000110
    font_row 0b00000000

    /* 0x90 (144) CP437 0x90 */
    font_row 0b00001110
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b11000000
    font_row 0b11111000
    font_row 0b11000000
    font_row 0b11111110
    font_row 0b00000000

    /* 0x91 (145) CP437 0x91 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111111
    font_row 0b00001100
    font_row 0b01111111
    font_row 0b11001100
    font_row 0b01111111
    font_row 0b00000000

    /* 0x92 (146) CP437 0x92 */
    font_row 0b00111111
    font_row 0b01101100
    font_row 0b11001100
    font_row 0b11111111
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001111
    font_row 0b00000000

    /* 0x93 (147) CP437 0x93 */
    font_row 0b01111100
    font_row 0b10000010
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x94 (148) CP437 0x94 */
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x95 (149) CP437 0x95 */
    font_row 0b11100000
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x96 (150) CP437 0x96 */
    font_row 0b01111100
    font_row 0b10000010
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x97 (151) CP437 0x97 */
    font_row 0b11100000
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0x98 (152) CP437 0x98 */
    font_row 0b01100110
    font_row 0b00000000
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00111110
    font_row 0b00000110
    font_row 0b01111100

    /* 0x99 (153) CP437 0x99 */
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0x9A (154) CP437 0x9A */
    font_row 0b11000110
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11111110
    font_row 0b00000000

    /* 0x9B (155) CP437 0x9B */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b11011000
    font_row 0b11011000
    font_row 0b11011000
    font_row 0b01111110
    font_row 0b00011000

    /* 0x9C (156) CP437 0x9C */
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b01100000
    font_row 0b11110000
    font_row 0b01100000
    font_row 0b01100110
    font_row 0b11111100
    font_row 0b00000000

    /* 0x9D (157) CP437 0x9D */
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00011000

    /* 0x9E (158) CP437 0x9E */
    font_row 0b11111000
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11111010
    font_row 0b11000110
    font_row 0b11001111
    font_row 0b11000110
    font_row 0b11000011

    /* 0x9F (159) CP437 0x9F */
    font_row 0b00001110
    font_row 0b00011011
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11011000
    font_row 0b01110000

    /* 0xA0 (160) CP437 0xA0 */
    font_row 0b00001110
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b00000110
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0xA1 (161) CP437 0xA1 */
    font_row 0b00011100
    font_row 0b00000000
    font_row 0b00111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b00000000

    /* 0xA2 (162) CP437 0xA2 */
    font_row 0b00001110
    font_row 0b00000000
    font_row 0b01111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0xA3 (163) CP437 0xA3 */
    font_row 0b00001110
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111110
    font_row 0b00000000

    /* 0xA4 (164) CP437 0xA4 */
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b00000000

    /* 0xA5 (165) CP437 0xA5 */
    font_row 0b11111110
    font_row 0b00000000
    font_row 0b11000110
    font_row 0b11100110
    font_row 0b11110110
    font_row 0b11011110
    font_row 0b11001110
    font_row 0b00000000

    /* 0xA6 (166) CP437 0xA6 */
    font_row 0b00111100
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b00111110
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00000000

    /* 0xA7 (167) CP437 0xA7 */
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00000000

    /* 0xA8 (168) CP437 0xA8 */
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00000000

    /* 0xA9 (169) CP437 0xA9 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xAA (170) CP437 0xAA */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00000000
    font_row 0b00000000

    /* 0xAB (171) CP437 0xAB */
    font_row 0b11000110
    font_row 0b11001100
    font_row 0b11011000
    font_row 0b00111111
    font_row 0b01100011
    font_row 0b11001111
    font_row 0b10001100
    font_row 0b00001111

    /* 0xAC (172) CP437 0xAC */
    font_row 0b11000011
    font_row 0b11000110
    font_row 0b11001100
    font_row 0b11011011
    font_row 0b00110111
    font_row 0b01101101
    font_row 0b11001111
    font_row 0b00000011

    /* 0xAD (173) CP437 0xAD */
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0xAE (174) CP437 0xAE */
    font_row 0b00000000
    font_row 0b00110011
    font_row 0b01100110
    font_row 0b11001100
    font_row 0b01100110
    font_row 0b00110011
    font_row 0b00000000
    font_row 0b00000000

    /* 0xAF (175) CP437 0xAF */
    font_row 0b00000000
    font_row 0b11001100
    font_row 0b01100110
    font_row 0b00110011
    font_row 0b01100110
    font_row 0b11001100
    font_row 0b00000000
    font_row 0b00000000

    /* 0xB0 (176) light shade */
    font_row 0b00100010
    font_row 0b10001000
    font_row 0b00100010
    font_row 0b10001000
    font_row 0b00100010
    font_row 0b10001000
    font_row 0b00100010
    font_row 0b10001000

    /* 0xB1 (177) medium shade */
    font_row 0b01010101
    font_row 0b10101010
    font_row 0b01010101
    font_row 0b10101010
    font_row 0b01010101
    font_row 0b10101010
    font_row 0b01010101
    font_row 0b10101010

    /* 0xB2 (178) dark shade */
    font_row 0b11011101
    font_row 0b01110111
    font_row 0b11011101
    font_row 0b01110111
    font_row 0b11011101
    font_row 0b01110111
    font_row 0b11011101
    font_row 0b01110111

    /* 0xB3 (179) box vertical */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xB4 (180) CP437 0xB4 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xB5 (181) CP437 0xB5 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xB6 (182) CP437 0xB6 */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xB7 (183) CP437 0xB7 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xB8 (184) CP437 0xB8 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xB9 (185) CP437 0xB9 */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11110110
    font_row 0b00000110
    font_row 0b11110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xBA (186) box double vertical */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xBB (187) box double down-left */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b00000110
    font_row 0b11110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xBC (188) box double up-left */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11110110
    font_row 0b00000110
    font_row 0b11111110
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xBD (189) CP437 0xBD */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11111110
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xBE (190) CP437 0xBE */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xBF (191) box single down-left */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xC0 (192) box single up-right */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xC1 (193) CP437 0xC1 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xC2 (194) CP437 0xC2 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xC3 (195) CP437 0xC3 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xC4 (196) box horizontal */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xC5 (197) box cross */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xC6 (198) CP437 0xC6 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xC7 (199) CP437 0xC7 */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xC8 (200) box double up-right */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110111
    font_row 0b00110000
    font_row 0b00111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xC9 (201) box double down-right */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00111111
    font_row 0b00110000
    font_row 0b00110111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xCA (202) CP437 0xCA */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11110111
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xCB (203) CP437 0xCB */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b11110111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xCC (204) CP437 0xCC */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110111
    font_row 0b00110000
    font_row 0b00110111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xCD (205) box double horizontal */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xCE (206) CP437 0xCE */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11110111
    font_row 0b00000000
    font_row 0b11110111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xCF (207) CP437 0xCF */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xD0 (208) CP437 0xD0 */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xD1 (209) CP437 0xD1 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xD2 (210) CP437 0xD2 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xD3 (211) CP437 0xD3 */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xD4 (212) CP437 0xD4 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xD5 (213) CP437 0xD5 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xD6 (214) CP437 0xD6 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00111111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xD7 (215) CP437 0xD7 */
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b11111111
    font_row 0b00110110
    font_row 0b00110110
    font_row 0b00110110

    /* 0xD8 (216) CP437 0xD8 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111111
    font_row 0b00011000
    font_row 0b11111111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xD9 (217) box single up-left */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11111000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xDA (218) box single down-right */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011111
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xDB (219) full block */
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111

    /* 0xDC (220) lower half block */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111

    /* 0xDD (221) left half block */
    font_row 0b11110000
    font_row 0b11110000
    font_row 0b11110000
    font_row 0b11110000
    font_row 0b11110000
    font_row 0b11110000
    font_row 0b11110000
    font_row 0b11110000

    /* 0xDE (222) right half block */
    font_row 0b00001111
    font_row 0b00001111
    font_row 0b00001111
    font_row 0b00001111
    font_row 0b00001111
    font_row 0b00001111
    font_row 0b00001111
    font_row 0b00001111

    /* 0xDF (223) upper half block */
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b11111111
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xE0 (224) CP437 0xE0 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01110110
    font_row 0b11011100
    font_row 0b11001000
    font_row 0b11011100
    font_row 0b01110110
    font_row 0b00000000

    /* 0xE1 (225) CP437 0xE1 */
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b01111000
    font_row 0b01101100
    font_row 0b01100110
    font_row 0b01101100
    font_row 0b01100000

    /* 0xE2 (226) CP437 0xE2 */
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b11000110
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b11000000
    font_row 0b00000000

    /* 0xE3 (227) CP437 0xE3 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b11111110
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b00000000

    /* 0xE4 (228) CP437 0xE4 */
    font_row 0b11111110
    font_row 0b01100000
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b11111110
    font_row 0b00000000

    /* 0xE5 (229) CP437 0xE5 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b11011000
    font_row 0b11011000
    font_row 0b11011000
    font_row 0b01110000
    font_row 0b00000000

    /* 0xE6 (230) CP437 0xE6 */
    font_row 0b00000000
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b01111100
    font_row 0b01100000
    font_row 0b11000000

    /* 0xE7 (231) CP437 0xE7 */
    font_row 0b00000000
    font_row 0b01110110
    font_row 0b11011100
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0xE8 (232) CP437 0xE8 */
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00011000
    font_row 0b01111110

    /* 0xE9 (233) CP437 0xE9 */
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b11000011
    font_row 0b11111111
    font_row 0b11000011
    font_row 0b01100110
    font_row 0b00111100
    font_row 0b00000000

    /* 0xEA (234) CP437 0xEA */
    font_row 0b00111100
    font_row 0b01100110
    font_row 0b11000011
    font_row 0b11000011
    font_row 0b01100110
    font_row 0b01100110
    font_row 0b11100111
    font_row 0b00000000

    /* 0xEB (235) CP437 0xEB */
    font_row 0b00001110
    font_row 0b00011000
    font_row 0b00001100
    font_row 0b01111110
    font_row 0b11000110
    font_row 0b11000110
    font_row 0b01111100
    font_row 0b00000000

    /* 0xEC (236) CP437 0xEC */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b11011011
    font_row 0b11011011
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00000000

    /* 0xED (237) CP437 0xED */
    font_row 0b00000110
    font_row 0b00001100
    font_row 0b01111110
    font_row 0b11011011
    font_row 0b11011011
    font_row 0b01111110
    font_row 0b01100000
    font_row 0b11000000

    /* 0xEE (238) CP437 0xEE */
    font_row 0b00111000
    font_row 0b01100000
    font_row 0b11000000
    font_row 0b11111000
    font_row 0b11000000
    font_row 0b01100000
    font_row 0b00111000
    font_row 0b00000000

    /* 0xEF (239) CP437 0xEF */
    font_row 0b01111000
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b11001100
    font_row 0b00000000

    /* 0xF0 (240) CP437 0xF0 */
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00000000

    /* 0xF1 (241) CP437 0xF1 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b01111110
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000

    /* 0xF2 (242) CP437 0xF2 */
    font_row 0b01100000
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b00000000

    /* 0xF3 (243) CP437 0xF3 */
    font_row 0b00011000
    font_row 0b00110000
    font_row 0b01100000
    font_row 0b00110000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b11111100
    font_row 0b00000000

    /* 0xF4 (244) CP437 0xF4 */
    font_row 0b00001110
    font_row 0b00011011
    font_row 0b00011011
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000

    /* 0xF5 (245) CP437 0xF5 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b11011000
    font_row 0b11011000
    font_row 0b01110000

    /* 0xF6 (246) CP437 0xF6 */
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b01111110
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000

    /* 0xF7 (247) CP437 0xF7 */
    font_row 0b00000000
    font_row 0b01110110
    font_row 0b11011100
    font_row 0b00000000
    font_row 0b01110110
    font_row 0b11011100
    font_row 0b00000000
    font_row 0b00000000

    /* 0xF8 (248) CP437 0xF8 */
    font_row 0b00111000
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b00111000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xF9 (249) CP437 0xF9 */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xFA (250) CP437 0xFA */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00011000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xFB (251) CP437 0xFB */
    font_row 0b00001111
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b00001100
    font_row 0b11101100
    font_row 0b01101100
    font_row 0b00111100
    font_row 0b00011100

    /* 0xFC (252) CP437 0xFC */
    font_row 0b01111000
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b01101100
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xFD (253) CP437 0xFD */
    font_row 0b01111100
    font_row 0b00001100
    font_row 0b01111100
    font_row 0b01100000
    font_row 0b01111100
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000

    /* 0xFE (254) CP437 0xFE */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00111100
    font_row 0b00111100
    font_row 0b00111100
    font_row 0b00111100
    font_row 0b00000000
    font_row 0b00000000

    /* 0xFF (255) NBSP (blank) */
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
    font_row 0b00000000
