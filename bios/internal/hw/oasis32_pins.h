/*
 * ============================================================================
 * Oasis32 BIOS Private — Board Pin Wiring & DVI Crossbar
 * ============================================================================
 * PRIVATE TO bios/ — NEVER exposed to disks/ or docs/ProgrammersReference.md.
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Reference: docs/Hardware.md
 * ============================================================================
 */

#ifndef OASIS32_BIOS_HW_OASIS32_PINS_H
#define OASIS32_BIOS_HW_OASIS32_PINS_H

/* ----------------------------------------------------------------------------
 * IO_BANK0 GPIOx_CTRL Offsets (8*x + 4) & PADS_BANK0 GPIOx Offsets (4*x + 4)
 * ---------------------------------------------------------------------------- */
/* Debug Serial — CP2102N (UART0) */
#define IO_UART0_TX_CTRL_OFF        0x004   /* GP0 = UART0 TX */
#define IO_UART0_RX_CTRL_OFF        0x00C   /* GP1 = UART0 RX */
#define PADS_UART0_TX_OFF           0x004
#define PADS_UART0_RX_OFF           0x008

/* SD Card Breakout — BRK-SD v2.0 (SPI0 + SIO CS/CD) */
#define IO_SD_SCK_CTRL_OFF          0x014   /* GP2 = SPI0 SCK */
#define IO_SD_MOSI_CTRL_OFF         0x01C   /* GP3 = SPI0 TX (MOSI) */
#define IO_SD_MISO_CTRL_OFF         0x024   /* GP4 = SPI0 RX (MISO) */
#define IO_SD_CS_CTRL_OFF           0x02C   /* GP5 = SIO output (manual CS) */
#define IO_SD_CD_CTRL_OFF           0x034   /* GP6 = SIO input (active LOW) */
#define PADS_SD_SCK_OFF             0x00C
#define PADS_SD_MOSI_OFF            0x010
#define PADS_SD_MISO_OFF            0x014
#define PADS_SD_CS_OFF              0x018
#define PADS_SD_CD_OFF              0x01C
#define SIO_SD_CS_MASK              (1 << 5)
#define SIO_SD_CD_MASK              (1 << 6)

/* Display — Adafruit DVI Sock (GP12-GP19 = HSTX BIT0-BIT7) */
#define IO_DVI_BASE_CTRL_OFF        0x064   /* GP12 .. GP19 (0x09C) */
#define PADS_DVI_BASE_OFF           0x034   /* GP12 .. GP19 (0x050) */
#define HSTX_LANE0_P                ((1  << 8) | 0)
#define HSTX_LANE0_N                ((1 << 16) | (1  << 8) | 0)
#define HSTX_CLK_P                  (1 << 17)
#define HSTX_CLK_N                  ((1 << 17) | (1 << 16))
#define HSTX_LANE2_P                ((21 << 8) | 20)
#define HSTX_LANE2_N                ((1 << 16) | (21 << 8) | 20)
#define HSTX_LANE1_P                ((11 << 8) | 10)
#define HSTX_LANE1_N                ((1 << 16) | (11 << 8) | 10)

/* Keyboard / Mouse — CH9350 (UART1, State 2 @ 115200 8N1) */
#define IO_UART1_TX_CTRL_OFF        0x0A4   /* GP20 = UART1 TX -> CH9350 RX */
#define IO_UART1_RX_CTRL_OFF        0x0AC   /* GP21 = UART1 RX <- CH9350 TX */
#define PADS_UART1_TX_OFF           0x054
#define PADS_UART1_RX_OFF           0x058

/* Piezo Buzzer (PWM3 A) */
#define IO_PIEZO_CTRL_OFF           0x0B4   /* GP22 = PWM3 A */
#define PADS_PIEZO_OFF              0x05C

/* Status LEDs (SIO outputs) */
#define IO_LED_RED_CTRL_OFF         0x0D4   /* GP26 = Red LED */
#define IO_LED_GREEN_CTRL_OFF       0x0DC   /* GP27 = Green LED */
#define IO_LED_BLUE_CTRL_OFF        0x0E4   /* GP28 = Blue LED */
#define PADS_LED_RED_OFF            0x06C
#define PADS_LED_GREEN_OFF          0x070
#define PADS_LED_BLUE_OFF           0x074
#define SIO_LED_RED_MASK            (1 << 26)
#define SIO_LED_GREEN_MASK          (1 << 27)
#define SIO_LED_BLUE_MASK           (1 << 28)
#define SIO_LED_ALL_MASK            (SIO_LED_RED_MASK | SIO_LED_GREEN_MASK | SIO_LED_BLUE_MASK)

#endif /* OASIS32_BIOS_HW_OASIS32_PINS_H */
