/*
 * ============================================================================
 * Pico 2 Desert Island — Bare-Metal RISC-V Test Harness (Phase 2, Stage 2b)
 * ============================================================================
 * Pure RP2350 Hazard3 RISC-V assembly with ZERO Pico SDK, runtime startup
 * files, or third-party libraries (-nostdlib -nostartfiles -nodefaultlibs).
 *
 * Stage 2b implements:
 *   - Clock tree: 12 MHz XOSC -> PLL_SYS (126 MHz) -> clk_sys, clk_peri, clk_hstx
 *   - 1 MHz (1 us) free-running hardware timebase on TIMER0
 *   - Status LEDs: Red (GP26) -> Green (GP27) -> Blue (GP28), advancing 1/sec
 *   - Piezo Buzzer: GP22 (PWM3 A), 1 kHz tone for 100 ms every 3 s
 *   - Debug Serial (CP2102N): UART0 (GP0 TX, GP1 RX) at 115200 8N1
 *       * Non-blocking 1024-byte software TX ring buffer
 *       * Boot banner on startup, 1 s heartbeat, dec/hex/bin RX echo
 *   - HDMI Display (Adafruit DVI Sock): HSTX on GP12-GP19, 640x480 @ 60 Hz
 *       * 38,400-byte 1 bpp monochrome framebuffer in SRAM
 *       * Zero-CPU hardware TMDS expansion + ping-pong DMA (DREQ_HSTX = 52)
 *       * SRAM-resident DMA_IRQ_0 (IRQ 10) handler via Hazard3 Xh3irq CSRs
 *       * Static 1 px border + 20x15 (32x32 px) grid + bouncing 32x32 XOR box
 *
 * Primary Authoritative Documentation:
 *   - rp2350-datasheet.pdf (RP2350 Silicon Reference)
 *   - pico-2-datasheet.pdf (Raspberry Pi Pico 2 Board Reference)
 *   - hazard3-manual.pdf   (Hazard3 RISC-V Core Reference)
 * ============================================================================
 */

/* ============================================================================
 * 1. Peripheral Base Addresses & Atomic Register Alias Offsets
 * ============================================================================
 * RP2350 APB/AHB peripherals support atomic bitwise alias windows
 * (rp2350-datasheet.pdf §2.1.3, p. 24):
 *   +0x0000 : Normal R/W
 *   +0x1000 : Atomic XOR
 *   +0x2000 : Atomic SET
 *   +0x3000 : Atomic CLEAR
 * Note: SIO (0xD0000000) does NOT support bus aliases; it provides dedicated
 * *_SET / *_CLR / *_XOR registers in its own register map.
 */
.equ ATOMIC_SET,            0x2000
.equ ATOMIC_CLR,            0x3000

.equ CLOCKS_BASE,           0x40010000  /* rp2350-datasheet.pdf §8.1.7, p. 481 */
.equ RESETS_BASE,           0x40020000  /* rp2350-datasheet.pdf §7.5.3, p. 459 */
.equ IO_BANK0_BASE,         0x40028000  /* rp2350-datasheet.pdf §9.11.1, p. 549 */
.equ PADS_BANK0_BASE,       0x40038000  /* rp2350-datasheet.pdf §9.11.3, p. 694 */
.equ XOSC_BASE,             0x40048000  /* rp2350-datasheet.pdf §8.2.8, p. 509 */
.equ PLL_SYS_BASE,          0x40050000  /* rp2350-datasheet.pdf §8.6.5, p. 535 */
.equ BUSCTRL_BASE,          0x40068000  /* rp2350-datasheet.pdf §12.15.4.3, p. 1170 */
.equ UART0_BASE,            0x40070000  /* rp2350-datasheet.pdf §12.1.8, p. 883 */
.equ PWM_BASE,              0x400A8000  /* rp2350-datasheet.pdf §12.5.3, p. 984 */
.equ TIMER0_BASE,           0x400B0000  /* rp2350-datasheet.pdf §12.8.5, p. 1099 */
.equ HSTX_CTRL_BASE,        0x400C0000  /* rp2350-datasheet.pdf §12.11.7, p. 1120 */
.equ TICKS_BASE,            0x40108000  /* rp2350-datasheet.pdf §8.5.2, p. 522 */
.equ DMA_BASE,              0x50000000  /* rp2350-datasheet.pdf §12.6.10, p. 1025 */
.equ HSTX_FIFO_BASE,        0x50600000  /* rp2350-datasheet.pdf §12.11.8, p. 1123 */
.equ HSTX_FIFO_DATA,        0x50600004  /* HSTX_FIFO.FIFO write port (+0x004) */
.equ SIO_BASE,              0xD0000000  /* rp2350-datasheet.pdf §3.1.11, p. 49 */

/* ----------------------------------------------------------------------------
 * XOSC Registers (rp2350-datasheet.pdf §8.2.8, Tables 630–634, pp. 509–512)
 *   Startup delay (1 ms @ 12 MHz): ceil(12,000,000 * 0.001 / 256) = 47
 *   CTRL: ENABLE (0xFAB << 12) | FREQ_RANGE_1_15MHZ (0xAA0) = 0x00FABAA0
 * ---------------------------------------------------------------------------- */
.equ XOSC_CTRL_OFF,         0x000
.equ XOSC_STATUS_OFF,       0x004
.equ XOSC_STARTUP_OFF,      0x00C
.equ XOSC_STARTUP_1MS,      47
.equ XOSC_CTRL_ENABLE_12M,  0x00FABAA0

/* ----------------------------------------------------------------------------
 * PLL_SYS Registers (rp2350-datasheet.pdf §8.6.5, Tables 668–672, pp. 535–537)
 *   Target clk_sys = 126.000 MHz (matches 25.2 MHz DVI pixel clock in Stage 2b):
 *     REFDIV   = 1   -> f_ref = 12 MHz
 *     FBDIV    = 126 -> f_vco = 12 MHz * 126 = 1512 MHz (within 750–1600 MHz)
 *     POSTDIV1 = 6, POSTDIV2 = 2 -> f_out = 1512 / (6 * 2) = 126.000 MHz exact
 * ---------------------------------------------------------------------------- */
.equ PLL_CS_OFF,            0x000
.equ PLL_PWR_OFF,           0x004
.equ PLL_FBDIV_INT_OFF,     0x008
.equ PLL_PRIM_OFF,          0x00C
.equ PLL_PWR_PD_VCO_MASK,   ((1 << 5) | (1 << 0))   /* VCOPD | PD */
.equ PLL_PWR_POSTDIVPD_BIT, (1 << 3)
.equ PLL_SYS_REFDIV,        1
.equ PLL_SYS_FBDIV,         126
.equ PLL_SYS_PRIM_6_2,      ((6 << 16) | (2 << 12)) /* POSTDIV1=6, POSTDIV2=2 */

/* ----------------------------------------------------------------------------
 * CLOCKS Registers (rp2350-datasheet.pdf §8.1.7, Tables 588–596, pp. 490–492)
 *   CLK_REF_CTRL  (0x030): SRC=2 (xosc_clksrc)      -> SELECTED bit 2
 *   CLK_SYS_CTRL  (0x03C): AUXSRC=0 (pll_sys), SRC=1 -> SELECTED bit 1
 *   CLK_PERI_CTRL (0x048): ENABLE (bit 11) | AUXSRC=0 (clk_sys = 126 MHz)
 * ---------------------------------------------------------------------------- */
.equ CLK_REF_CTRL_OFF,      0x030
.equ CLK_REF_SELECTED_OFF,  0x038
.equ CLK_SYS_CTRL_OFF,      0x03C
.equ CLK_SYS_DIV_OFF,       0x040
.equ CLK_SYS_SELECTED_OFF,  0x044
.equ CLK_PERI_CTRL_OFF,     0x048
.equ CLK_HSTX_CTRL_OFF,     0x054
.equ CLK_HSTX_DIV_OFF,      0x058

.equ CLK_REF_SRC_XOSC,      2
.equ CLK_REF_SEL_XOSC_BIT,  (1 << 2)
.equ CLK_SYS_SRC_REF,       0
.equ CLK_SYS_SRC_AUX_PLL,   ((0 << 5) | 1)
.equ CLK_SYS_SEL_REF_BIT,   (1 << 0)
.equ CLK_SYS_SEL_AUX_BIT,   (1 << 1)
.equ CLK_SYS_DIV_1,         (1 << 16)
.equ CLK_PERI_EN_SYS,       ((1 << 11) | (0 << 5))
.equ CLK_HSTX_EN_SYS,       ((1 << 11) | (0 << 5))  /* ENABLE | AUXSRC=0 (clk_sys) */
.equ CLK_HSTX_DIV_1,        (1 << 16)

/* ----------------------------------------------------------------------------
 * TICKS Registers (rp2350-datasheet.pdf §8.5.2, Tables 649–652, pp. 522–524)
 *   Divide 12 MHz clk_ref by 12 -> 1 MHz (1 us) TIMER0 tick.
 * ---------------------------------------------------------------------------- */
.equ TICKS_TIMER0_CTRL_OFF,   0x018
.equ TICKS_TIMER0_CYCLES_OFF, 0x01C
.equ TICKS_CYCLES_1US,        12
.equ TICKS_CTRL_ENABLE,       1

/* ----------------------------------------------------------------------------
 * RESETS Registers (rp2350-datasheet.pdf §7.5.3, Tables 566–569, pp. 459–462)
 * ---------------------------------------------------------------------------- */
.equ RESETS_RESET_OFF,      0x000
.equ RESETS_DONE_OFF,       0x008
.equ RESET_BIT_BUSCTRL,     (1 << 1)
.equ RESET_BIT_DMA,         (1 << 2)
.equ RESET_BIT_HSTX,        (1 << 3)
.equ RESET_BIT_IO_BANK0,    (1 << 6)
.equ RESET_BIT_PADS_BANK0,  (1 << 9)
.equ RESET_BIT_PLL_SYS,     (1 << 14)
.equ RESET_BIT_PWM,         (1 << 16)
.equ RESET_BIT_TIMER0,      (1 << 23)
.equ RESET_BIT_UART0,       (1 << 26)
.equ RESETS_STAGE2B_MASK,   (RESET_BIT_BUSCTRL | RESET_BIT_DMA | RESET_BIT_HSTX | \
                             RESET_BIT_IO_BANK0 | RESET_BIT_PADS_BANK0 | \
                             RESET_BIT_PWM | RESET_BIT_TIMER0 | RESET_BIT_UART0)

/* ----------------------------------------------------------------------------
 * GPIO / IO_BANK0 / PADS_BANK0 / SIO Offsets
 *   IO_BANK0:   GPIOx_CTRL = 8*x + 4   (rp2350-datasheet.pdf §9.11.1, p. 549)
 *   PADS_BANK0: GPIOx      = 4*x + 4   (rp2350-datasheet.pdf §9.11.3, p. 694)
 *     Bit 8 = ISO (resets to 1 on RP2350 — must be cleared!)
 *     Bit 7 = OD  (output disable)
 *     Bit 6 = IE  (input enable)
 *     Bit 3 = PUE (pull-up enable)
 *     Bit 2 = PDE (pull-down enable)
 *   SIO (RP2350 interleaved map, §3.1.11, Table 17, pp. 49–51):
 *     0x018 = GPIO_OUT_SET, 0x020 = GPIO_OUT_CLR, 0x038 = GPIO_OE_SET
 * ---------------------------------------------------------------------------- */
.equ IO_FUNCSEL_HSTX,       0
.equ IO_FUNCSEL_UART,       2
.equ IO_FUNCSEL_PWM,        4
.equ IO_FUNCSEL_SIO,        5

.equ IO_GPIO0_CTRL_OFF,     0x004   /* GP0  = UART0 TX */
.equ IO_GPIO1_CTRL_OFF,     0x00C   /* GP1  = UART0 RX */
.equ IO_GPIO12_CTRL_OFF,    0x064   /* GP12 = HSTX BIT0 (D0+) .. GP19 = 0x09C */
.equ IO_GPIO22_CTRL_OFF,    0x0B4   /* GP22 = PWM3 A (Piezo) */
.equ IO_GPIO26_CTRL_OFF,    0x0D4   /* GP26 = Red LED */
.equ IO_GPIO27_CTRL_OFF,    0x0DC   /* GP27 = Green LED */
.equ IO_GPIO28_CTRL_OFF,    0x0E4   /* GP28 = Blue LED */

.equ PADS_GPIO0_OFF,        0x004
.equ PADS_GPIO1_OFF,        0x008
.equ PADS_GPIO12_OFF,       0x034   /* GP12 .. GP19 = 0x050 */
.equ PADS_GPIO22_OFF,       0x05C
.equ PADS_GPIO26_OFF,       0x06C
.equ PADS_GPIO27_OFF,       0x070
.equ PADS_GPIO28_OFF,       0x074

.equ PADS_ISO_BIT,          (1 << 8)
.equ PADS_OD_BIT,           (1 << 7)
.equ PADS_IE_BIT,           (1 << 6)
.equ PADS_PUE_BIT,          (1 << 3)
.equ PADS_PDE_BIT,          (1 << 2)
.equ PADS_SLEWFAST_BIT,     (1 << 0)
.equ PADS_ISO_OD_MASK,      (PADS_ISO_BIT | PADS_OD_BIT)
.equ PADS_RX_CLR_MASK,      (PADS_ISO_BIT | PADS_PDE_BIT)
.equ PADS_RX_SET_MASK,      (PADS_IE_BIT  | PADS_PUE_BIT)

.equ SIO_GPIO_OUT_SET_OFF,  0x018
.equ SIO_GPIO_OUT_CLR_OFF,  0x020
.equ SIO_GPIO_OE_SET_OFF,   0x038

.equ LED_RED_MASK,          (1 << 26)
.equ LED_GREEN_MASK,        (1 << 27)
.equ LED_BLUE_MASK,         (1 << 28)
.equ LED_ALL_MASK,          (LED_RED_MASK | LED_GREEN_MASK | LED_BLUE_MASK)

/* ----------------------------------------------------------------------------
 * PWM Slice 3 Registers (GP22 = PWM3 A, rp2350-datasheet.pdf §12.5.3, p. 984)
 *   f_pwm = f_sys / ((TOP + 1) * DIV)
 *   With f_sys = 126 MHz, DIV = 126.0 (126 << 4 = 0x7E0) -> 1 MHz tick:
 *     TOP = 999  -> 1,000,000 / 1000 = 1000 Hz (1 kHz)
 *     CC  = 500  -> 50% duty cycle (active)
 *     CC  = 0    -> 0% duty cycle (silent)
 * ---------------------------------------------------------------------------- */
.equ PWM_CH3_CSR_OFF,       0x03C
.equ PWM_CH3_DIV_OFF,       0x040
.equ PWM_CH3_CTR_OFF,       0x044
.equ PWM_CH3_CC_OFF,        0x048
.equ PWM_CH3_TOP_OFF,       0x04C

.equ PWM_PIEZO_DIV_126,     (126 << 4)
.equ PWM_PIEZO_TOP,         999
.equ PWM_PIEZO_CC_ON,       500
.equ PWM_PIEZO_CC_OFF,      0

/* ----------------------------------------------------------------------------
 * PL011 UART0 Registers (rp2350-datasheet.pdf §12.1.8, Tables 1081–1089)
 *   Baud Rate Divisor @ clk_peri = 126 MHz, 115200 baud (§12.1.3.2.1, p. 875):
 *     BRD = 126,000,000 / (16 * 115,200) = 68.359375
 *     IBRD = 68
 *     FBRD = floor(0.359375 * 64 + 0.5) = 23  (0.000% exact baud error!)
 *   UARTLCR_H: WLEN=0b11 (8-bit, bits 6:5) | FEN=1 (FIFOs, bit 4) = 0x70
 *   UARTCR:    RXE (bit 9) | TXE (bit 8) | UARTEN (bit 0)         = 0x301
 * ---------------------------------------------------------------------------- */
.equ UART_DR_OFF,           0x000
.equ UART_FR_OFF,           0x018
.equ UART_IBRD_OFF,         0x024
.equ UART_FBRD_OFF,         0x028
.equ UART_LCR_H_OFF,        0x02C
.equ UART_CR_OFF,           0x030

.equ UART_FR_RXFE_BIT,      (1 << 4)    /* Receive FIFO Empty */
.equ UART_FR_TXFF_BIT,      (1 << 5)    /* Transmit FIFO Full */
.equ UART0_IBRD_115200,     68
.equ UART0_FBRD_115200,     23
.equ UART_LCR_8N1_FIFO,     0x70
.equ UART_CR_EN_TX_RX,      0x301

.equ UART_TX_RING_SIZE,     1024
.equ UART_TX_RING_MASK,     (UART_TX_RING_SIZE - 1)

/* ----------------------------------------------------------------------------
 * HSTX, DMA, BUSCTRL & Hazard3 Xh3irq Constants (640x480 @ 60 Hz 1 bpp DVI)
 * ----------------------------------------------------------------------------
 * HSTX_CTRL (rp2350-datasheet.pdf §12.11.7, Tables 1364–1368, pp. 1120–1122):
 *   EXPAND_TMDS  = 0x00191919 : all 3 lanes ROT=25 (bit 0->7), NBITS=0 (1 bit)
 *   EXPAND_SHIFT = 0x00010100 : ENC_N_SHIFTS=0 (32 px/word), ENC_SHIFT=1,
 *                               RAW_N_SHIFTS=1, RAW_SHIFT=0
 *   CSR          = 0x50050203 : CLKDIV=5, N_SHIFTS=5, SHIFT=2, EXPAND_EN=1, EN=1
 * DMA (rp2350-datasheet.pdf §12.6.10, Tables 1258–1259, pp. 1033–1044):
 *   DREQ_HSTX = 52 (TREQ_SEL bits [22:17] = 52 << 17 = 0x00680000)
 *   CH0 (PING) chains to CH1 (0x00682019); CH1 (PONG) chains to CH0 (0x00680019)
 * Hazard3 Xh3irq (hazard3-manual.pdf §4.8.1, p. 53; Table 95, p. 81):
 *   DMA_IRQ_0 = IRQ 10 -> h3.meiea (CSR 0xBE0) window 0, bit (16 + 10) = 1 << 26
 * ---------------------------------------------------------------------------- */
.equ HSTX_CSR_OFF,          0x000
.equ HSTX_BIT0_OFF,         0x004
.equ HSTX_BIT1_OFF,         0x008
.equ HSTX_BIT2_OFF,         0x00C
.equ HSTX_BIT3_OFF,         0x010
.equ HSTX_BIT4_OFF,         0x014
.equ HSTX_BIT5_OFF,         0x018
.equ HSTX_BIT6_OFF,         0x01C
.equ HSTX_BIT7_OFF,         0x020
.equ HSTX_EXPAND_SHIFT_OFF, 0x024
.equ HSTX_EXPAND_TMDS_OFF,  0x028

.equ HSTX_EXPAND_TMDS_1BPP, 0x00191919
.equ HSTX_EXPAND_SHIFT_1BPP,0x00010100
.equ HSTX_CSR_DVI_ENABLE,   0x50050203

/* Adafruit DVI Sock crossbar (GP12/13=D0, GP14/15=CK, GP16/17=D2, GP18/19=D1) */
.equ HSTX_LANE0_P,          ((1  << 8) | 0)
.equ HSTX_LANE0_N,          ((1 << 16) | (1  << 8) | 0)
.equ HSTX_CLK_P,            (1 << 17)
.equ HSTX_CLK_N,            ((1 << 17) | (1 << 16))
.equ HSTX_LANE2_P,          ((21 << 8) | 20)
.equ HSTX_LANE2_N,          ((1 << 16) | (21 << 8) | 20)
.equ HSTX_LANE1_P,          ((11 << 8) | 10)
.equ HSTX_LANE1_N,          ((1 << 16) | (11 << 8) | 10)

.equ BUSCTRL_PRIORITY_OFF,  0x000
.equ BUSCTRL_PRIO_DMA_RW,   ((1 << 12) | (1 << 8))  /* DMA_W | DMA_R */

.equ DMA_CH0_READ_OFF,      0x000
.equ DMA_CH0_WRITE_OFF,     0x004
.equ DMA_CH0_COUNT_OFF,     0x008
.equ DMA_CH0_AL1_CTRL_OFF,  0x010
.equ DMA_CH1_READ_OFF,      0x040
.equ DMA_CH1_WRITE_OFF,     0x044
.equ DMA_CH1_COUNT_OFF,     0x048
.equ DMA_CH1_AL1_CTRL_OFF,  0x050
.equ DMA_INTR_OFF,          0x400
.equ DMA_INTE0_OFF,         0x404
.equ DMA_INTS0_OFF,         0x40C
.equ DMA_MULTI_TRIG_OFF,    0x450

.equ DMA_CTRL_PING,         ((52 << 17) | (1 << 13) | (1 << 4) | (2 << 2) | 1)
.equ DMA_CTRL_PONG,         ((52 << 17) | (0 << 13) | (1 << 4) | (2 << 2) | 1)

.equ CSR_MEIEA,             0xBE0
.equ H3_IRQ10_EN_WIN0,      (1 << (16 + 10))        /* DMA_IRQ_0 in window 0 */
.equ MIE_MEIE_BIT,          (1 << 11)               /* Machine External IRQ Enable */
.equ MSTATUS_MIE_BIT,       (1 << 3)                /* Global M-mode IRQ Enable */

/* 640x480 @ 60 Hz timing & framebuffer geometry */
.equ MODE_H_ACTIVE,         640
.equ MODE_V_FRONT_PORCH,    10
.equ MODE_V_SYNC_END,       12                      /* 10 + 2 */
.equ MODE_V_BLANK_END,      45                      /* 10 + 2 + 33 */
.equ MODE_V_ACTIVE,         480
.equ MODE_V_TOTAL,          525
.equ FB_WORDS_PER_LINE,     20                      /* 640 / 32 */
.equ FB_BYTES_PER_LINE,     80                      /* 20 * 4 */
.equ FB_TOTAL_BYTES,        38400                   /* 480 * 80 */

.equ BOX_SIZE_PX,           32
.equ BOX_MIN_X,             1
.equ BOX_MAX_X,             607                     /* 640 - 1 - 32 */
.equ BOX_MIN_Y,             1
.equ BOX_MAX_Y,             447                     /* 480 - 1 - 32 */

/* ----------------------------------------------------------------------------
 * TIMER0 & Scheduling Intervals (microseconds)
 * ---------------------------------------------------------------------------- */
.equ TIMER_RAWL_OFF,        0x028       /* Lower 32 bits of 1 MHz counter */
.equ LED_INTERVAL_US,       1000000     /* 1 s */
.equ HEARTBEAT_INTERVAL_US, 1000000     /* 1 s */
.equ PIEZO_PERIOD_US,       3000000     /* 3 s */
.equ PIEZO_DURATION_US,     100000      /* 100 ms */
.equ VIDEO_STEP_INTERVAL_US,16667       /* ~60 px/s (1 px per 60 Hz frame) */


/* ============================================================================
 * 2. Boot Entry Trampoline (.text.boot @ 0x10000000) & PICOBIN IMAGE_DEF
 * ============================================================================
 * Keeping .text.boot tiny guarantees that .picobin_block sits near 0x10000010,
 * well inside the Boot ROM's 4 kB scan window (0x10000000–0x10000FFF) no
 * matter how large .text grows in later stages.
 */
.section .text.boot, "ax"
.global _start
.type _start, @function
_start:
    la      sp, __stack_top             /* Top of SRAM (0x20082000) */
    j       boot_init
.size _start, . - _start

/* Minimum Viable RP2350 RISC-V IMAGE_DEF (rp2350-datasheet.pdf Table 504, p. 390) */
.section .picobin_block, "a"
.p2align 2
picobin_image_def:
    .word   0xffffded3                  /* PICOBIN_BLOCK_MARKER_START */
    .word   0x11010142                  /* IMAGE_TYPE: EXE | RISCV | RP2350 */
    .word   0x000001ff                  /* LAST item (1 preceding word) */
    .word   0x00000000                  /* Next block offset (self-loop) */
    .word   0xab123579                  /* PICOBIN_BLOCK_MARKER_END */


/* ============================================================================
 * 3. Main Program Code (.text in XIP Flash)
 * ============================================================================ */
.section .text, "ax"

/* ----------------------------------------------------------------------------
 * boot_init: Zero .bss, bring up clocks/peripherals, enter non-blocking loop
 * ---------------------------------------------------------------------------- */
boot_init:
    /* 1a. Copy initialized .data and SRAM-resident .ramfunc from Flash to SRAM. */
    la      t0, __etext                 /* LMA source in Flash */
    la      t1, __data_start            /* VMA destination in SRAM */
    la      t2, __data_end
copy_data_loop:
    bgeu    t1, t2, copy_data_done
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       copy_data_loop
copy_data_done:

    /* 1b. Zero-initialize .bss in SRAM (__bss_start .. __bss_end). */
    la      t0, __bss_start
    la      t1, __bss_end
zero_bss_loop:
    bgeu    t0, t1, zero_bss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       zero_bss_loop
zero_bss_done:

    /* 2. Bring up 12 MHz XOSC -> 126 MHz PLL_SYS -> clk_sys, clk_peri, clk_hstx. */
    call    clocks_init_126mhz

    /* 3. Start 1 MHz (1 us) tick generator for TIMER0. */
    li      t0, TICKS_BASE
    li      t1, TICKS_CYCLES_1US
    sw      t1, TICKS_TIMER0_CYCLES_OFF(t0)
    li      t1, TICKS_CTRL_ENABLE
    sw      t1, TICKS_TIMER0_CTRL_OFF(t0)

    /* 4. Release BUSCTRL, DMA, HSTX, IO_BANK0, PADS_BANK0, PWM, TIMER0, UART0. */
    li      t0, RESETS_BASE + ATOMIC_CLR
    li      t1, RESETS_STAGE2B_MASK
    sw      t1, RESETS_RESET_OFF(t0)
    li      t0, RESETS_BASE
wait_periph_resets:
    lw      t2, RESETS_DONE_OFF(t0)
    and     t2, t2, t1
    bne     t2, t1, wait_periph_resets

    /* 5. Initialize peripherals and draw initial 20x15 grid + bouncing box. */
    call    leds_init
    call    piezo_init
    call    uart0_init

    call    fb_draw_grid_and_border
    li      t0, 16
    la      t1, box_x
    sw      t0, 0(t1)
    la      t1, box_y
    sw      t0, 0(t1)
    li      t0, 1
    la      t1, box_dx
    sw      t0, 0(t1)
    la      t1, box_dy
    sw      t0, 0(t1)
    li      a0, 16
    li      a1, 16
    call    fb_xor_box

    call    dvi_hstx_init

    /* 6. Queue startup banner for immediate non-blocking transmission. */
    la      a0, str_boot_banner
    call    uart0_tx_enqueue_str

    /* ------------------------------------------------------------------------
     * 7. Initialize Non-Blocking Cooperative Scheduler State
     *    Dedicated callee-saved registers for the main loop:
     *      s0 = TIMER0_BASE     (0x400B0000)
     *      s1 = next_led_us     (32-bit us deadline)
     *      s2 = led_index       (0=Red, 1=Green, 2=Blue)
     *      s3 = next_piezo_us   (next start deadline)
     *      s4 = piezo_stop_us   (stop deadline while active)
     *      s5 = piezo_active    (0=silent, 1=beeping)
     *      s6 = next_hb_us      (1 s heartbeat deadline)
     *      s7 = heartbeat_count (incrementing seconds counter)
     *      s8 = now_us          (current TIMERAWL snapshot each iteration)
     *      s11 = next_video_us  (16,667 us bouncing box step deadline)
     * ------------------------------------------------------------------------ */
    li      s0, TIMER0_BASE
    lw      s8, TIMER_RAWL_OFF(s0)

    /* Start on Red LED and schedule next step in 1 s. */
    li      s2, 0
    mv      a0, s2
    call    leds_set_active
    li      t0, LED_INTERVAL_US
    add     s1, s8, t0

    /* Trigger initial 100 ms beep on boot/reset, then repeat every 3 s. */
    li      s5, 1
    li      a0, 1
    call    piezo_set_active
    li      t0, PIEZO_DURATION_US
    add     s4, s8, t0
    li      t0, PIEZO_PERIOD_US
    add     s3, s8, t0

    /* Schedule first serial heartbeat in 1 s and first video step in 16.67 ms. */
    li      s7, 0
    li      t0, HEARTBEAT_INTERVAL_US
    add     s6, s8, t0
    li      t0, VIDEO_STEP_INTERVAL_US
    add     s11, s8, t0

/* ----------------------------------------------------------------------------
 * main_loop: Strictly non-blocking cooperative polling loop
 * ---------------------------------------------------------------------------- */
main_loop:
    lw      s8, TIMER_RAWL_OFF(s0)      /* Sample 32-bit 1 MHz hardware timer */

    /* ---- Task 1: Cycle Red -> Green -> Blue LEDs once per second ---- */
    sub     t0, s8, s1                  /* Wrap-safe check: (int32)(now - next) >= 0 */
    bltz    t0, task1_done
    addi    s2, s2, 1
    li      t1, 3
    bltu    s2, t1, led_idx_ok
    li      s2, 0
led_idx_ok:
    mv      a0, s2
    call    leds_set_active
    li      t0, LED_INTERVAL_US
    add     s1, s1, t0
task1_done:

    /* ---- Task 2: Piezo 1 kHz beep for 100 ms every 3 seconds ---- */
    bnez    s5, piezo_check_stop
    sub     t0, s8, s3                  /* Silent: check next_piezo_us */
    bltz    t0, task2_done
    li      a0, 1
    call    piezo_set_active
    li      s5, 1
    li      t0, PIEZO_DURATION_US
    add     s4, s8, t0                  /* piezo_stop_us = now + 100 ms */
    li      t0, PIEZO_PERIOD_US
    add     s3, s3, t0                  /* next_piezo_us += 3 s */
    j       task2_done

piezo_check_stop:
    sub     t0, s8, s4                  /* Active: check piezo_stop_us */
    bltz    t0, task2_done
    li      a0, 0
    call    piezo_set_active
    li      s5, 0
task2_done:

    /* ---- Task 3: Serial heartbeat once per second ---- */
    sub     t0, s8, s6
    bltz    t0, task3_done
    addi    s7, s7, 1
    mv      a0, s7
    call    uart0_enqueue_heartbeat
    li      t0, HEARTBEAT_INTERVAL_US
    add     s6, s6, t0
task3_done:

    /* ---- Task 4: Poll UART0 RX and enqueue dec/hex/bin formatted echo ---- */
    call    uart0_rx_poll

    /* ---- Drain software TX ring buffer into PL011 TX FIFO ---- */
    call    uart0_tx_poll

    /* ---- Task 5: Glide 32x32 XOR box across 20x15 grid (~60 px/s) ---- */
    sub     t0, s8, s11
    bltz    t0, task5_done
    call    video_step_box
    li      t0, VIDEO_STEP_INTERVAL_US
    add     s11, s11, t0
task5_done:

    j       main_loop


/* ============================================================================
 * 4. Hardware Initialization Subroutines
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * clocks_init_126mhz:
 *   1. Enable 12 MHz XOSC and wait for STABLE.
 *   2. Switch clk_ref -> XOSC and clk_sys -> clk_ref (glitchless).
 *   3. Reset/configure PLL_SYS for 126 MHz (VCO=1512 MHz, PD1=6, PD2=2).
 *   4. Switch clk_sys -> PLL_SYS (126 MHz) and enable clk_peri -> clk_sys.
 * ---------------------------------------------------------------------------- */
clocks_init_126mhz:
    /* Enable 12 MHz XOSC */
    li      t0, XOSC_BASE
    li      t1, XOSC_STARTUP_1MS
    sw      t1, XOSC_STARTUP_OFF(t0)
    li      t1, XOSC_CTRL_ENABLE_12M
    sw      t1, XOSC_CTRL_OFF(t0)
1:
    lw      t1, XOSC_STATUS_OFF(t0)
    bgez    t1, 1b                      /* Wait for STABLE (bit 31) */

    /* Switch clk_ref -> XOSC (12 MHz) and clk_sys -> clk_ref safely */
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

    /* Reset and unreset PLL_SYS (bit 14 in RESETS) */
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

    /* Program PLL_SYS: REFDIV=1, FBDIV=126 (VCO=1512 MHz), power up VCO */
    li      t0, PLL_SYS_BASE
    li      t1, PLL_SYS_REFDIV
    sw      t1, PLL_CS_OFF(t0)
    li      t1, PLL_SYS_FBDIV
    sw      t1, PLL_FBDIV_INT_OFF(t0)

    li      t2, PLL_SYS_BASE + ATOMIC_CLR
    li      t1, PLL_PWR_PD_VCO_MASK
    sw      t1, PLL_PWR_OFF(t2)         /* Clear VCOPD & PD */
5:
    lw      t1, PLL_CS_OFF(t0)
    bgez    t1, 5b                      /* Wait for LOCK (bit 31) */

    /* Set post-dividers (6 * 2 = 12 -> 126 MHz) and power up post-divider */
    li      t1, PLL_SYS_PRIM_6_2
    sw      t1, PLL_PRIM_OFF(t0)
    li      t1, PLL_PWR_POSTDIVPD_BIT
    sw      t1, PLL_PWR_OFF(t2)

    /* Switch clk_sys -> clksrc_pll_sys (126 MHz) with divider = 1 */
    li      t0, CLOCKS_BASE
    li      t1, CLK_SYS_DIV_1
    sw      t1, CLK_SYS_DIV_OFF(t0)
    li      t1, CLK_SYS_SRC_AUX_PLL     /* AUXSRC=0 (pll_sys) | SRC=1 (aux) */
    sw      t1, CLK_SYS_CTRL_OFF(t0)
6:
    lw      t1, CLK_SYS_SELECTED_OFF(t0)
    andi    t1, t1, CLK_SYS_SEL_AUX_BIT
    beqz    t1, 6b

    /* Enable clk_peri and clk_hstx sourced from clk_sys (126 MHz) */
    li      t1, CLK_PERI_EN_SYS
    sw      t1, CLK_PERI_CTRL_OFF(t0)
    li      t1, CLK_HSTX_DIV_1
    sw      t1, CLK_HSTX_DIV_OFF(t0)
    li      t1, CLK_HSTX_EN_SYS
    sw      t1, CLK_HSTX_CTRL_OFF(t0)
    ret

/* ----------------------------------------------------------------------------
 * leds_init: Configure GP26 (Red), GP27 (Green), GP28 (Blue) as SIO outputs
 * ---------------------------------------------------------------------------- */
leds_init:
    li      t0, SIO_BASE
    li      t1, LED_ALL_MASK
    sw      t1, SIO_GPIO_OUT_CLR_OFF(t0)    /* Start all LEDs OFF */
    sw      t1, SIO_GPIO_OE_SET_OFF(t0)     /* Enable SIO output drivers */

    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_SIO
    sw      t1, IO_GPIO26_CTRL_OFF(t0)
    sw      t1, IO_GPIO27_CTRL_OFF(t0)
    sw      t1, IO_GPIO28_CTRL_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, PADS_ISO_OD_MASK            /* Clear ISO (bit 8) & OD (bit 7) */
    sw      t1, PADS_GPIO26_OFF(t0)
    sw      t1, PADS_GPIO27_OFF(t0)
    sw      t1, PADS_GPIO28_OFF(t0)
    ret

/* ----------------------------------------------------------------------------
 * leds_set_active(a0 = 0:Red, 1:Green, 2:Blue)
 * ---------------------------------------------------------------------------- */
leds_set_active:
    li      t0, SIO_BASE
    li      t1, LED_ALL_MASK
    sw      t1, SIO_GPIO_OUT_CLR_OFF(t0)    /* Turn all three OFF */
    li      t2, 26
    add     t2, t2, a0                      /* Pin = 26 + index */
    li      t1, 1
    sll     t1, t1, t2
    sw      t1, SIO_GPIO_OUT_SET_OFF(t0)    /* Turn selected LED ON */
    ret

/* ----------------------------------------------------------------------------
 * piezo_init: Configure GP22 (PWM3 A) for 1 kHz square wave (initially silent)
 * ---------------------------------------------------------------------------- */
piezo_init:
    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_PWM
    sw      t1, IO_GPIO22_CTRL_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, PADS_ISO_OD_MASK
    sw      t1, PADS_GPIO22_OFF(t0)

    li      t0, PWM_BASE
    sw      zero, PWM_CH3_CSR_OFF(t0)       /* Disable slice while configuring */
    li      t1, PWM_PIEZO_DIV_126
    sw      t1, PWM_CH3_DIV_OFF(t0)         /* 126 MHz / 126 = 1 MHz tick */
    li      t1, PWM_PIEZO_TOP
    sw      t1, PWM_CH3_TOP_OFF(t0)         /* 1 MHz / 1000 = 1 kHz */
    sw      zero, PWM_CH3_CC_OFF(t0)        /* 0% duty = silent */
    sw      zero, PWM_CH3_CTR_OFF(t0)
    li      t1, 1
    sw      t1, PWM_CH3_CSR_OFF(t0)         /* EN=1, free-running, non-phase-correct */
    ret

/* ----------------------------------------------------------------------------
 * piezo_set_active(a0 = 0:silent, nonzero:1 kHz @ 50% duty)
 * ---------------------------------------------------------------------------- */
piezo_set_active:
    li      t0, PWM_BASE
    beqz    a0, 1f
    li      t1, PWM_PIEZO_CC_ON
    sw      t1, PWM_CH3_CC_OFF(t0)
    ret
1:
    sw      zero, PWM_CH3_CC_OFF(t0)
    ret

/* ----------------------------------------------------------------------------
 * uart0_init: Configure UART0 (GP0 TX, GP1 RX) for 115200 8N1 with FIFOs
 * ---------------------------------------------------------------------------- */
uart0_init:
    li      t0, UART0_BASE
    sw      zero, UART_CR_OFF(t0)           /* Disable UART while configuring */

    li      t1, UART0_IBRD_115200
    sw      t1, UART_IBRD_OFF(t0)           /* IBRD = 68 */
    li      t1, UART0_FBRD_115200
    sw      t1, UART_FBRD_OFF(t0)           /* FBRD = 23 -> 115200.00 bps exact */
    li      t1, UART_LCR_8N1_FIFO
    sw      t1, UART_LCR_H_OFF(t0)          /* 8N1 + 32-byte FIFOs (latches BRD) */
    li      t1, UART_CR_EN_TX_RX
    sw      t1, UART_CR_OFF(t0)             /* UARTEN | TXE | RXE */

    /* Route GP0 -> UART0 TX, GP1 -> UART0 RX (Function 2) */
    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_UART
    sw      t1, IO_GPIO0_CTRL_OFF(t0)
    sw      t1, IO_GPIO1_CTRL_OFF(t0)

    /* Clear pad isolation on GP0 (TX) and GP1 (RX), enable pull-up on GP1 */
    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, PADS_ISO_OD_MASK
    sw      t1, PADS_GPIO0_OFF(t0)
    li      t1, PADS_RX_CLR_MASK            /* Clear ISO & PDE on GP1 */
    sw      t1, PADS_GPIO1_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_SET
    li      t1, PADS_RX_SET_MASK            /* Set IE & PUE on GP1 */
    sw      t1, PADS_GPIO1_OFF(t0)
    ret

/* ============================================================================
 * 4b. Framebuffer Pattern & HSTX / DMA / Hazard3 Xh3irq Video Bring-Up
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * fb_draw_grid_and_border:
 *   Draws 1-pixel outer border (0,0)-(639,479) and word-aligned 20x15 grid
 *   of 32x32-pixel cells into the 38,400-byte SRAM framebuffer.
 * ---------------------------------------------------------------------------- */
fb_draw_grid_and_border:
    la      t0, framebuffer
    li      t1, 0                           /* y = 0..479 */
    li      t2, MODE_V_ACTIVE
    li      t3, (MODE_V_ACTIVE - 1)         /* y = 479 */
    li      t4, 0x80000000                  /* Right border bit (x = 639) */
fb_row_loop:
    andi    t5, t1, 31
    beqz    t5, fb_row_horiz
    beq     t1, t3, fb_row_horiz
    li      t5, 0x00000001                  /* Vertical grid line on bit 0 */
    j       fb_col_start
fb_row_horiz:
    li      t5, -1                          /* 0xFFFFFFFF horizontal line */
fb_col_start:
    li      t6, 0                           /* w = 0..19 */
    li      a0, (FB_WORDS_PER_LINE - 1)
fb_col_loop:
    mv      a1, t5
    bne     t6, a0, fb_col_store
    or      a1, a1, t4                      /* Add rightmost border at w == 19 */
fb_col_store:
    sw      a1, 0(t0)
    addi    t0, t0, 4
    addi    t6, t6, 1
    li      a2, FB_WORDS_PER_LINE
    bltu    t6, a2, fb_col_loop

    addi    t1, t1, 1
    bltu    t1, t2, fb_row_loop
    ret

/* ----------------------------------------------------------------------------
 * fb_xor_box(a0 = x, a1 = y):
 *   XORs a 32x32-pixel solid square at (x, y). Because width == 32 bits, each
 *   row touches at most two adjacent 32-bit words in framebuffer.
 * ---------------------------------------------------------------------------- */
fb_xor_box:
    srli    t0, a0, 5                       /* word_idx = x >> 5 */
    andi    t1, a0, 31                      /* bit_shift = x & 31 */
    li      t2, -1
    sll     t3, t2, t1                      /* mask_lo = 0xFFFFFFFF << bit_shift */
    li      t4, 0                           /* mask_hi = 0 if bit_shift == 0 */
    beqz    t1, 1f
    li      t5, 32
    sub     t5, t5, t1
    srl     t4, t2, t5                      /* mask_hi = 0xFFFFFFFF >> (32 - shift) */
1:
    /* row_ptr = framebuffer + y * 80 + word_idx * 4 */
    li      t5, FB_BYTES_PER_LINE
    mul     t5, a1, t5
    slli    t0, t0, 2
    add     t5, t5, t0
    la      t0, framebuffer
    add     t0, t0, t5

    li      t1, BOX_SIZE_PX                 /* 32 rows */
2:
    lw      t5, 0(t0)
    xor     t5, t5, t3
    sw      t5, 0(t0)
    beqz    t4, 3f
    lw      t5, 4(t0)
    xor     t5, t5, t4
    sw      t5, 4(t0)
3:
    addi    t0, t0, FB_BYTES_PER_LINE
    addi    t1, t1, -1
    bnez    t1, 2b
    ret

/* ----------------------------------------------------------------------------
 * video_step_box: Erase old box, advance/bounce within border, redraw box
 * ---------------------------------------------------------------------------- */
video_step_box:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    la      t0, box_x
    lw      a0, 0(t0)
    la      t1, box_y
    lw      a1, 0(t1)
    call    fb_xor_box                      /* Erase old box */

    /* Bounce X in [BOX_MIN_X, BOX_MAX_X] */
    la      t0, box_x
    lw      t2, 0(t0)
    la      t1, box_dx
    lw      t3, 0(t1)
    blez    t3, 1f
    li      t4, BOX_MAX_X
    blt     t2, t4, 2f
    neg     t3, t3
    j       2f
1:
    li      t4, BOX_MIN_X
    bgt     t2, t4, 2f
    neg     t3, t3
2:
    add     t2, t2, t3
    sw      t2, 0(t0)
    sw      t3, 0(t1)
    mv      a0, t2

    /* Bounce Y in [BOX_MIN_Y, BOX_MAX_Y] */
    la      t0, box_y
    lw      t2, 0(t0)
    la      t1, box_dy
    lw      t3, 0(t1)
    blez    t3, 3f
    li      t4, BOX_MAX_Y
    blt     t2, t4, 4f
    neg     t3, t3
    j       4f
3:
    li      t4, BOX_MIN_Y
    bgt     t2, t4, 4f
    neg     t3, t3
4:
    add     t2, t2, t3
    sw      t2, 0(t0)
    sw      t3, 0(t1)
    mv      a1, t2

    call    fb_xor_box                      /* Draw new box */

    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------------
 * dvi_hstx_init:
 *   Configure HSTX crossbar/TMDS expander, GP12-GP19 pads, BUSCTRL DMA
 *   priority, ping-pong DMA channels 0/1, Hazard3 Xh3irq DMA_IRQ_0, and start!
 * ---------------------------------------------------------------------------- */
dvi_hstx_init:
    li      t0, HSTX_CTRL_BASE
    sw      zero, HSTX_CSR_OFF(t0)          /* Ensure HSTX disabled during setup */

    li      t1, HSTX_EXPAND_TMDS_1BPP
    sw      t1, HSTX_EXPAND_TMDS_OFF(t0)
    li      t1, HSTX_EXPAND_SHIFT_1BPP
    sw      t1, HSTX_EXPAND_SHIFT_OFF(t0)

    /* Crossbar matching Adafruit DVI Sock pinout (GP12..GP19) */
    li      t1, HSTX_LANE0_P
    sw      t1, HSTX_BIT0_OFF(t0)
    li      t1, HSTX_LANE0_N
    sw      t1, HSTX_BIT1_OFF(t0)
    li      t1, HSTX_CLK_P
    sw      t1, HSTX_BIT2_OFF(t0)
    li      t1, HSTX_CLK_N
    sw      t1, HSTX_BIT3_OFF(t0)
    li      t1, HSTX_LANE2_P
    sw      t1, HSTX_BIT4_OFF(t0)
    li      t1, HSTX_LANE2_N
    sw      t1, HSTX_BIT5_OFF(t0)
    li      t1, HSTX_LANE1_P
    sw      t1, HSTX_BIT6_OFF(t0)
    li      t1, HSTX_LANE1_N
    sw      t1, HSTX_BIT7_OFF(t0)

    /* Mux GP12-GP19 to HSTX (FUNCSEL = 0), clear ISO/OD, set fast slew rate */
    li      t1, IO_BANK0_BASE + IO_GPIO12_CTRL_OFF
    li      t2, PADS_BANK0_BASE + ATOMIC_CLR + PADS_GPIO12_OFF
    li      t3, PADS_BANK0_BASE + ATOMIC_SET + PADS_GPIO12_OFF
    li      t4, 8
    li      t5, PADS_ISO_OD_MASK
    li      t6, PADS_SLEWFAST_BIT
1:
    sw      zero, 0(t1)                     /* FUNCSEL = 0 (HSTX) */
    sw      t5, 0(t2)                       /* Clear ISO & OD */
    sw      t6, 0(t3)                       /* Set SLEWFAST = 1 */
    addi    t1, t1, 8
    addi    t2, t2, 4
    addi    t3, t3, 4
    addi    t4, t4, -1
    bnez    t4, 1b

    /* Enable HSTX serializer + command expander */
    li      t1, HSTX_CSR_DVI_ENABLE
    sw      t1, HSTX_CSR_OFF(t0)

    /* Elevate DMA read/write priority on AHB5 crossbar */
    li      t0, BUSCTRL_BASE
    li      t1, BUSCTRL_PRIO_DMA_RW
    sw      t1, BUSCTRL_PRIORITY_OFF(t0)

    /* Initialize DMA scanline state: lines 0 & 1 pre-loaded on PING & PONG */
    la      t0, dma_pong_next
    sw      zero, 0(t0)
    la      t0, v_scanline
    li      t1, 2
    sw      t1, 0(t0)
    la      t0, vactive_cmdlist_posted
    sw      zero, 0(t0)

    /* Configure DMA Channel 0 (PING) and Channel 1 (PONG) */
    li      t0, DMA_BASE
    la      t1, vblank_line_vsync_off
    li      t2, HSTX_FIFO_DATA
    li      t3, 6

    sw      t1, DMA_CH0_READ_OFF(t0)
    sw      t2, DMA_CH0_WRITE_OFF(t0)
    sw      t3, DMA_CH0_COUNT_OFF(t0)
    li      t4, DMA_CTRL_PING
    sw      t4, DMA_CH0_AL1_CTRL_OFF(t0)

    sw      t1, DMA_CH1_READ_OFF(t0)
    sw      t2, DMA_CH1_WRITE_OFF(t0)
    sw      t3, DMA_CH1_COUNT_OFF(t0)
    li      t4, DMA_CTRL_PONG
    sw      t4, DMA_CH1_AL1_CTRL_OFF(t0)

    /* Clear stale IRQ0 flags and enable CH0 + CH1 on DMA_IRQ_0 */
    li      t1, 0x3
    sw      t1, DMA_INTS0_OFF(t0)
    sw      t1, DMA_INTE0_OFF(t0)

    /* Point mtvec to SRAM-resident dma_irq_handler (Direct mode: bit 0 = 0) */
    la      t1, dma_irq_handler
    csrw    mtvec, t1

    /* Enable IRQ 10 (DMA_IRQ_0) in Hazard3 h3.meiea (window 0, bit 26) */
    li      t1, H3_IRQ10_EN_WIN0
    csrs    CSR_MEIEA, t1

    /* Enable M-mode External Interrupts (mie.MEIE) and Global IRQs (mstatus.MIE) */
    li      t1, MIE_MEIE_BIT
    csrs    mie, t1
    csrsi   mstatus, MSTATUS_MIE_BIT

    /* Start Channel 0 (PING) via MULTI_CHAN_TRIGGER! */
    li      t1, 0x1
    sw      t1, DMA_MULTI_TRIG_OFF(t0)
    ret


/* ============================================================================
 * 5. Non-Blocking UART0 TX Ring Buffer, Formatters, and RX Echo
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * uart0_tx_enqueue_byte(a0 = byte): Non-blocking push to 1024-byte TX ring
 * ---------------------------------------------------------------------------- */
uart0_tx_enqueue_byte:
    la      t0, uart_tx_head
    lw      t1, 0(t0)                       /* head */
    addi    t2, t1, 1
    andi    t2, t2, UART_TX_RING_MASK       /* next_head = (head + 1) & 1023 */
    la      t3, uart_tx_tail
    lw      t4, 0(t3)                       /* tail */
    beq     t2, t4, 1f                      /* Full -> drop byte (never block) */
    la      t5, uart_tx_ring
    add     t5, t5, t1
    sb      a0, 0(t5)
    sw      t2, 0(t0)
1:
    ret

/* ----------------------------------------------------------------------------
 * uart0_tx_enqueue_str(a0 = NUL-terminated char*)
 * ---------------------------------------------------------------------------- */
uart0_tx_enqueue_str:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s9, 8(sp)
    mv      s9, a0
1:
    lbu     a0, 0(s9)
    beqz    a0, 2f
    call    uart0_tx_enqueue_byte
    addi    s9, s9, 1
    j       1b
2:
    lw      s9, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------------
 * uart0_tx_enqueue_u32_dec(a0 = uint32_t value)
 *   Uses RV32M divu/remu to extract decimal digits onto the stack, then emits
 *   them MSB-first.
 * ---------------------------------------------------------------------------- */
uart0_tx_enqueue_u32_dec:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s9, 24(sp)
    li      t0, 10
    li      s9, 0                           /* digit count */
1:
    remu    t1, a0, t0                      /* digit = value % 10 */
    divu    a0, a0, t0                      /* value /= 10 */
    addi    t1, t1, '0'
    add     t2, sp, s9
    sb      t1, 0(t2)                       /* digits[count] = '0' + digit */
    addi    s9, s9, 1
    bnez    a0, 1b
2:
    addi    s9, s9, -1
    add     t2, sp, s9
    lbu     a0, 0(t2)
    call    uart0_tx_enqueue_byte
    bnez    s9, 2b

    lw      s9, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret

/* ----------------------------------------------------------------------------
 * uart0_tx_enqueue_u8_hex(a0 = uint8_t value): Emits 2 uppercase hex digits
 * ---------------------------------------------------------------------------- */
uart0_tx_enqueue_u8_hex:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s9, 8(sp)
    mv      s9, a0

    la      t0, hex_digits
    srli    t1, s9, 4
    andi    t1, t1, 0x0F
    add     t1, t0, t1
    lbu     a0, 0(t1)
    call    uart0_tx_enqueue_byte

    la      t0, hex_digits
    andi    t1, s9, 0x0F
    add     t1, t0, t1
    lbu     a0, 0(t1)
    call    uart0_tx_enqueue_byte

    lw      s9, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------------
 * uart0_tx_enqueue_u8_bin(a0 = uint8_t value): Emits 8 binary bits MSB-first
 * ---------------------------------------------------------------------------- */
uart0_tx_enqueue_u8_bin:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s9, 8(sp)
    sw      s10, 4(sp)
    mv      s9, a0
    li      s10, 7
1:
    srl     t0, s9, s10
    andi    t0, t0, 1
    addi    a0, t0, '0'
    call    uart0_tx_enqueue_byte
    addi    s10, s10, -1
    bgez    s10, 1b

    lw      s10, 4(sp)
    lw      s9, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------------
 * uart0_enqueue_heartbeat(a0 = counter / uptime_s)
 * ---------------------------------------------------------------------------- */
uart0_enqueue_heartbeat:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s9, 8(sp)
    mv      s9, a0

    la      a0, str_hb_prefix
    call    uart0_tx_enqueue_str
    mv      a0, s9
    call    uart0_tx_enqueue_u32_dec
    la      a0, str_hb_mid
    call    uart0_tx_enqueue_str
    mv      a0, s9
    call    uart0_tx_enqueue_u32_dec
    la      a0, str_hb_suffix
    call    uart0_tx_enqueue_str

    lw      s9, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------------
 * uart0_rx_poll: Read all pending RX bytes and enqueue dec/hex/bin echo lines
 * ---------------------------------------------------------------------------- */
uart0_rx_poll:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s9, 8(sp)
1:
    li      t0, UART0_BASE
    lw      t1, UART_FR_OFF(t0)
    andi    t1, t1, UART_FR_RXFE_BIT        /* RXFE == 1 means FIFO empty */
    bnez    t1, 2f

    lw      s9, UART_DR_OFF(t0)
    andi    s9, s9, 0xFF                    /* Mask 8-bit character */

    la      a0, str_rx_dec
    call    uart0_tx_enqueue_str
    mv      a0, s9
    call    uart0_tx_enqueue_u32_dec

    la      a0, str_rx_hex
    call    uart0_tx_enqueue_str
    mv      a0, s9
    call    uart0_tx_enqueue_u8_hex

    la      a0, str_rx_bin
    call    uart0_tx_enqueue_str
    mv      a0, s9
    call    uart0_tx_enqueue_u8_bin

    la      a0, str_crlf
    call    uart0_tx_enqueue_str
    j       1b
2:
    lw      s9, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------------
 * uart0_tx_poll: Drain software TX ring into PL011 TX FIFO while not full
 * ---------------------------------------------------------------------------- */
uart0_tx_poll:
    li      t0, UART0_BASE
    la      t1, uart_tx_head
    la      t2, uart_tx_tail
    la      t3, uart_tx_ring
1:
    lw      t4, 0(t2)                       /* tail */
    lw      t5, 0(t1)                       /* head */
    beq     t4, t5, 2f                      /* Ring empty */

    lw      t6, UART_FR_OFF(t0)
    andi    t6, t6, UART_FR_TXFF_BIT        /* TXFF == 1 means FIFO full */
    bnez    t6, 2f

    add     t6, t3, t4
    lbu     t6, 0(t6)
    sw      t6, UART_DR_OFF(t0)             /* Push byte into PL011 TX FIFO */

    addi    t4, t4, 1
    andi    t4, t4, UART_TX_RING_MASK
    sw      t4, 0(t2)
    j       1b
2:
    ret


/* ============================================================================
 * 6. Read-Only Strings (.rodata in Flash)
 * ============================================================================ */
.section .rodata, "a"

hex_digits:
    .ascii  "0123456789ABCDEF"

str_boot_banner:
    .asciz  "\r\n========================================\r\nPico 2 Desert Island - Bare-Metal ASM (2b)\r\n126 MHz | UART0 | DVI 640x480 | LEDs | PWM\r\n========================================\r\n"

str_hb_prefix:
    .asciz  "Heartbeat #"
str_hb_mid:
    .asciz  " (uptime: "
str_hb_suffix:
    .asciz  " s)\r\n"

str_rx_dec:
    .asciz  "Serial character received: dec="
str_rx_hex:
    .asciz  " hex=0x"
str_rx_bin:
    .asciz  " bin=0b"
str_crlf:
    .asciz  "\r\n"


/* ============================================================================
 * 7. SRAM-Resident DMA_IRQ_0 Handler (.ramfunc -> copied to SRAM at boot)
 * ============================================================================
 * Runs at deterministic 0-wait-state SRAM speed so XIP flash cache misses can
 * never delay scanline reprogramming. Saves/restores only t0-t6 (28 bytes).
 */
.section .ramfunc, "ax"
.p2align 2
dma_irq_handler:
    addi    sp, sp, -32
    sw      t0, 0(sp)
    sw      t1, 4(sp)
    sw      t2, 8(sp)
    sw      t3, 12(sp)
    sw      t4, 16(sp)
    sw      t5, 20(sp)
    sw      t6, 24(sp)

    /* Determine which channel finished (0=PING, 1=PONG) and toggle flag */
    la      t0, dma_pong_next
    lw      t1, 0(t0)                       /* ch_num (0 or 1) */
    xori    t2, t1, 1
    sw      t2, 0(t0)

    /* Clear DMA interrupt flag (write-1-clear to DMA.INTR) */
    li      t0, DMA_BASE
    li      t2, 1
    sll     t2, t2, t1
    sw      t2, DMA_INTR_OFF(t0)

    /* Compute channel register base: DMA_BASE + (ch_num << 6) */
    slli    t1, t1, 6
    add     t0, t0, t1                      /* t0 = &dma_hw->ch[ch_num] */

    /* Inspect v_scanline */
    la      t1, v_scanline
    lw      t2, 0(t1)                       /* t2 = v_scanline */

    /* If v_scanline in [10, 12): VSYNC active line */
    li      t3, MODE_V_FRONT_PORCH
    bltu    t2, t3, isr_vblank_off
    li      t3, MODE_V_SYNC_END
    bltu    t2, t3, isr_vblank_on

    /* If v_scanline < 45: VSYNC inactive blanking line */
    li      t3, MODE_V_BLANK_END
    bltu    t2, t3, isr_vblank_off

    /* Active line (45..524): alternate prefix (7 words) and pixels (20 words) */
    la      t3, vactive_cmdlist_posted
    lw      t4, 0(t3)
    bnez    t4, isr_vactive_pixels

    /* Post active-line blanking prefix + TMDS|640 command */
    la      t5, vactive_line_prefix
    li      t6, 7
    sw      t5, DMA_CH0_READ_OFF(t0)
    sw      t6, DMA_CH0_COUNT_OFF(t0)
    li      t4, 1
    sw      t4, 0(t3)
    j       isr_done

isr_vactive_pixels:
    /* Post 20 words of 1 bpp pixels from framebuffer[v_scanline - 45] */
    addi    t5, t2, -MODE_V_BLANK_END       /* active_y */
    li      t6, FB_BYTES_PER_LINE
    mul     t5, t5, t6
    la      t6, framebuffer
    add     t5, t5, t6
    li      t6, FB_WORDS_PER_LINE
    sw      t5, DMA_CH0_READ_OFF(t0)
    sw      t6, DMA_CH0_COUNT_OFF(t0)
    sw      zero, 0(t3)                     /* vactive_cmdlist_posted = 0 */

    addi    t2, t2, 1
    li      t3, MODE_V_TOTAL
    bltu    t2, t3, isr_store_line
    li      t2, 0
    j       isr_store_line

isr_vblank_on:
    la      t5, vblank_line_vsync_on
    li      t6, 6
    sw      t5, DMA_CH0_READ_OFF(t0)
    sw      t6, DMA_CH0_COUNT_OFF(t0)
    addi    t2, t2, 1
    j       isr_store_line

isr_vblank_off:
    la      t5, vblank_line_vsync_off
    li      t6, 6
    sw      t5, DMA_CH0_READ_OFF(t0)
    sw      t6, DMA_CH0_COUNT_OFF(t0)
    addi    t2, t2, 1

isr_store_line:
    sw      t2, 0(t1)

isr_done:
    lw      t6, 24(sp)
    lw      t5, 20(sp)
    lw      t4, 16(sp)
    lw      t3, 12(sp)
    lw      t2, 8(sp)
    lw      t1, 4(sp)
    lw      t0, 0(sp)
    addi    sp, sp, 32
    mret


/* ============================================================================
 * 8. Initialized SRAM Data (.data -> copied to SRAM at boot)
 * ============================================================================
 * Placing the HSTX command lists in SRAM keeps all DMA reads 0-wait-state.
 * TMDS control symbols (DVI 1.0 Table 3-5):
 *   00 = 0x354, 01 = 0x0AB, 10 = 0x154, 11 = 0x2AB
 */
.section .data, "aw"
.p2align 2
vblank_line_vsync_off:
    .word   (0x1000 | 16)                   /* RAW_REPEAT 16 (HFP) */
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB) /* SYNC_V1_H1 */
    .word   (0x1000 | 96)                   /* RAW_REPEAT 96 (HSYNC) */
    .word   ((0x354 << 20) | (0x354 << 10) | 0x154) /* SYNC_V1_H0 */
    .word   (0x1000 | (48 + 640))           /* RAW_REPEAT 688 (HBP + blank) */
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB) /* SYNC_V1_H1 */

vblank_line_vsync_on:
    .word   (0x1000 | 16)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x0AB) /* SYNC_V0_H1 */
    .word   (0x1000 | 96)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x354) /* SYNC_V0_H0 */
    .word   (0x1000 | (48 + 640))
    .word   ((0x354 << 20) | (0x354 << 10) | 0x0AB) /* SYNC_V0_H1 */

vactive_line_prefix:
    .word   (0x1000 | 16)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB) /* SYNC_V1_H1 */
    .word   (0x1000 | 96)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x154) /* SYNC_V1_H0 */
    .word   (0x1000 | 48)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB) /* SYNC_V1_H1 */
    .word   (0x2000 | 640)                  /* TMDS 640 active pixels */


/* ============================================================================
 * 9. Zero-Initialized SRAM State (.bss in RAM)
 * ============================================================================ */
.section .bss, "aw", @nobits
.p2align 2
uart_tx_head:
    .word   0
uart_tx_tail:
    .word   0
dma_pong_next:
    .word   0
v_scanline:
    .word   0
vactive_cmdlist_posted:
    .word   0
box_x:
    .word   0
box_y:
    .word   0
box_dx:
    .word   0
box_dy:
    .word   0
uart_tx_ring:
    .space  UART_TX_RING_SIZE
.p2align 2
framebuffer:
    .space  FB_TOTAL_BYTES                  /* 38,400 bytes (640x480 1 bpp) */
