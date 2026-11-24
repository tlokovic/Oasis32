/*
 * ============================================================================
 * Pico 2 Desert Island — Bare-Metal RISC-V Blink (Sub-Phase 1a ASM Check)
 * ============================================================================
 * Pure RP2350 Hazard3 RISC-V assembly equivalent of test_harness/cpp:
 * toggles the onboard green LED (GPIO25) every 50 ms with zero third-party
 * libraries, runtime startup files, or Pico SDK code.
 *
 * Hardware Bring-Up Sequence:
 *   1. Initialize stack pointer (sp = __stack_top = 0x20082000).
 *   2. Enable the 12 MHz external crystal oscillator (XOSC) and wait for lock.
 *   3. Switch clk_ref and clk_sys glitchlessly from ROSC to 12 MHz XOSC.
 *   4. Configure the TIMER0 tick generator for a 1 MHz (1 us) timebase.
 *   5. Release IO_BANK0, PADS_BANK0, and TIMER0 from subsystem reset.
 *   6. Configure GPIO25 for SIO output and clear its RP2350 pad isolation latch.
 *   7. Toggle GPIO25 every 50,000 us (50 ms) using TIMER0.TIMERAWL.
 *
 * Primary Documentation:
 *   - rp2350-datasheet.pdf (RP2350 Silicon Reference)
 *   - pico-2-datasheet.pdf (Raspberry Pi Pico 2 Board Reference)
 * ============================================================================
 */

/* ----------------------------------------------------------------------------
 * Peripheral Base Addresses & Atomic Register Alias Offsets
 * ----------------------------------------------------------------------------
 * RP2350 APB/AHB peripherals support atomic bitwise alias windows
 * (rp2350-datasheet.pdf §2.1.3, p. 24):
 *   +0x0000 : Normal R/W
 *   +0x1000 : Atomic XOR
 *   +0x2000 : Atomic SET
 *   +0x3000 : Atomic CLEAR
 * Note: SIO (0xd0000000) does NOT support these bus aliases; it provides
 * dedicated *_SET / *_CLR / *_XOR registers directly in its register map.
 */
.equ ATOMIC_CLR,            0x3000

.equ CLOCKS_BASE,           0x40010000  /* rp2350-datasheet.pdf §8.1.7, p. 481 */
.equ RESETS_BASE,           0x40020000  /* rp2350-datasheet.pdf §7.5.3, p. 459 */
.equ IO_BANK0_BASE,         0x40028000  /* rp2350-datasheet.pdf §9.11.1, p. 549 */
.equ PADS_BANK0_BASE,       0x40038000  /* rp2350-datasheet.pdf §9.11.3, p. 694 */
.equ XOSC_BASE,             0x40048000  /* rp2350-datasheet.pdf §8.2.8, p. 509 */
.equ TIMER0_BASE,           0x400B0000  /* rp2350-datasheet.pdf §12.8.5, p. 1099 */
.equ TICKS_BASE,            0x40108000  /* rp2350-datasheet.pdf §8.5.2, p. 522 */
.equ SIO_BASE,              0xD0000000  /* rp2350-datasheet.pdf §3.1.11, p. 49 */

/* ----------------------------------------------------------------------------
 * XOSC Registers (rp2350-datasheet.pdf §8.2.4 & §8.2.8, Tables 630–634, pp. 509–512)
 * ----------------------------------------------------------------------------
 * Startup delay derivation for 12 MHz crystal and 1 ms stabilization:
 *   STARTUP_DELAY = ceil((12,000,000 Hz * 0.001 s) / 256) = ceil(46.875) = 47
 * CTRL encoding:
 *   bits [23:12] ENABLE     = 0xFAB (4011 = ENABLE magic key)
 *   bits [11:0]  FREQ_RANGE = 0xAA0 (2720 = 1_15MHZ range code)
 *   combined                = 0x00FABAA0
 */
.equ XOSC_CTRL_OFF,         0x000
.equ XOSC_STATUS_OFF,       0x004
.equ XOSC_STARTUP_OFF,      0x00C
.equ XOSC_STARTUP_1MS,      47
.equ XOSC_CTRL_ENABLE_12M,  0x00FABAA0

/* ----------------------------------------------------------------------------
 * CLOCKS Registers (rp2350-datasheet.pdf §8.1.7, Tables 588–593, pp. 488–491)
 * ----------------------------------------------------------------------------
 * CLK_REF_CTRL.SRC:      2 = xosc_clksrc  -> CLK_REF_SELECTED bit 2 (0x4)
 * CLK_SYS_CTRL.SRC:      0 = clk_ref      -> CLK_SYS_SELECTED bit 0 (0x1)
 */
.equ CLK_REF_CTRL_OFF,      0x030
.equ CLK_REF_SELECTED_OFF,  0x038
.equ CLK_SYS_CTRL_OFF,      0x03C
.equ CLK_SYS_SELECTED_OFF,  0x044
.equ CLK_REF_SRC_XOSC,      2
.equ CLK_REF_SEL_XOSC_BIT,  (1 << 2)
.equ CLK_SYS_SRC_REF,       0
.equ CLK_SYS_SEL_REF_BIT,   (1 << 0)

/* ----------------------------------------------------------------------------
 * TICKS Registers (rp2350-datasheet.pdf §8.5.2, Tables 649–652, pp. 522–524)
 * ----------------------------------------------------------------------------
 * Tick generators divide clk_ref (now 12 MHz XOSC) to produce 1 us ticks:
 *   TIMER0_CYCLES = 12 MHz / 1 MHz = 12
 */
.equ TICKS_TIMER0_CTRL_OFF,   0x018
.equ TICKS_TIMER0_CYCLES_OFF, 0x01C
.equ TICKS_CYCLES_1US,        12
.equ TICKS_CTRL_ENABLE,       1

/* ----------------------------------------------------------------------------
 * RESETS Registers (rp2350-datasheet.pdf §7.5.3, Tables 566–569, pp. 459–462)
 * ----------------------------------------------------------------------------
 * Subsystem reset bits to release:
 *   Bit 6  : IO_BANK0   (0x00000040)
 *   Bit 9  : PADS_BANK0 (0x00000200)
 *   Bit 23 : TIMER0     (0x00800000)
 *   Mask   : 0x00800240
 */
.equ RESETS_RESET_OFF,      0x000
.equ RESETS_DONE_OFF,       0x008
.equ RESETS_MASK,           ((1 << 6) | (1 << 9) | (1 << 23))

/* ----------------------------------------------------------------------------
 * GPIO25 (Pico 2 Onboard LED, active HIGH — pico-2-datasheet.pdf §3.2, p. 10)
 * ----------------------------------------------------------------------------
 * IO_BANK0:   GPIO25_CTRL offset = 25 * 8 + 4 = 0x0CC (Table 733, p. 585)
 *             FUNCSEL = 5 (sio_25, Table 677, p. 542)
 * PADS_BANK0: GPIO25 offset      = 0x004 + 25 * 4 = 0x068 (Table 910, p. 719)
 *             Bit 8 = ISO (pad isolation latch, resets to 1 on RP2350!)
 *             Bit 7 = OD  (output disable, resets to 0)
 * SIO:        RP2350 interleaves GPIO0..31 and GPIO_HI (32..47) registers
 *             (rp2350-datasheet.pdf §3.1.11, Table 17, pp. 49–51):
 *               0x020 = GPIO_OUT_CLR
 *               0x028 = GPIO_OUT_XOR
 *               0x038 = GPIO_OE_SET
 */
.equ LED_PIN,               25
.equ LED_MASK,              (1 << LED_PIN)
.equ IO_GPIO25_CTRL_OFF,    0x0CC
.equ IO_FUNCSEL_SIO,        5
.equ PADS_GPIO25_OFF,       0x068
.equ PADS_ISO_OD_MASK,      ((1 << 8) | (1 << 7))
.equ SIO_GPIO_OUT_CLR_OFF,  0x020
.equ SIO_GPIO_OUT_XOR_OFF,  0x028
.equ SIO_GPIO_OE_SET_OFF,   0x038

/* ----------------------------------------------------------------------------
 * TIMER0 Register & Blink Timing (rp2350-datasheet.pdf §12.8.5, Table 1349, p. 1102)
 * ----------------------------------------------------------------------------
 * TIMERAWL (offset 0x028) provides a side-effect-free read of bits [31:0] of
 * the 64-bit microsecond counter.
 * Matches test_harness/cpp/test_harness_cpp.c: LED_DELAY_MS = 50 (50,000 us).
 */
.equ TIMER_RAWL_OFF,        0x028
.equ BLINK_DELAY_US,        50000


/* ============================================================================
 * Boot Entry Point (.text.boot -> placed at 0x10000000 by memmap.ld)
 * ============================================================================
 */
.section .text.boot, "ax"
.global _start
.type _start, @function
_start:
    /* 1. Initialize stack pointer to top of SRAM (0x20082000). */
    la      sp, __stack_top

    /* ------------------------------------------------------------------------
     * 2. Enable 12 MHz Crystal Oscillator (XOSC) and wait for stabilization.
     * ------------------------------------------------------------------------
     */
    li      t0, XOSC_BASE
    li      t1, XOSC_STARTUP_1MS
    sw      t1, XOSC_STARTUP_OFF(t0)        /* 1 ms startup delay (47 * 256 cycles) */
    li      t1, XOSC_CTRL_ENABLE_12M
    sw      t1, XOSC_CTRL_OFF(t0)           /* Enable XOSC in 1–15 MHz range */

wait_xosc_stable:
    lw      t1, XOSC_STATUS_OFF(t0)
    bgez    t1, wait_xosc_stable            /* Bit 31 (STABLE) is sign bit: loop while 0 */

    /* ------------------------------------------------------------------------
     * 3. Switch clk_ref and clk_sys glitchlessly to 12 MHz XOSC.
     * ------------------------------------------------------------------------
     */
    li      t0, CLOCKS_BASE
    li      t1, CLK_REF_SRC_XOSC
    sw      t1, CLK_REF_CTRL_OFF(t0)        /* Request clk_ref = xosc_clksrc */

wait_clk_ref:
    lw      t1, CLK_REF_SELECTED_OFF(t0)
    andi    t1, t1, CLK_REF_SEL_XOSC_BIT
    beqz    t1, wait_clk_ref                /* Wait for glitchless mux switch */

    li      t1, CLK_SYS_SRC_REF
    sw      t1, CLK_SYS_CTRL_OFF(t0)        /* Request clk_sys = clk_ref (12 MHz) */

wait_clk_sys:
    lw      t1, CLK_SYS_SELECTED_OFF(t0)
    andi    t1, t1, CLK_SYS_SEL_REF_BIT
    beqz    t1, wait_clk_sys                /* Wait for glitchless mux switch */

    /* ------------------------------------------------------------------------
     * 4. Start the 1 MHz (1 us) tick generator for TIMER0.
     * ------------------------------------------------------------------------
     */
    li      t0, TICKS_BASE
    li      t1, TICKS_CYCLES_1US
    sw      t1, TICKS_TIMER0_CYCLES_OFF(t0) /* Divide 12 MHz clk_ref by 12 -> 1 MHz */
    li      t1, TICKS_CTRL_ENABLE
    sw      t1, TICKS_TIMER0_CTRL_OFF(t0)   /* Enable TIMER0 tick generator */

    /* ------------------------------------------------------------------------
     * 5. Deassert subsystem resets for IO_BANK0, PADS_BANK0, and TIMER0.
     * ------------------------------------------------------------------------
     */
    li      t0, RESETS_BASE + ATOMIC_CLR
    li      t1, RESETS_MASK
    sw      t1, RESETS_RESET_OFF(t0)        /* Atomic CLEAR of reset bits 6, 9, 23 */

    li      t0, RESETS_BASE
wait_resets_done:
    lw      t2, RESETS_DONE_OFF(t0)
    and     t2, t2, t1
    bne     t2, t1, wait_resets_done        /* Poll until all three blocks are ready */

    /* ------------------------------------------------------------------------
     * 6. Configure GPIO25 (onboard LED) for SIO output.
     *    Order follows rp2350-datasheet.pdf §9.7 (p. 545) & §9.10.1 (p. 548):
     *      a) Pre-configure SIO output low and enable output driver.
     *      b) Mux GPIO25 to SIO (FUNCSEL = 5) in IO_BANK0.
     *      c) Clear pad isolation latch (ISO) and output disable (OD) in
     *         PADS_BANK0 so the SIO signal propagates to the physical pin.
     * ------------------------------------------------------------------------
     */
    li      s0, SIO_BASE
    li      s1, LED_MASK
    sw      s1, SIO_GPIO_OUT_CLR_OFF(s0)    /* Start LED OFF (logic low) */
    sw      s1, SIO_GPIO_OE_SET_OFF(s0)     /* Enable SIO output driver on GPIO25 */

    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_SIO
    sw      t1, IO_GPIO25_CTRL_OFF(t0)      /* FUNCSEL = 5 (SIO), overrides = NORMAL */

    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, PADS_ISO_OD_MASK
    sw      t1, PADS_GPIO25_OFF(t0)         /* Clear ISO (bit 8) & OD (bit 7); keep 4 mA */

    /* ------------------------------------------------------------------------
     * 7. Main Blink Loop (50 ms ON / 50 ms OFF via TIMER0.TIMERAWL).
     *    Callee-saved registers held across the loop:
     *      s0 = SIO_BASE      (0xD0000000)
     *      s1 = LED_MASK      (1 << 25)
     *      s2 = TIMER0_BASE   (0x400B0000)
     *      s3 = BLINK_DELAY_US (50000 us = 50 ms)
     * ------------------------------------------------------------------------
     */
    li      s2, TIMER0_BASE
    li      s3, BLINK_DELAY_US

blink_loop:
    sw      s1, SIO_GPIO_OUT_XOR_OFF(s0)    /* Atomically toggle GPIO25 */
    lw      t0, TIMER_RAWL_OFF(s2)          /* Capture start timestamp (us) */

delay_loop:
    lw      t1, TIMER_RAWL_OFF(s2)          /* Read current timestamp (us) */
    sub     t1, t1, t0                      /* Unsigned elapsed = now - start (wrap-safe) */
    bltu    t1, s3, delay_loop              /* Wait until elapsed >= 50,000 us */

    j       blink_loop

.size _start, . - _start


/* ============================================================================
 * RP2350 Boot ROM Metadata Block (Minimum Viable RISC-V IMAGE_DEF)
 * ============================================================================
 * Placed immediately after .text.boot by memmap.ld so it resides well inside
 * the Boot ROM's 4 kB scan window (0x10000000 - 0x10000FFF).
 *
 * Exact 20-byte structure from rp2350-datasheet.pdf §5.9.5.2, Table 504, p. 390:
 *   Word 0: 0xffffded3  PICOBIN_BLOCK_MARKER_START
 *   Word 1: 0x11010142  IMAGE_TYPE item:
 *                         [7:0]   = 0x42 (PICOBIN_BLOCK_ITEM_1BS_IMAGE_TYPE)
 *                         [15:8]  = 0x01 (size = 1 word)
 *                         [31:16] = 0x1101 (EXE | RISCV | RP2350)
 *   Word 2: 0x000001ff  LAST item:
 *                         [7:0]   = 0xff (PICOBIN_BLOCK_ITEM_2BS_LAST)
 *                         [23:8]  = 0x0001 (total preceding items = 1 word)
 *                         [31:24] = 0x00 (pad)
 *   Word 3: 0x00000000  Relative offset to next block (0 = single-block self-loop)
 *   Word 4: 0xab123579  PICOBIN_BLOCK_MARKER_END
 *
 * Because no ENTRY_POINT item is included, the Boot ROM enters the binary at
 * its lowest address (0x10000000 -> _start), which is the default on RISC-V.
 */
.section .picobin_block, "a"
.p2align 2
picobin_image_def:
    .word   0xffffded3
    .word   0x11010142
    .word   0x000001ff
    .word   0x00000000
    .word   0xab123579
