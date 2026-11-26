/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Monotonic Microsecond Timer Driver (TICKS + TIMER0)
 * ============================================================================
 * Configures TICKS to divide 12 MHz clk_ref by 12 -> 1 MHz (1 us) TIMER0 tick,
 * and exposes an atomic, re-entrant 64-bit microsecond read matching
 * BIOS_TIME_US (0x50).
 *
 * References:
 *   - rp2350-datasheet.pdf §8.5.2 (TICKS), pp. 522-524
 *   - rp2350-datasheet.pdf §12.8.5 (TIMER0), pp. 1099-1102
 * ============================================================================
 */

#include "hw/rp2350_regs.h"
#include "bios_config.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * timer_init(): Start 1 MHz (1 us) tick generator for TIMER0
 * ---------------------------------------------------------------------------- */
.global timer_init
.type timer_init, @function
timer_init:
    li      t0, TICKS_BASE
    li      t1, CFG_TICKS_CYCLES_1US
    sw      t1, TICKS_TIMER0_CYCLES_OFF(t0)
    li      t1, TICKS_CTRL_ENABLE
    sw      t1, TICKS_TIMER0_CTRL_OFF(t0)
    ret
.size timer_init, . - timer_init

/* ----------------------------------------------------------------------------
 * timer_read_us() -> a0 = us_lo (uint32_t), a1 = us_hi (uint32_t)
 *   Atomic, ISR-safe 64-bit read via RAWH -> RAWL -> RAWH rollover check.
 * ---------------------------------------------------------------------------- */
.global timer_read_us
.type timer_read_us, @function
timer_read_us:
    li      t0, TIMER0_BASE
1:
    lw      a1, TIMER_RAWH_OFF(t0)
    lw      a0, TIMER_RAWL_OFF(t0)
    lw      t1, TIMER_RAWH_OFF(t0)
    bne     a1, t1, 1b
    ret
.size timer_read_us, . - timer_read_us
