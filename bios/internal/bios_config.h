/*
 * ============================================================================
 * Oasis32 BIOS Private — Clock, Baud, SPI, PWM & DMA Configuration
 * ============================================================================
 * PRIVATE TO bios/ — NEVER exposed to disks/ or docs/ProgrammersReference.md.
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * All divisors verified against 12 MHz XOSC -> 126.000 MHz PLL_SYS in Phase 2.
 * ============================================================================
 */

#ifndef OASIS32_BIOS_CONFIG_H
#define OASIS32_BIOS_CONFIG_H

/* ----------------------------------------------------------------------------
 * Oasis32 System ROM / BIOS Version (returned by BIOS_SYS_VERSION)
 * ---------------------------------------------------------------------------- */
#define BIOS_VERSION_MAJOR          0
#define BIOS_VERSION_MINOR          1
#define BIOS_VERSION_PATCH          0
#define BIOS_VERSION_PACKED         ((BIOS_VERSION_MAJOR << 16) | (BIOS_VERSION_MINOR << 8) | BIOS_VERSION_PATCH)

/* ----------------------------------------------------------------------------
 * XOSC (12 MHz) & PLL_SYS (126.000 MHz)
 *   f_vco = 12 MHz * 126 = 1512 MHz; f_out = 1512 / (6 * 2) = 126.000 MHz
 * ---------------------------------------------------------------------------- */
#define CFG_XOSC_STARTUP_1MS        47
#define CFG_XOSC_CTRL_ENABLE_12M    0x00FABAA0
#define CFG_PLL_SYS_REFDIV          1
#define CFG_PLL_SYS_FBDIV           126
#define CFG_PLL_SYS_PRIM_6_2        ((6 << 16) | (2 << 12))

/* TIMER0 1 MHz (1 us) tick from 12 MHz clk_ref */
#define CFG_TICKS_CYCLES_1US        12

/* ----------------------------------------------------------------------------
 * UART0 & UART1 @ 115200 baud (clk_peri = 126 MHz, 0.000% exact error)
 *   BRD = 126,000,000 / (16 * 115,200) = 68.359375 -> IBRD = 68, FBRD = 23
 * ---------------------------------------------------------------------------- */
#define CFG_UART_IBRD_115200        68
#define CFG_UART_FBRD_115200        23

/* ----------------------------------------------------------------------------
 * SPI0 (SD Card) Divisors @ clk_peri = 126 MHz
 *   Init: 126 MHz / (16 * (1 + 19)) = 393.75 kHz (within 100-400 kHz spec)
 *   Run:  126 MHz / (10 * (1 + 0))  = 12.60 MHz
 * ---------------------------------------------------------------------------- */
#define CFG_SPI_CR0_INIT_394K       ((19 << 8) | 0x07)
#define CFG_SPI_CPSR_INIT_394K      16
#define CFG_SPI_CR0_RUN_12M6        ((0  << 8) | 0x07)
#define CFG_SPI_CPSR_RUN_12M6       10

/* ----------------------------------------------------------------------------
 * PWM Piezo Base Divider (126 MHz / 126.0 = 1 MHz counter tick)
 * ---------------------------------------------------------------------------- */
#define CFG_PWM_PIEZO_DIV_126       (126 << 4)

/* ----------------------------------------------------------------------------
 * HSTX 1 bpp DVI Timing & DMA Channels (640x480 @ 60 Hz, 25.2 MHz pixel clk)
 * ---------------------------------------------------------------------------- */
#define CFG_HSTX_EXPAND_TMDS_1BPP   0x00191919
#define CFG_HSTX_EXPAND_SHIFT_1BPP  0x00010100
#define CFG_HSTX_CSR_DVI_ENABLE     0x50050203

#define CFG_DMA_DREQ_HSTX           52
#define CFG_DMA_CTRL_PING           ((52 << 17) | (1 << 13) | (1 << 4) | (2 << 2) | 1)
#define CFG_DMA_CTRL_PONG           ((52 << 17) | (0 << 13) | (1 << 4) | (2 << 2) | 1)

#define CFG_MODE_V_FRONT_PORCH      10
#define CFG_MODE_V_SYNC_END         12
#define CFG_MODE_V_BLANK_END        45
#define CFG_MODE_V_ACTIVE           480
#define CFG_MODE_V_TOTAL            525

#endif /* OASIS32_BIOS_CONFIG_H */
