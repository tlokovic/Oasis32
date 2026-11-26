/*
 * ============================================================================
 * Oasis32 BIOS Private — RP2350 Silicon Register Map & Hazard3 CSRs
 * ============================================================================
 * PRIVATE TO bios/ — NEVER exposed to disks/ or docs/ProgrammersReference.md.
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Primary Sources:
 *   - rp2350-datasheet.pdf (RP2350 Silicon Reference)
 *   - hazard3-manual.pdf   (Hazard3 RISC-V Core Reference)
 * ============================================================================
 */

#ifndef OASIS32_BIOS_HW_RP2350_REGS_H
#define OASIS32_BIOS_HW_RP2350_REGS_H

/* ----------------------------------------------------------------------------
 * Atomic Register Alias Offsets (rp2350-datasheet.pdf §2.1.3, p. 24)
 * Note: SIO (0xD0000000) does NOT support bus aliases.
 * ---------------------------------------------------------------------------- */
#define ATOMIC_XOR                  0x1000
#define ATOMIC_SET                  0x2000
#define ATOMIC_CLR                  0x3000

/* ----------------------------------------------------------------------------
 * Peripheral Base Addresses (validated on RP2350 silicon in Phase 2)
 * ---------------------------------------------------------------------------- */
#define CLOCKS_BASE                 0x40010000  /* §8.1.7, p. 481 */
#define RESETS_BASE                 0x40020000  /* §7.5.3, p. 459 */
#define IO_BANK0_BASE               0x40028000  /* §9.11.1, p. 549 */
#define PADS_BANK0_BASE             0x40038000  /* §9.11.3, p. 694 */
#define XOSC_BASE                   0x40048000  /* §8.2.8, p. 509 */
#define PLL_SYS_BASE                0x40050000  /* §8.6.5, p. 535 */
#define BUSCTRL_BASE                0x40068000  /* §12.15.4.3, p. 1170 */
#define UART0_BASE                  0x40070000  /* §12.1.8, p. 883 */
#define UART1_BASE                  0x40078000  /* §12.1.8, p. 883 */
#define SPI0_BASE                   0x40080000  /* §12.3.5, p. 958 */
#define PWM_BASE                    0x400A8000  /* §12.5.3, p. 984 */
#define TIMER0_BASE                 0x400B0000  /* §12.8.5, p. 1099 */
#define HSTX_CTRL_BASE              0x400C0000  /* §12.11.7, p. 1120 */
#define TICKS_BASE                  0x40108000  /* §8.5.2, p. 522 */

#define DMA_BASE                    0x50000000  /* §12.6.10, p. 1025 */
#define USBCTRL_DPRAM_BASE          0x50100000  /* §12.7.1.1.3, p. 1058 */
#define HSTX_FIFO_BASE              0x50600000  /* §12.11.8, p. 1123 */
#define HSTX_FIFO_DATA              0x50600004

#define SIO_BASE                    0xD0000000  /* §3.1.11, p. 49 */

/* ----------------------------------------------------------------------------
 * XOSC Registers (§8.2.8, pp. 509-512)
 * ---------------------------------------------------------------------------- */
#define XOSC_CTRL_OFF               0x000
#define XOSC_STATUS_OFF             0x004
#define XOSC_STARTUP_OFF            0x00C
#define XOSC_STATUS_STABLE_BIT      (1 << 31)

/* ----------------------------------------------------------------------------
 * PLL Registers (§8.6.5, pp. 535-537)
 * ---------------------------------------------------------------------------- */
#define PLL_CS_OFF                  0x000
#define PLL_PWR_OFF                 0x004
#define PLL_FBDIV_INT_OFF           0x008
#define PLL_PRIM_OFF                0x00C
#define PLL_CS_LOCK_BIT             (1 << 31)
#define PLL_PWR_PD_VCO_MASK         ((1 << 5) | (1 << 0))
#define PLL_PWR_POSTDIVPD_BIT       (1 << 3)

/* ----------------------------------------------------------------------------
 * CLOCKS Registers (§8.1.7, pp. 490-492)
 * ---------------------------------------------------------------------------- */
#define CLK_REF_CTRL_OFF            0x030
#define CLK_REF_SELECTED_OFF        0x038
#define CLK_SYS_CTRL_OFF            0x03C
#define CLK_SYS_DIV_OFF             0x040
#define CLK_SYS_SELECTED_OFF        0x044
#define CLK_PERI_CTRL_OFF           0x048
#define CLK_HSTX_CTRL_OFF           0x054
#define CLK_HSTX_DIV_OFF            0x058

#define CLK_REF_SRC_XOSC            2
#define CLK_REF_SEL_XOSC_BIT        (1 << 2)
#define CLK_SYS_SRC_REF             0
#define CLK_SYS_SRC_AUX_PLL         ((0 << 5) | 1)
#define CLK_SYS_SEL_REF_BIT         (1 << 0)
#define CLK_SYS_SEL_AUX_BIT         (1 << 1)
#define CLK_SYS_DIV_1               (1 << 16)
#define CLK_PERI_EN_SYS             ((1 << 11) | (0 << 5))
#define CLK_HSTX_EN_SYS             ((1 << 11) | (0 << 5))
#define CLK_HSTX_DIV_1              (1 << 16)

/* ----------------------------------------------------------------------------
 * TICKS Registers (§8.5.2, pp. 522-524)
 * ---------------------------------------------------------------------------- */
#define TICKS_TIMER0_CTRL_OFF       0x018
#define TICKS_TIMER0_CYCLES_OFF     0x01C
#define TICKS_CTRL_ENABLE           1

/* ----------------------------------------------------------------------------
 * RESETS Registers (§7.5.3, pp. 459-462)
 * ---------------------------------------------------------------------------- */
#define RESETS_RESET_OFF            0x000
#define RESETS_DONE_OFF             0x008
#define RESET_BIT_BUSCTRL           (1 << 1)
#define RESET_BIT_DMA               (1 << 2)
#define RESET_BIT_HSTX              (1 << 3)
#define RESET_BIT_IO_BANK0          (1 << 6)
#define RESET_BIT_PADS_BANK0        (1 << 9)
#define RESET_BIT_PLL_SYS           (1 << 14)
#define RESET_BIT_PWM               (1 << 16)
#define RESET_BIT_SPI0              (1 << 18)
#define RESET_BIT_TIMER0            (1 << 23)
#define RESET_BIT_UART0             (1 << 26)
#define RESET_BIT_UART1             (1 << 27)
#define RESET_BIT_USBCTRL           (1 << 28)   /* Enables USB DPRAM (4 KB) */

/* ----------------------------------------------------------------------------
 * IO_BANK0 & PADS_BANK0 (§9.11.1, p. 549; §9.11.3, p. 694)
 * ---------------------------------------------------------------------------- */
#define IO_FUNCSEL_HSTX             0
#define IO_FUNCSEL_SPI              1
#define IO_FUNCSEL_UART             2
#define IO_FUNCSEL_PWM              4
#define IO_FUNCSEL_SIO              5

#define PADS_ISO_BIT                (1 << 8)    /* Resets to 1 on RP2350! */
#define PADS_OD_BIT                 (1 << 7)
#define PADS_IE_BIT                 (1 << 6)
#define PADS_PUE_BIT                (1 << 3)
#define PADS_PDE_BIT                (1 << 2)
#define PADS_SLEWFAST_BIT           (1 << 0)

/* ----------------------------------------------------------------------------
 * SIO Registers (§3.1.11, Table 17, pp. 49-51)
 * ---------------------------------------------------------------------------- */
#define SIO_CPUID_OFF               0x000
#define SIO_GPIO_IN_OFF             0x004
#define SIO_GPIO_OUT_SET_OFF        0x018
#define SIO_GPIO_OUT_CLR_OFF        0x020
#define SIO_GPIO_OE_SET_OFF         0x038
#define SIO_FIFO_ST_OFF             0x050
#define SIO_FIFO_WR_OFF             0x054
#define SIO_FIFO_RD_OFF             0x058
#define SIO_FIFO_ST_VLD_BIT         (1 << 0)
#define SIO_FIFO_ST_RDY_BIT         (1 << 1)

/* ----------------------------------------------------------------------------
 * PL011 UART Registers (§12.1.8, pp. 883-895)
 * ---------------------------------------------------------------------------- */
#define UART_DR_OFF                 0x000
#define UART_FR_OFF                 0x018
#define UART_IBRD_OFF               0x024
#define UART_FBRD_OFF               0x028
#define UART_LCR_H_OFF              0x02C
#define UART_CR_OFF                 0x030
#define UART_IFLS_OFF               0x034
#define UART_IMSC_OFF               0x038
#define UART_MIS_OFF                0x040
#define UART_ICR_OFF                0x044

#define UART_FR_BUSY_BIT            (1 << 3)
#define UART_FR_RXFE_BIT            (1 << 4)
#define UART_FR_TXFF_BIT            (1 << 5)
#define UART_FR_TXFE_BIT            (1 << 7)
#define UART_LCR_8N1_FIFO           0x70
#define UART_CR_EN_TX_RX            0x301

/* ----------------------------------------------------------------------------
 * PL022 SPI0 Registers (§12.3.5, p. 958)
 * ---------------------------------------------------------------------------- */
#define SPI_SSPCR0_OFF              0x000
#define SPI_SSPCR1_OFF              0x004
#define SPI_SSPDR_OFF               0x008
#define SPI_SSPSR_OFF               0x00C
#define SPI_SSPCPSR_OFF             0x010
#define SPI_SR_TNF_BIT              (1 << 1)
#define SPI_SR_RNE_BIT              (1 << 2)
#define SPI_CR1_ENABLE              (1 << 1)

/* ----------------------------------------------------------------------------
 * PWM Registers (§12.5.3, p. 984)
 * ---------------------------------------------------------------------------- */
#define PWM_CH3_CSR_OFF             0x03C
#define PWM_CH3_DIV_OFF             0x040
#define PWM_CH3_CTR_OFF             0x044
#define PWM_CH3_CC_OFF              0x048
#define PWM_CH3_TOP_OFF             0x04C

/* ----------------------------------------------------------------------------
 * TIMER0 Registers (§12.8.5, p. 1099)
 * ---------------------------------------------------------------------------- */
#define TIMER_TIMEHR_OFF            0x008
#define TIMER_TIMELR_OFF            0x00C
#define TIMER_RAWL_OFF              0x028
#define TIMER_RAWH_OFF              0x024

/* ----------------------------------------------------------------------------
 * HSTX & DMA & BUSCTRL (§12.11.7, §12.6.10, §12.15.4.3)
 * ---------------------------------------------------------------------------- */
#define HSTX_CSR_OFF                0x000
#define HSTX_BIT0_OFF               0x004
#define HSTX_BIT1_OFF               0x008
#define HSTX_BIT2_OFF               0x00C
#define HSTX_BIT3_OFF               0x010
#define HSTX_BIT4_OFF               0x014
#define HSTX_BIT5_OFF               0x018
#define HSTX_BIT6_OFF               0x01C
#define HSTX_BIT7_OFF               0x020
#define HSTX_EXPAND_SHIFT_OFF       0x024
#define HSTX_EXPAND_TMDS_OFF        0x028

#define BUSCTRL_PRIORITY_OFF        0x000
#define BUSCTRL_PRIO_DMA_RW         ((1 << 12) | (1 << 8))

#define DMA_CH0_READ_OFF            0x000
#define DMA_CH0_WRITE_OFF           0x004
#define DMA_CH0_COUNT_OFF           0x008
#define DMA_CH0_AL1_CTRL_OFF        0x010
#define DMA_CH1_READ_OFF            0x040
#define DMA_CH1_WRITE_OFF           0x044
#define DMA_CH1_COUNT_OFF           0x048
#define DMA_CH1_AL1_CTRL_OFF        0x050
#define DMA_INTR_OFF                0x400
#define DMA_INTE0_OFF               0x404
#define DMA_INTS0_OFF               0x40C
#define DMA_MULTI_TRIG_OFF          0x450

/* ----------------------------------------------------------------------------
 * Hazard3 Standard & Xh3irq CSRs (hazard3-manual.pdf §4.1, pp. 38-43)
 * ---------------------------------------------------------------------------- */
#define CSR_MEIEA                   0xBE0
#define CSR_MEIPA                   0xBE1
#define CSR_MEIFA                   0xBE2
#define CSR_MEIPRA                  0xBE3
#define CSR_MEINEXT                 0xBE4
#define CSR_MEICONTEXT              0xBE5

#define MIE_MEIE_BIT                (1 << 11)
#define MSTATUS_MIE_BIT             (1 << 3)
#define MCAUSE_ECALL_M              11

#endif /* OASIS32_BIOS_HW_RP2350_REGS_H */
