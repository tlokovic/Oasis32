/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Text Console & Hardware Cursor (BIOS_BLK_TEXT, 0x80)
 * ============================================================================
 * Manages the 80x60 TEXT_BUF (0x2007DE00, 4,800 B) and the BIOS-owned hardware
 * text cursor state stored atomically in USB DPRAM (BIOS_CURSOR_STATE_ADDR):
 *   bits [7:0]   = col (0..79)
 *   bits [15:8]  = row (0..59)
 *   bits [23:16] = visible (0 = hidden, 1 = visible)
 *   bits [31:24] = blink_frames (0 = solid, 1..255 = 60 Hz half-period)
 *
 * Core 1 latches this 32-bit word once per frame during VBLANK and inverts
 * (^ 0xFF) the active 8x8 cell non-destructively during Layer 3 compositing.
 *
 * Exposes BIOS_BLK_TEXT (0x80-0x87):
 *   - text_clear            ()                  -> ERR_OK
 *   - text_putc             (a0=ch)             -> ERR_OK
 *   - text_puts             (a0=cstr_ptr)       -> ERR_OK or ERR_INVALID_ARG
 *   - text_set_cursor_pos   (a0=col, a1=row)    -> ERR_OK or ERR_INVALID_ARG
 *   - text_get_cursor_pos   ()                  -> a0=col, a1=row
 *   - text_set_cursor_state (a0=vis, a1=frames) -> ERR_OK or ERR_INVALID_ARG
 *   - text_scroll_up        (a0=lines)          -> ERR_OK
 *   - text_scroll_down      (a0=lines)          -> ERR_OK
 *
 * References:
 *   - include/abi/bios_abi.h (BIOS_BLK_TEXT 0x80-0x87)
 *   - docs/VideoArchitecture.md §2-§3
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "bios_ram.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * text_clear() -> a0 = ERR_OK (0)
 *   Zero-fills TEXT_BUF (4,800 B) and resets cursor to (0, 0), preserving
 *   visibility and blink rate.
 * ---------------------------------------------------------------------------- */
.global text_clear
.type text_clear, @function
text_clear:
    li      t0, VIDEO_TEXT_BUF_BASE
    li      t1, VIDEO_TEXT_BUF_BASE + VIDEO_TEXT_BUF_SIZE
1:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b

    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    srli    t1, t1, 16
    slli    t1, t1, 16                      /* Clear col & row to (0, 0) */
    sw      t1, 0(t0)

    li      a0, ERR_OK
    ret
.size text_clear, . - text_clear

/* ----------------------------------------------------------------------------
 * text_set_cursor_pos(a0 = col, a1 = row) -> a0 = ERR_OK or ERR_INVALID_ARG
 *   Sets cursor position (col in 0..79, row in 0..59).
 * ---------------------------------------------------------------------------- */
.global text_set_cursor_pos
.type text_set_cursor_pos, @function
text_set_cursor_pos:
    li      t0, VIDEO_TEXT_COLS
    bgeu    a0, t0, 1f
    li      t0, VIDEO_TEXT_ROWS
    bgeu    a1, t0, 1f

    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    srli    t1, t1, 16
    slli    t1, t1, 16                      /* Preserve [blink:8 | vis:8] */
    slli    t2, a1, 8
    or      t1, t1, t2
    or      t1, t1, a0
    sw      t1, 0(t0)

    li      a0, ERR_OK
    ret
1:
    li      a0, ERR_INVALID_ARG
    ret
.size text_set_cursor_pos, . - text_set_cursor_pos

/* ----------------------------------------------------------------------------
 * text_get_cursor_pos() -> a0 = col (0..79), a1 = row (0..59)
 * ---------------------------------------------------------------------------- */
.global text_get_cursor_pos
.type text_get_cursor_pos, @function
text_get_cursor_pos:
    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    andi    a0, t1, 0xFF
    srli    a1, t1, 8
    andi    a1, a1, 0xFF
    ret
.size text_get_cursor_pos, . - text_get_cursor_pos

/* ----------------------------------------------------------------------------
 * text_set_cursor_state(a0 = vis, a1 = frames) -> a0 = ERR_OK or ERR_INVALID_ARG
 *   vis: 0 = hidden, nonzero = visible
 *   frames: 0 = solid, 1..255 = blink half-period in 60 Hz frames
 * ---------------------------------------------------------------------------- */
.global text_set_cursor_state
.type text_set_cursor_state, @function
text_set_cursor_state:
    li      t0, 255
    bgtu    a1, t0, 1f

    snez    t2, a0                          /* Normalize vis to 0 or 1 */
    slli    t2, t2, 16
    slli    t3, a1, 24
    or      t2, t2, t3                      /* [frames:8 | vis:8 | 0:16] */

    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    slli    t1, t1, 16
    srli    t1, t1, 16                      /* Preserve [row:8 | col:8] */
    or      t1, t1, t2
    sw      t1, 0(t0)

    li      a0, ERR_OK
    ret
1:
    li      a0, ERR_INVALID_ARG
    ret
.size text_set_cursor_state, . - text_set_cursor_state

/* ----------------------------------------------------------------------------
 * text_scroll_up(a0 = lines) -> a0 = ERR_OK (0)
 *   Scrolls TEXT_BUF up by `lines` rows, filling bottom rows with 0x00.
 *   Does not alter cursor coordinates.
 * ---------------------------------------------------------------------------- */
.global text_scroll_up
.type text_scroll_up, @function
text_scroll_up:
    beqz    a0, scroll_up_done

    li      t0, VIDEO_TEXT_ROWS
    bgeu    a0, t0, scroll_up_zero_all

    /* Forward word copy: dst = BASE, src = BASE + lines * 80, until src == END */
    li      t0, VIDEO_TEXT_COLS
    mul     t0, a0, t0                      /* byte_shift = lines * 80 */
    li      t1, VIDEO_TEXT_BUF_BASE         /* dst */
    add     t2, t1, t0                      /* src */
    li      t3, VIDEO_TEXT_BUF_BASE + VIDEO_TEXT_BUF_SIZE
1:
    lw      t4, 0(t2)
    sw      t4, 0(t1)
    addi    t1, t1, 4
    addi    t2, t2, 4
    bltu    t2, t3, 1b

    /* Zero-fill bottom `lines` rows from dst..END */
2:
    sw      zero, 0(t1)
    addi    t1, t1, 4
    bltu    t1, t3, 2b
    j       scroll_up_done

scroll_up_zero_all:
    li      t1, VIDEO_TEXT_BUF_BASE
    li      t3, VIDEO_TEXT_BUF_BASE + VIDEO_TEXT_BUF_SIZE
3:
    sw      zero, 0(t1)
    addi    t1, t1, 4
    bltu    t1, t3, 3b

scroll_up_done:
    li      a0, ERR_OK
    ret
.size text_scroll_up, . - text_scroll_up

/* ----------------------------------------------------------------------------
 * text_scroll_down(a0 = lines) -> a0 = ERR_OK (0)
 *   Scrolls TEXT_BUF down by `lines` rows, filling top rows with 0x00.
 *   Does not alter cursor coordinates.
 * ---------------------------------------------------------------------------- */
.global text_scroll_down
.type text_scroll_down, @function
text_scroll_down:
    beqz    a0, scroll_down_done

    li      t0, VIDEO_TEXT_ROWS
    bgeu    a0, t0, scroll_down_zero_all

    /* Backward word copy: dst = END, src = END - lines * 80, down to BASE */
    li      t0, VIDEO_TEXT_COLS
    mul     t0, a0, t0                      /* byte_shift = lines * 80 */
    li      t3, VIDEO_TEXT_BUF_BASE         /* base floor */
    li      t1, VIDEO_TEXT_BUF_BASE + VIDEO_TEXT_BUF_SIZE /* dst */
    sub     t2, t1, t0                      /* src */
1:
    addi    t1, t1, -4
    addi    t2, t2, -4
    lw      t4, 0(t2)
    sw      t4, 0(t1)
    bgtu    t2, t3, 1b

    /* Zero-fill top `lines` rows from BASE..BASE + byte_shift */
    add     t2, t3, t0
2:
    sw      zero, 0(t3)
    addi    t3, t3, 4
    bltu    t3, t2, 2b
    j       scroll_down_done

scroll_down_zero_all:
    li      t1, VIDEO_TEXT_BUF_BASE
    li      t3, VIDEO_TEXT_BUF_BASE + VIDEO_TEXT_BUF_SIZE
3:
    sw      zero, 0(t1)
    addi    t1, t1, 4
    bltu    t1, t3, 3b

scroll_down_done:
    li      a0, ERR_OK
    ret
.size text_scroll_down, . - text_scroll_down

/* ----------------------------------------------------------------------------
 * text_putc(a0 = ch) -> a0 = ERR_OK (0)
 *   Writes character at current cursor position, advancing/wrapping and
 *   auto-scrolling up past row 59.
 *   Control chars:
 *     '\n' (0x0A): Unix newline (col = 0, row++, scroll up if row >= 60)
 *     '\r' (0x0D): Carriage return (col = 0)
 *     '\b' (0x08): Left (col--; wraps to end of previous line if col == 0 & row > 0)
 * ---------------------------------------------------------------------------- */
.global text_putc
.type text_putc, @function
text_putc:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)
    sw      s2, 0(sp)

    andi    s0, a0, 0xFF                    /* s0 = ch */
    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    andi    s1, t1, 0xFF                    /* s1 = col (0..79) */
    srli    s2, t1, 8
    andi    s2, s2, 0xFF                    /* s2 = row (0..59) */

    /* Check control characters */
    li      t0, '\n'
    beq     s0, t0, putc_newline
    li      t0, '\r'
    beq     s0, t0, putc_cr
    li      t0, '\b'
    beq     s0, t0, putc_bs

    /* Normal glyph write at TEXT_BUF[row * 80 + col] */
    li      t0, VIDEO_TEXT_COLS
    mul     t0, s2, t0
    add     t0, t0, s1
    li      t1, VIDEO_TEXT_BUF_BASE
    add     t0, t1, t0
    sb      s0, 0(t0)

    /* Advance col; wrap to next line at col == 80 */
    addi    s1, s1, 1
    li      t0, VIDEO_TEXT_COLS
    bltu    s1, t0, putc_commit
    li      s1, 0
    j       putc_advance_row

putc_newline:
    li      s1, 0
putc_advance_row:
    addi    s2, s2, 1
    li      t0, VIDEO_TEXT_ROWS
    bltu    s2, t0, putc_commit
    li      s2, (VIDEO_TEXT_ROWS - 1)
    li      a0, 1
    call    text_scroll_up
    j       putc_commit

putc_cr:
    li      s1, 0
    j       putc_commit

putc_bs:
    beqz    s1, 1f
    addi    s1, s1, -1
    j       putc_commit
1:
    beqz    s2, putc_commit
    li      s1, (VIDEO_TEXT_COLS - 1)
    addi    s2, s2, -1

putc_commit:
    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    srli    t1, t1, 16
    slli    t1, t1, 16                      /* Preserve [blink:8 | vis:8] */
    slli    t2, s2, 8
    or      t1, t1, t2
    or      t1, t1, s1
    sw      t1, 0(t0)

    li      a0, ERR_OK
    lw      s2, 0(sp)
    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size text_putc, . - text_putc

/* ----------------------------------------------------------------------------
 * text_puts(a0 = cstr_ptr) -> a0 = ERR_OK or ERR_INVALID_ARG
 *   Prints NUL-terminated string in User SRAM via text_putc semantics.
 * ---------------------------------------------------------------------------- */
.global text_puts
.type text_puts, @function
text_puts:
    li      t0, USER_RAM_BASE
    bltu    a0, t0, puts_invalid_early
    li      t0, (USER_RAM_BASE + USER_RAM_SIZE)
    bgeu    a0, t0, puts_invalid_early

    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)

    mv      s0, a0                          /* s0 = current char ptr */
    li      s1, (USER_RAM_BASE + USER_RAM_SIZE)
1:
    bgeu    s0, s1, puts_invalid
    lbu     a0, 0(s0)
    beqz    a0, puts_ok
    call    text_putc
    addi    s0, s0, 1
    j       1b

puts_ok:
    li      a0, ERR_OK
    j       puts_done
puts_invalid:
    li      a0, ERR_INVALID_ARG
puts_done:
    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

puts_invalid_early:
    li      a0, ERR_INVALID_ARG
    ret
.size text_puts, . - text_puts
