/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Clock Tree & PLL_SYS Bring-Up (126.000 MHz)
 * ============================================================================
 * Switches from boot ROSC -> 12 MHz XOSC -> 126.000 MHz PLL_SYS and routes
 * clk_sys, clk_peri, and clk_hstx to 126.000 MHz (exact 25.2 MHz DVI pixel
 * clock / 115200.00 bps UART clock).
 *
 * References:
 *   - rp2350-datasheet.pdf §8.1.7 (CLOCKS), §8.2.8 (XOSC), §8.6.5 (PLL_SYS)
 * ============================================================================
 */

#include "hw/rp2350_regs.h"
#include "bios_config.h"

.section .text, "ax"

.global clocks_init_126mhz
.type clocks_init_126mhz, @function
clocks_init_126mhz:
    /* 1. Enable 12 MHz XOSC and wait for STABLE (bit 31) */
    li      t0, XOSC_BASE
    li      t1, CFG_XOSC_STARTUP_1MS
    sw      t1, XOSC_STARTUP_OFF(t0)
    li      t1, CFG_XOSC_CTRL_ENABLE_12M
    sw      t1, XOSC_CTRL_OFF(t0)
1:
    lw      t1, XOSC_STATUS_OFF(t0)
    bgez    t1, 1b

    /* 2. Switch clk_ref -> XOSC (12 MHz) and clk_sys -> clk_ref safely */
    li      t0, CLOCKS_BASE
    li      t1, CLK_REF_SRC_XOSC
    sw      t1, CLK_REF_CTRL_OFF(t0)
2:
    lw      t1, CLK_REF_SELECTED_OFF(t0)
    andi    t1, t1, CLK_REF_SEL_XOSC_BIT
    beqz    t1, 2b

    li      t1, CLK_SYS_SRC_REF
    sw      t1, CLK_SYS_CTRL_OFF(t0)
3:
    lw      t1, CLK_SYS_SELECTED_OFF(t0)
    andi    t1, t1, CLK_SYS_SEL_REF_BIT
    beqz    t1, 3b

    /* 3. Reset and release PLL_SYS */
    li      t0, RESETS_BASE + ATOMIC_SET
    li      t1, RESET_BIT_PLL_SYS
    sw      t1, RESETS_RESET_OFF(t0)
    li      t0, RESETS_BASE + ATOMIC_CLR
    sw      t1, RESETS_RESET_OFF(t0)
    li      t0, RESETS_BASE
4:
    lw      t2, RESETS_DONE_OFF(t0)
    and     t2, t2, t1
    beqz    t2, 4b

    /* 4. Program PLL_SYS: REFDIV=1, FBDIV=126 (VCO = 1512 MHz), power up VCO */
    li      t0, PLL_SYS_BASE
    li      t1, CFG_PLL_SYS_REFDIV
    sw      t1, PLL_CS_OFF(t0)
    li      t1, CFG_PLL_SYS_FBDIV
    sw      t1, PLL_FBDIV_INT_OFF(t0)

    li      t2, PLL_SYS_BASE + ATOMIC_CLR
    li      t1, PLL_PWR_PD_VCO_MASK
    sw      t1, PLL_PWR_OFF(t2)
5:
    lw      t1, PLL_CS_OFF(t0)
    bgez    t1, 5b                      /* Wait for LOCK (bit 31) */

    /* 5. Program post-dividers (6 * 2 = 12 -> 126.000 MHz) and power up */
    li      t1, CFG_PLL_SYS_PRIM_6_2
    sw      t1, PLL_PRIM_OFF(t0)
    li      t1, PLL_PWR_POSTDIVPD_BIT
    sw      t1, PLL_PWR_OFF(t2)

    /* 6. Switch clk_sys -> pll_sys (div = 1) */
    li      t0, CLOCKS_BASE
    li      t1, CLK_SYS_DIV_1
    sw      t1, CLK_SYS_DIV_OFF(t0)
    li      t1, CLK_SYS_SRC_AUX_PLL
    sw      t1, CLK_SYS_CTRL_OFF(t0)
6:
    lw      t1, CLK_SYS_SELECTED_OFF(t0)
    andi    t1, t1, CLK_SYS_SEL_AUX_BIT
    beqz    t1, 6b

    /* 7. Enable clk_peri and clk_hstx sourced from clk_sys (126.000 MHz) */
    li      t1, CLK_PERI_EN_SYS
    sw      t1, CLK_PERI_CTRL_OFF(t0)
    li      t1, CLK_HSTX_DIV_1
    sw      t1, CLK_HSTX_DIV_OFF(t0)
    li      t1, CLK_HSTX_EN_SYS
    sw      t1, CLK_HSTX_CTRL_OFF(t0)
    ret
.size clocks_init_126mhz, . - clocks_init_126mhz
