/**
 * Pico 2 Desert Island Computer - Phase 1 Hardware Test Harness (Sub-Phase 1e)
 *
 * Non-blocking cooperative polling loop verifying:
 *   - Status LEDs: Red (GP26) -> Green (GP27) -> Blue (GP28), advancing every 1 s
 *   - Piezo Buzzer: GP22 (PWM3 A), 1 kHz tone for 100 ms every 3 s
 *   - Hardware Reset: RUN pin (Pin 30) cleanly restarts sequence
 *   - Debug Serial (CP2102N): UART0 (GP0 TX, GP1 RX) at 115200 8N1
 *       * Boot banner on startup
 *       * 1-second incrementing heartbeat message
 *       * Non-blocking RX polling with dec/hex/bin formatted echo
 *   - HDMI Display (Adafruit DVI Sock): HSTX on GP12-GP19, 640x480 @ 60 Hz
 *       * 1 bpp monochrome framebuffer in SRAM (38,400 bytes)
 *       * Ping-pong DMA paced by DREQ_HSTX with hardware TMDS encoding
 *       * Static 1 px border + 20x15 (32x32 px) grid + bouncing 32x32 XOR box
 *   - Keyboard/Mouse Host (CH9350): UART1 (GP20 TX, GP21 RX) at 115200 8N1
 *       * Non-blocking 0x57 0xAB frame parser (State 2 keyboard, relative mouse,
 *         status/version/disconnect frames) logged to UART0
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/pwm.h"
#include "hardware/structs/bus_ctrl.h"
#include "hardware/structs/hstx_ctrl.h"
#include "hardware/structs/hstx_fifo.h"
#include "hardware/uart.h"
#include "pico/stdlib.h"

// Hardware pin assignments (see README.md)
#define PIN_UART0_TX     0u   // UART0 TX (rp2350-datasheet.pdf §9.4, Table 677)
#define PIN_UART0_RX     1u   // UART0 RX (rp2350-datasheet.pdf §9.4, Table 677)
#define PIN_DVI_FIRST   12u   // GP12-GP19: HSTX (Function 0, Table 677)
#define PIN_DVI_COUNT    8u
#define PIN_UART1_TX    20u   // UART1 TX -> CH9350 RX (rp2350-datasheet.pdf §9.4, Table 677)
#define PIN_UART1_RX    21u   // UART1 RX <- CH9350 TX (rp2350-datasheet.pdf §9.4, Table 677)
#define PIN_PIEZO       22u   // PWM3 A   (rp2350-datasheet.pdf §12.5.2, Table 1183)
#define PIN_LED_RED     26u
#define PIN_LED_GREEN   27u
#define PIN_LED_BLUE    28u

// System / HSTX clocking:
//   640x480 @ 60 Hz pixel clock = 800 * 525 * 60 = 25.2 MHz
//   TMDS serial bit rate = 10 * 25.2 MHz = 252 Mbps per lane
//   HSTX DDR clock = 252 / 2 = 126 MHz (2 bits per HSTX clock cycle)
//   Running clk_sys = 126 MHz lets clk_hstx derive directly from clk_sys (1:1).
#define SYS_CLOCK_KHZ           126000u
#define SYS_CLOCK_HZ            (SYS_CLOCK_KHZ * 1000u)

// Debug UART0 configuration (PL011, rp2350-datasheet.pdf §12.1)
#define UART_DEBUG              uart0
#define UART_DEBUG_BAUD         115200u
#define UART_TX_RING_SIZE       1024u  // Power of 2 for cheap bitmask wrap
#define UART_TX_RING_MASK       (UART_TX_RING_SIZE - 1u)

// CH9350 HID Bridge UART1 configuration (CH9350DS.PDF §7.2.1, p. 8)
#define UART_HID                uart1
#define UART_HID_BAUD           115200u
#define CH9350_SYNC1            0x57u
#define CH9350_SYNC2            0xABu
#define CH9350_MAX_PAYLOAD      8u

// Scheduling intervals (microseconds, driven by 64-bit 1 MHz system timer)
#define LED_STEP_INTERVAL_US     1000000ull  // 1 s
#define HEARTBEAT_INTERVAL_US    1000000ull  // 1 s
#define PIEZO_PERIOD_US          3000000ull  // 3 s
#define PIEZO_DURATION_US         100000ull  // 100 ms
#define VIDEO_STEP_INTERVAL_US     16667ull  // ~60 px/s (1 px per 60 Hz frame)

// Video test pattern geometry: 1 px outer border + 20x15 (32x32 px) grid + 32x32 XOR box
#define BOX_SIZE_PX                   32u
#define BOX_MIN_X                      1u
#define BOX_MAX_X                (MODE_H_ACTIVE_PIXELS - 1u - BOX_SIZE_PX)  // 607
#define BOX_MIN_Y                      1u
#define BOX_MAX_Y                (MODE_V_ACTIVE_LINES  - 1u - BOX_SIZE_PX)  // 447

// PWM configuration for 1 kHz piezo tone:
//   f_pwm = f_sys / ((TOP + 1) * DIV)
//   By setting DIV = f_sys / 1,000,000 (1 MHz counter tick):
//     TOP = 999  -> period = 1000 ticks -> f_pwm = 1,000,000 / 1000 = 1000 Hz
//     CC  = 500  -> 50% duty cycle (active)
//     CC  = 0    -> 0% duty cycle (glitch-free low / silent)
#define PIEZO_PWM_TICK_HZ      1000000u
#define PIEZO_FREQ_HZ             1000u
#define PIEZO_PWM_WRAP         ((PIEZO_PWM_TICK_HZ / PIEZO_FREQ_HZ) - 1u)
#define PIEZO_PWM_LEVEL_ON     ((PIEZO_PWM_WRAP + 1u) / 2u)
#define PIEZO_PWM_LEVEL_OFF          0u

// 640x480 @ 60 Hz DVI/VGA timing (active-low HSYNC and VSYNC)
#define MODE_H_FRONT_PORCH       16u
#define MODE_H_SYNC_WIDTH        96u
#define MODE_H_BACK_PORCH        48u
#define MODE_H_ACTIVE_PIXELS    640u

#define MODE_V_FRONT_PORCH       10u
#define MODE_V_SYNC_WIDTH         2u
#define MODE_V_BACK_PORCH        33u
#define MODE_V_ACTIVE_LINES     480u
#define MODE_V_TOTAL_LINES      (MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH + \
                                 MODE_V_BACK_PORCH + MODE_V_ACTIVE_LINES)

#define FB_WORDS_PER_LINE       (MODE_H_ACTIVE_PIXELS / 32u)  // 20 words = 80 bytes

// HSTX Command Expander opcodes (rp2350-datasheet.pdf §12.11.5, p. 1119)
#define HSTX_CMD_RAW            (0x0u << 12u)
#define HSTX_CMD_RAW_REPEAT     (0x1u << 12u)
#define HSTX_CMD_TMDS           (0x2u << 12u)
#define HSTX_CMD_TMDS_REPEAT    (0x3u << 12u)
#define HSTX_CMD_NOP            (0xfu << 12u)

// 10-bit TMDS control symbols (DVI 1.0 Table 3-5): C1 = VSYNC, C0 = HSYNC on Lane 0
#define TMDS_CTRL_00            0x354u
#define TMDS_CTRL_01            0x0ABu
#define TMDS_CTRL_10            0x154u
#define TMDS_CTRL_11            0x2ABu

#define SYNC_V0_H0  ((TMDS_CTRL_00 << 20u) | (TMDS_CTRL_00 << 10u) | TMDS_CTRL_00)
#define SYNC_V0_H1  ((TMDS_CTRL_00 << 20u) | (TMDS_CTRL_00 << 10u) | TMDS_CTRL_01)
#define SYNC_V1_H0  ((TMDS_CTRL_00 << 20u) | (TMDS_CTRL_00 << 10u) | TMDS_CTRL_10)
#define SYNC_V1_H1  ((TMDS_CTRL_00 << 20u) | (TMDS_CTRL_00 << 10u) | TMDS_CTRL_11)

// Ping-pong DMA channels for continuous HSTX scanline streaming
#define DMACH_PING              0u
#define DMACH_PONG              1u

static const uint LED_PINS[3] = {
    PIN_LED_RED,
    PIN_LED_GREEN,
    PIN_LED_BLUE,
};

// 640x480 1 bpp monochrome framebuffer in SRAM (480 * 20 * 4 = 38,400 bytes)
// Bit (x & 31) of framebuffer[y][x >> 5] controls pixel (x, y).
static uint32_t framebuffer[MODE_V_ACTIVE_LINES][FB_WORDS_PER_LINE];

// Pre-built HSTX command lists for blanking lines and active-line sync prefix
static const uint32_t vblank_line_vsync_off[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_V1_H1,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_V1_H0,
    HSTX_CMD_RAW_REPEAT | (MODE_H_BACK_PORCH + MODE_H_ACTIVE_PIXELS),
    SYNC_V1_H1,
};

static const uint32_t vblank_line_vsync_on[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_V0_H1,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_V0_H0,
    HSTX_CMD_RAW_REPEAT | (MODE_H_BACK_PORCH + MODE_H_ACTIVE_PIXELS),
    SYNC_V0_H1,
};

static const uint32_t vactive_line_prefix[] = {
    HSTX_CMD_RAW_REPEAT | MODE_H_FRONT_PORCH,
    SYNC_V1_H1,
    HSTX_CMD_RAW_REPEAT | MODE_H_SYNC_WIDTH,
    SYNC_V1_H0,
    HSTX_CMD_RAW_REPEAT | MODE_H_BACK_PORCH,
    SYNC_V1_H1,
    HSTX_CMD_TMDS | MODE_H_ACTIVE_PIXELS,
};

// DMA scanline state (updated exclusively inside dma_irq_handler in SRAM)
static bool dma_pong_next = false;
static uint32_t v_scanline = 2u;   // Lines 0 and 1 are pre-loaded on startup
static bool vactive_cmdlist_posted = false;

static uint piezo_slice;
static uint piezo_channel;

// Software TX ring buffer for strictly non-blocking UART0 output.
// The PL011 hardware TX FIFO holds 32 bytes (rp2350-datasheet.pdf §12.1.2.4);
// buffering formatted lines here prevents busy-waiting when a line > 32 bytes.
static uint8_t uart_tx_ring[UART_TX_RING_SIZE];
static uint32_t uart_tx_head = 0u;
static uint32_t uart_tx_tail = 0u;

static void __not_in_flash_func(dma_irq_handler)(void) {
    // Reprogram the channel that just finished while the other channel streams
    uint ch_num = dma_pong_next ? DMACH_PONG : DMACH_PING;
    dma_channel_hw_t *ch = &dma_hw->ch[ch_num];
    dma_hw->intr = 1u << ch_num;
    dma_pong_next = !dma_pong_next;

    if (v_scanline >= MODE_V_FRONT_PORCH &&
        v_scanline < (MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH)) {
        ch->read_addr = (uintptr_t)vblank_line_vsync_on;
        ch->transfer_count = count_of(vblank_line_vsync_on);
        v_scanline++;
    } else if (v_scanline < (MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH + MODE_V_BACK_PORCH)) {
        ch->read_addr = (uintptr_t)vblank_line_vsync_off;
        ch->transfer_count = count_of(vblank_line_vsync_off);
        v_scanline++;
    } else if (!vactive_cmdlist_posted) {
        ch->read_addr = (uintptr_t)vactive_line_prefix;
        ch->transfer_count = count_of(vactive_line_prefix);
        vactive_cmdlist_posted = true;
    } else {
        uint32_t active_y = v_scanline -
            (MODE_V_FRONT_PORCH + MODE_V_SYNC_WIDTH + MODE_V_BACK_PORCH);
        ch->read_addr = (uintptr_t)framebuffer[active_y];
        ch->transfer_count = FB_WORDS_PER_LINE;
        vactive_cmdlist_posted = false;
        if (++v_scanline >= MODE_V_TOTAL_LINES) {
            v_scanline = 0u;
        }
    }
}

static void fb_draw_grid_and_border(void) {
    // Draw a 1-pixel outer border (0,0)-(639,479) and a word-aligned 20x15 grid
    // of 32x32-pixel cells. Each column aligns to bit 0 of a 32-bit word.
    for (uint32_t y = 0u; y < MODE_V_ACTIVE_LINES; ++y) {
        bool horiz_line = ((y & 31u) == 0u) || (y == (MODE_V_ACTIVE_LINES - 1u));
        for (uint32_t w = 0u; w < FB_WORDS_PER_LINE; ++w) {
            uint32_t word = horiz_line ? 0xFFFFFFFFu : 0x00000001u;
            if (w == (FB_WORDS_PER_LINE - 1u)) {
                word |= 0x80000000u;  // Rightmost 1 px border at x = 639
            }
            framebuffer[y][w] = word;
        }
    }
}

static void fb_xor_box(uint32_t x, uint32_t y) {
    // XOR a 32x32 solid square at (x, y). Because width == 32 bits, each row
    // touches at most two adjacent 32-bit framebuffer words.
    uint32_t word_idx = x >> 5u;
    uint32_t bit_shift = x & 31u;
    uint32_t mask_lo = 0xFFFFFFFFu << bit_shift;
    uint32_t mask_hi = (bit_shift != 0u) ? (0xFFFFFFFFu >> (32u - bit_shift)) : 0u;

    for (uint32_t row = y; row < (y + BOX_SIZE_PX); ++row) {
        framebuffer[row][word_idx] ^= mask_lo;
        if (mask_hi != 0u) {
            framebuffer[row][word_idx + 1u] ^= mask_hi;
        }
    }
}

static void dvi_hstx_init(void) {
    // Source clk_hstx directly from clk_sys (126 MHz -> 252 Mbps DDR = 25.2 MHz pixel clock)
    clock_configure(
        clk_hstx,
        0u,
        CLOCKS_CLK_HSTX_CTRL_AUXSRC_VALUE_CLK_SYS,
        SYS_CLOCK_HZ,
        SYS_CLOCK_HZ
    );

    // Configure 1 bpp monochrome TMDS expansion (rp2350-datasheet.pdf §12.11.7, Table 1368):
    //   Each lane right-rotates by 25 (moves bit 0 -> bit 7) with 1 valid bit (NBITS = 0),
    //   mapping pixel 0 -> 0x00 (black) and pixel 1 -> 0x80 (bright gray/white) on R, G, B.
    hstx_ctrl_hw->expand_tmds =
        (0u  << HSTX_CTRL_EXPAND_TMDS_L2_NBITS_LSB) |
        (25u << HSTX_CTRL_EXPAND_TMDS_L2_ROT_LSB)   |
        (0u  << HSTX_CTRL_EXPAND_TMDS_L1_NBITS_LSB) |
        (25u << HSTX_CTRL_EXPAND_TMDS_L1_ROT_LSB)   |
        (0u  << HSTX_CTRL_EXPAND_TMDS_L0_NBITS_LSB) |
        (25u << HSTX_CTRL_EXPAND_TMDS_L0_ROT_LSB);

    // Expander shifter (rp2350-datasheet.pdf §12.11.7, Table 1367):
    //   ENC_N_SHIFTS = 0 means 32 shifts per 32-bit word (1 bit/pixel, LSB-first, ENC_SHIFT = 1).
    //   RAW_N_SHIFTS = 1, RAW_SHIFT = 0 keeps 30-bit control words unshifted.
    hstx_ctrl_hw->expand_shift =
        (0u << HSTX_CTRL_EXPAND_SHIFT_ENC_N_SHIFTS_LSB) |
        (1u << HSTX_CTRL_EXPAND_SHIFT_ENC_SHIFT_LSB)    |
        (1u << HSTX_CTRL_EXPAND_SHIFT_RAW_N_SHIFTS_LSB) |
        (0u << HSTX_CTRL_EXPAND_SHIFT_RAW_SHIFT_LSB);

    // Output crossbar matching Adafruit DVI Sock pinout (see README.md):
    //   GP12/13 (BIT0/1) = D0+/D0- (Lane 0: bits  0..9)
    //   GP14/15 (BIT2/3) = CK+/CK- (Clock generator)
    //   GP16/17 (BIT4/5) = D2+/D2- (Lane 2: bits 20..29)
    //   GP18/19 (BIT6/7) = D1+/D1- (Lane 1: bits 10..19)
    const uint32_t lane0 = (0u  << HSTX_CTRL_BIT0_SEL_P_LSB) | (1u  << HSTX_CTRL_BIT0_SEL_N_LSB);
    const uint32_t lane1 = (10u << HSTX_CTRL_BIT0_SEL_P_LSB) | (11u << HSTX_CTRL_BIT0_SEL_N_LSB);
    const uint32_t lane2 = (20u << HSTX_CTRL_BIT0_SEL_P_LSB) | (21u << HSTX_CTRL_BIT0_SEL_N_LSB);

    hstx_ctrl_hw->bit[0] = lane0;
    hstx_ctrl_hw->bit[1] = lane0 | HSTX_CTRL_BIT0_INV_BITS;
    hstx_ctrl_hw->bit[2] = HSTX_CTRL_BIT0_CLK_BITS;
    hstx_ctrl_hw->bit[3] = HSTX_CTRL_BIT0_CLK_BITS | HSTX_CTRL_BIT0_INV_BITS;
    hstx_ctrl_hw->bit[4] = lane2;
    hstx_ctrl_hw->bit[5] = lane2 | HSTX_CTRL_BIT0_INV_BITS;
    hstx_ctrl_hw->bit[6] = lane1;
    hstx_ctrl_hw->bit[7] = lane1 | HSTX_CTRL_BIT0_INV_BITS;

    // Configure GP12-GP19 for HSTX (Function 0) with fast slew rate
    for (uint pin = PIN_DVI_FIRST; pin < (PIN_DVI_FIRST + PIN_DVI_COUNT); ++pin) {
        gpio_set_function(pin, GPIO_FUNC_HSTX);
        gpio_set_slew_rate(pin, GPIO_SLEW_RATE_FAST);
        gpio_set_drive_strength(pin, GPIO_DRIVE_STRENGTH_4MA);
    }

    // Enable HSTX: 5 DDR shifts of 2 bits = 10-bit TMDS symbols, clock period = 5 HSTX cycles
    hstx_ctrl_hw->csr = 0u;
    hstx_ctrl_hw->csr =
        HSTX_CTRL_CSR_EXPAND_EN_BITS          |
        (5u << HSTX_CTRL_CSR_CLKDIV_LSB)      |
        (5u << HSTX_CTRL_CSR_N_SHIFTS_LSB)    |
        (2u << HSTX_CTRL_CSR_SHIFT_LSB)       |
        HSTX_CTRL_CSR_EN_BITS;

    // Prioritize DMA on the AHB5 bus fabric so video streaming never stalls
    bus_ctrl_hw->priority = BUSCTRL_BUS_PRIORITY_DMA_W_BITS | BUSCTRL_BUS_PRIORITY_DMA_R_BITS;

    // Configure ping-pong DMA channels paced by DREQ_HSTX
    dma_channel_config cfg = dma_channel_get_default_config(DMACH_PING);
    channel_config_set_transfer_data_size(&cfg, DMA_SIZE_32);
    channel_config_set_read_increment(&cfg, true);
    channel_config_set_write_increment(&cfg, false);
    channel_config_set_dreq(&cfg, DREQ_HSTX);
    channel_config_set_chain_to(&cfg, DMACH_PONG);
    dma_channel_configure(
        DMACH_PING, &cfg,
        &hstx_fifo_hw->fifo,
        vblank_line_vsync_off,
        count_of(vblank_line_vsync_off),
        false
    );

    cfg = dma_channel_get_default_config(DMACH_PONG);
    channel_config_set_transfer_data_size(&cfg, DMA_SIZE_32);
    channel_config_set_read_increment(&cfg, true);
    channel_config_set_write_increment(&cfg, false);
    channel_config_set_dreq(&cfg, DREQ_HSTX);
    channel_config_set_chain_to(&cfg, DMACH_PING);
    dma_channel_configure(
        DMACH_PONG, &cfg,
        &hstx_fifo_hw->fifo,
        vblank_line_vsync_off,
        count_of(vblank_line_vsync_off),
        false
    );

    dma_hw->ints0 = (1u << DMACH_PING) | (1u << DMACH_PONG);
    dma_hw->inte0 = (1u << DMACH_PING) | (1u << DMACH_PONG);
    irq_set_exclusive_handler(DMA_IRQ_0, dma_irq_handler);
    irq_set_enabled(DMA_IRQ_0, true);

    dma_channel_start(DMACH_PING);
}

static void uart0_tx_enqueue_byte(uint8_t byte) {
    uint32_t next_head = (uart_tx_head + 1u) & UART_TX_RING_MASK;
    if (next_head == uart_tx_tail) {
        // Ring full: drop newest byte rather than blocking the cooperative loop
        return;
    }
    uart_tx_ring[uart_tx_head] = byte;
    uart_tx_head = next_head;
}

static void uart0_tx_enqueue_str(const char *s) {
    while (*s != '\0') {
        uart0_tx_enqueue_byte((uint8_t)*s++);
    }
}

static void uart0_tx_enqueue_u32_dec(uint32_t value) {
    char digits[10];
    uint count = 0u;
    do {
        digits[count++] = (char)('0' + (value % 10u));
        value /= 10u;
    } while (value > 0u);

    while (count > 0u) {
        uart0_tx_enqueue_byte((uint8_t)digits[--count]);
    }
}

static void uart0_tx_enqueue_i32_dec(int32_t value) {
    if (value < 0) {
        uart0_tx_enqueue_byte('-');
        uart0_tx_enqueue_u32_dec((uint32_t)(-(int64_t)value));
    } else {
        uart0_tx_enqueue_u32_dec((uint32_t)value);
    }
}

static void uart0_tx_enqueue_u8_hex(uint8_t value) {
    static const char HEX_DIGITS[16] = "0123456789ABCDEF";
    uart0_tx_enqueue_byte((uint8_t)HEX_DIGITS[(value >> 4u) & 0x0Fu]);
    uart0_tx_enqueue_byte((uint8_t)HEX_DIGITS[value & 0x0Fu]);
}

static void uart0_tx_enqueue_u8_bin(uint8_t value) {
    for (int bit = 7; bit >= 0; --bit) {
        uart0_tx_enqueue_byte(((value >> (uint)bit) & 1u) ? '1' : '0');
    }
}

static void uart0_init(void) {
    // Initialize UART0 peripheral and baud rate divisor for 115200 baud
    uart_init(UART_DEBUG, UART_DEBUG_BAUD);

    // Route GP0 -> UART0 TX and GP1 -> UART0 RX (Function 2)
    gpio_set_function(PIN_UART0_TX, GPIO_FUNC_UART);
    gpio_set_function(PIN_UART0_RX, GPIO_FUNC_UART);
    // Keep RX idling high (marking state) if the bridge is unplugged or resetting
    gpio_pull_up(PIN_UART0_RX);

    // 8N1, no hardware flow control (CTS/RTS not wired), 32-byte FIFOs enabled
    uart_set_hw_flow(UART_DEBUG, false, false);
    uart_set_format(UART_DEBUG, 8u, 1u, UART_PARITY_NONE);
    uart_set_fifo_enabled(UART_DEBUG, true);
}

static void uart0_tx_poll(void) {
    // Drain software TX ring into the PL011 TX FIFO while space is available
    while (uart_tx_tail != uart_tx_head && uart_is_writable(UART_DEBUG)) {
        uart_putc_raw(UART_DEBUG, (char)uart_tx_ring[uart_tx_tail]);
        uart_tx_tail = (uart_tx_tail + 1u) & UART_TX_RING_MASK;
    }
}

static void uart0_rx_poll(void) {
    // Read all pending bytes from the PL011 RX FIFO and enqueue formatted echoes
    while (uart_is_readable(UART_DEBUG)) {
        uint8_t ch = (uint8_t)uart_getc(UART_DEBUG);
        uart0_tx_enqueue_str("Serial character received: dec=");
        uart0_tx_enqueue_u32_dec(ch);
        uart0_tx_enqueue_str(" hex=0x");
        uart0_tx_enqueue_u8_hex(ch);
        uart0_tx_enqueue_str(" bin=0b");
        uart0_tx_enqueue_u8_bin(ch);
        uart0_tx_enqueue_str("\r\n");
    }
}

static void uart0_enqueue_boot_banner(void) {
    uart0_tx_enqueue_str("\r\n========================================\r\n");
    uart0_tx_enqueue_str("Pico 2 Desert Island - Test Harness (1e)\r\n");
    uart0_tx_enqueue_str("UART0: 115200 | DVI: 640x480 | CH9350: UART1\r\n");
    uart0_tx_enqueue_str("========================================\r\n");
}

// ---------------------------------------------------------------------------
// CH9350 USB HID-to-UART Bridge (UART1, State 2, CH9350DS.PDF §7.2.4, pp. 10-12)
// ---------------------------------------------------------------------------

typedef enum {
    CH9350_STATE_WAIT_SYNC1 = 0,
    CH9350_STATE_WAIT_SYNC2,
    CH9350_STATE_WAIT_CMD,
    CH9350_STATE_READ_PAYLOAD,
} ch9350_parse_state_t;

static ch9350_parse_state_t ch9350_state = CH9350_STATE_WAIT_SYNC1;
static uint8_t ch9350_cmd = 0u;
static uint8_t ch9350_payload[CH9350_MAX_PAYLOAD];
static uint8_t ch9350_payload_len = 0u;
static uint8_t ch9350_payload_idx = 0u;

static void ch9350_uart1_init(void) {
    uart_init(UART_HID, UART_HID_BAUD);

    // Route GP20 -> UART1 TX and GP21 -> UART1 RX (Function 2)
    gpio_set_function(PIN_UART1_TX, GPIO_FUNC_UART);
    gpio_set_function(PIN_UART1_RX, GPIO_FUNC_UART);
    // Keep RX idling high while CH9350 boots or if disconnected
    gpio_pull_up(PIN_UART1_RX);

    // 8N1, no hardware flow control, 32-byte FIFOs enabled
    uart_set_hw_flow(UART_HID, false, false);
    uart_set_format(UART_HID, 8u, 1u, UART_PARITY_NONE);
    uart_set_fifo_enabled(UART_HID, true);
}

static const char *hid_keycode_name(uint8_t code) {
    static const char *const LETTERS[26] = {
        "A","B","C","D","E","F","G","H","I","J","K","L","M",
        "N","O","P","Q","R","S","T","U","V","W","X","Y","Z"
    };
    static const char *const DIGITS[10] = {
        "1","2","3","4","5","6","7","8","9","0"
    };

    if (code >= 0x04u && code <= 0x1Du) {
        return LETTERS[code - 0x04u];
    }
    if (code >= 0x1Eu && code <= 0x27u) {
        return DIGITS[code - 0x1Eu];
    }
    switch (code) {
        case 0x28u: return "Enter";
        case 0x29u: return "Esc";
        case 0x2Au: return "Bksp";
        case 0x2Bu: return "Tab";
        case 0x2Cu: return "Space";
        case 0x2Du: return "-";
        case 0x2Eu: return "=";
        case 0x2Fu: return "[";
        case 0x30u: return "]";
        case 0x31u: return "\\";
        case 0x33u: return ";";
        case 0x34u: return "'";
        case 0x35u: return "`";
        case 0x36u: return ",";
        case 0x37u: return ".";
        case 0x38u: return "/";
        case 0x39u: return "CapsLock";
        case 0x4Fu: return "Right";
        case 0x50u: return "Left";
        case 0x51u: return "Down";
        case 0x52u: return "Up";
        default:    return NULL;
    }
}

static void ch9350_log_modifiers(uint8_t mod) {
    static const char *const MOD_NAMES[8] = {
        "LCtrl", "LShift", "LAlt", "LGUI",
        "RCtrl", "RShift", "RAlt", "RGUI"
    };
    if (mod == 0u) {
        return;
    }
    uart0_tx_enqueue_byte('(');
    bool first = true;
    for (uint i = 0u; i < 8u; ++i) {
        if ((mod & (1u << i)) != 0u) {
            if (!first) {
                uart0_tx_enqueue_byte('+');
            }
            uart0_tx_enqueue_str(MOD_NAMES[i]);
            first = false;
        }
    }
    uart0_tx_enqueue_byte(')');
}

static void ch9350_log_mouse_buttons(uint8_t btn) {
    if (btn == 0u) {
        return;
    }
    uart0_tx_enqueue_byte('(');
    bool first = true;
    if ((btn & 0x01u) != 0u) {
        uart0_tx_enqueue_byte('L');
        first = false;
    }
    if ((btn & 0x02u) != 0u) {
        if (!first) { uart0_tx_enqueue_byte('+'); }
        uart0_tx_enqueue_byte('R');
        first = false;
    }
    if ((btn & 0x04u) != 0u) {
        if (!first) { uart0_tx_enqueue_byte('+'); }
        uart0_tx_enqueue_byte('M');
    }
    uart0_tx_enqueue_byte(')');
}

static void ch9350_dispatch_frame(uint8_t cmd, const uint8_t *data) {
    switch (cmd) {
        case 0x01u: {
            // State 2/3/4 Keyboard Report (8 bytes: Mod, 0x00, Key1..Key6)
            uint8_t mod = data[0];
            uart0_tx_enqueue_str("[CH9350] KBD: mod=0x");
            uart0_tx_enqueue_u8_hex(mod);
            ch9350_log_modifiers(mod);
            uart0_tx_enqueue_str(" keys=[");
            bool any_key = false;
            for (uint i = 2u; i < 8u; ++i) {
                uint8_t k = data[i];
                if (k == 0u) {
                    continue;
                }
                if (any_key) {
                    uart0_tx_enqueue_str(", ");
                }
                uart0_tx_enqueue_str("0x");
                uart0_tx_enqueue_u8_hex(k);
                const char *name = hid_keycode_name(k);
                if (name != NULL) {
                    uart0_tx_enqueue_byte('(');
                    uart0_tx_enqueue_str(name);
                    uart0_tx_enqueue_byte(')');
                }
                any_key = true;
            }
            if (!any_key) {
                uart0_tx_enqueue_str("none");
            }
            uart0_tx_enqueue_str("]\r\n");
            break;
        }
        case 0x02u: {
            // State 2 Relative Mouse Report (4 bytes: Buttons, dX, dY, Wheel)
            uint8_t btn = data[0];
            int8_t dx = (int8_t)data[1];
            int8_t dy = (int8_t)data[2];
            int8_t wheel = (int8_t)data[3];
            uart0_tx_enqueue_str("[CH9350] MOUSE: btn=0x");
            uart0_tx_enqueue_u8_hex(btn);
            ch9350_log_mouse_buttons(btn);
            uart0_tx_enqueue_str(" dx=");
            uart0_tx_enqueue_i32_dec(dx);
            uart0_tx_enqueue_str(" dy=");
            uart0_tx_enqueue_i32_dec(dy);
            uart0_tx_enqueue_str(" wheel=");
            uart0_tx_enqueue_i32_dec(wheel);
            uart0_tx_enqueue_str("\r\n");
            break;
        }
        case 0x04u: {
            // State 3/4 Absolute Mouse Report (7 bytes: ID, Btn, X_lo, X_hi, Y_lo, Y_hi, Wheel)
            uint8_t btn = data[1];
            uint32_t ax = (uint32_t)data[2] | ((uint32_t)data[3] << 8u);
            uint32_t ay = (uint32_t)data[4] | ((uint32_t)data[5] << 8u);
            int8_t wheel = (int8_t)data[6];
            uart0_tx_enqueue_str("[CH9350] ABS_MOUSE: btn=0x");
            uart0_tx_enqueue_u8_hex(btn);
            ch9350_log_mouse_buttons(btn);
            uart0_tx_enqueue_str(" x=");
            uart0_tx_enqueue_u32_dec(ax);
            uart0_tx_enqueue_str(" y=");
            uart0_tx_enqueue_u32_dec(ay);
            uart0_tx_enqueue_str(" wheel=");
            uart0_tx_enqueue_i32_dec(wheel);
            uart0_tx_enqueue_str("\r\n");
            break;
        }
        case 0x80u:
            // State 2/3/4 Status Change / LED sync query (CH9350DS.PDF §7.2.4.8, p. 12):
            // 1-byte payload already consumed by the parser; ignore silently.
            break;
        case 0x82u:
            // State 0/1 Status Request Frame (CH9350DS.PDF §7.2.4.2, p. 10)
            uart0_tx_enqueue_str("[CH9350] STATUS_REQ (State 0/1): val=0x");
            uart0_tx_enqueue_u8_hex(data[0]);
            uart0_tx_enqueue_str("\r\n");
            break;
        case 0x84u:
            // State 1 Reset Delay Command (CH9350DS.PDF §7.2.4.4, p. 12)
            uart0_tx_enqueue_str("[CH9350] RESET_DELAY (0x84)\r\n");
            break;
        case 0x85u:
            // State 0/1 Working Status Change (CH9350DS.PDF §7.2.4.5, p. 12)
            uart0_tx_enqueue_str("[CH9350] MODE_CHANGE: state=0x");
            uart0_tx_enqueue_u8_hex(data[0]);
            uart0_tx_enqueue_str("\r\n");
            break;
        case 0x86u:
            // Device Disconnect Command (CH9350DS.PDF §7.2.4.6, p. 12)
            uart0_tx_enqueue_str("[CH9350] DEVICE_DISCONNECT (0x86)\r\n");
            break;
        case 0x87u:
            // Obtain Version Number Command (CH9350DS.PDF §7.2.4.7, p. 12)
            uart0_tx_enqueue_str("[CH9350] VERSION_QUERY (0x87)\r\n");
            break;
        default:
            uart0_tx_enqueue_str("[CH9350] UNKNOWN cmd=0x");
            uart0_tx_enqueue_u8_hex(cmd);
            uart0_tx_enqueue_str("\r\n");
            break;
    }
}

static void ch9350_rx_poll(void) {
    while (uart_is_readable(UART_HID)) {
        uint8_t b = (uint8_t)uart_getc(UART_HID);

        switch (ch9350_state) {
            case CH9350_STATE_WAIT_SYNC1:
                if (b == CH9350_SYNC1) {
                    ch9350_state = CH9350_STATE_WAIT_SYNC2;
                }
                break;

            case CH9350_STATE_WAIT_SYNC2:
                if (b == CH9350_SYNC2) {
                    ch9350_state = CH9350_STATE_WAIT_CMD;
                } else if (b != CH9350_SYNC1) {
                    ch9350_state = CH9350_STATE_WAIT_SYNC1;
                }
                break;

            case CH9350_STATE_WAIT_CMD:
                ch9350_cmd = b;
                ch9350_payload_idx = 0u;
                switch (b) {
                    case 0x01u: ch9350_payload_len = 8u; break;
                    case 0x02u: ch9350_payload_len = 4u; break;
                    case 0x04u: ch9350_payload_len = 7u; break;
                    case 0x80u:
                    case 0x82u:
                    case 0x85u: ch9350_payload_len = 1u; break;
                    case 0x84u:
                    case 0x86u:
                    case 0x87u: ch9350_payload_len = 0u; break;
                    default:
                        ch9350_dispatch_frame(b, ch9350_payload);
                        ch9350_state = CH9350_STATE_WAIT_SYNC1;
                        continue;
                }
                if (ch9350_payload_len == 0u) {
                    ch9350_dispatch_frame(ch9350_cmd, ch9350_payload);
                    ch9350_state = CH9350_STATE_WAIT_SYNC1;
                } else {
                    ch9350_state = CH9350_STATE_READ_PAYLOAD;
                }
                break;

            case CH9350_STATE_READ_PAYLOAD:
                ch9350_payload[ch9350_payload_idx++] = b;
                if (ch9350_payload_idx >= ch9350_payload_len) {
                    ch9350_dispatch_frame(ch9350_cmd, ch9350_payload);
                    ch9350_state = CH9350_STATE_WAIT_SYNC1;
                }
                break;
        }
    }
}

static void uart0_enqueue_heartbeat(uint32_t counter, uint32_t uptime_s) {
    uart0_tx_enqueue_str("Heartbeat #");
    uart0_tx_enqueue_u32_dec(counter);
    uart0_tx_enqueue_str(" (uptime: ");
    uart0_tx_enqueue_u32_dec(uptime_s);
    uart0_tx_enqueue_str(" s)\r\n");
}

static void leds_init(void) {
    for (uint i = 0; i < 3; ++i) {
        gpio_init(LED_PINS[i]);
        gpio_set_dir(LED_PINS[i], GPIO_OUT);
        gpio_put(LED_PINS[i], false);
    }
}

static void leds_set_active(uint active_index) {
    for (uint i = 0; i < 3; ++i) {
        gpio_put(LED_PINS[i], i == active_index);
    }
}

static void piezo_init(void) {
    gpio_set_function(PIN_PIEZO, GPIO_FUNC_PWM);

    piezo_slice = pwm_gpio_to_slice_num(PIN_PIEZO);
    piezo_channel = pwm_gpio_to_channel(PIN_PIEZO);

    pwm_config cfg = pwm_get_default_config();
    pwm_config_set_phase_correct(&cfg, false);
    pwm_config_set_clkdiv(&cfg, (float)clock_get_hz(clk_sys) / (float)PIEZO_PWM_TICK_HZ);
    pwm_config_set_wrap(&cfg, PIEZO_PWM_WRAP);

    pwm_init(piezo_slice, &cfg, false);
    pwm_set_chan_level(piezo_slice, piezo_channel, PIEZO_PWM_LEVEL_OFF);
    pwm_set_enabled(piezo_slice, true);
}

static void piezo_set_active(bool on) {
    pwm_set_chan_level(piezo_slice, piezo_channel,
                       on ? PIEZO_PWM_LEVEL_ON : PIEZO_PWM_LEVEL_OFF);
}

int main(void) {
    // Configure PLL_SYS to 126 MHz first so PWM, UART0, and HSTX derive from it
    set_sys_clock_khz(SYS_CLOCK_KHZ, true);

    leds_init();
    piezo_init();
    uart0_init();
    ch9350_uart1_init();

    // Draw static 1 px border + 20x15 (32x32 px) grid and initial bouncing box
    fb_draw_grid_and_border();
    uint32_t box_x = 16u;
    uint32_t box_y = 16u;
    int32_t box_dx = 1;
    int32_t box_dy = 1;
    fb_xor_box(box_x, box_y);

    dvi_hstx_init();

    // Queue boot banner for immediate non-blocking transmission
    uart0_enqueue_boot_banner();

    // Free-running 64-bit microsecond hardware timer (TIMER0)
    uint64_t now_us = time_us_64();

    // Start immediately on Red LED and schedule next step in 1 s
    uint led_index = 0;
    leds_set_active(led_index);
    uint64_t next_led_step_us = now_us + LED_STEP_INTERVAL_US;

    // Trigger an initial 100 ms beep on boot/reset, then repeat every 3 s
    bool piezo_active = true;
    piezo_set_active(true);
    uint64_t piezo_stop_us = now_us + PIEZO_DURATION_US;
    uint64_t next_piezo_start_us = now_us + PIEZO_PERIOD_US;

    // Schedule first serial heartbeat in 1 s
    uint32_t heartbeat_count = 0u;
    uint64_t next_heartbeat_us = now_us + HEARTBEAT_INTERVAL_US;

    // Schedule bouncing XOR box animation (~60 px/s)
    uint64_t next_video_step_us = now_us + VIDEO_STEP_INTERVAL_US;

    // Non-blocking cooperative polling loop
    while (true) {
        now_us = time_us_64();

        // Task 1: Cycle Red -> Green -> Blue LEDs once per second
        if (now_us >= next_led_step_us) {
            led_index = (led_index + 1u) % 3u;
            leds_set_active(led_index);
            next_led_step_us += LED_STEP_INTERVAL_US;
        }

        // Task 2: Piezo 1 kHz beep for 100 ms every 3 seconds
        if (!piezo_active && now_us >= next_piezo_start_us) {
            piezo_set_active(true);
            piezo_active = true;
            piezo_stop_us = now_us + PIEZO_DURATION_US;
            next_piezo_start_us += PIEZO_PERIOD_US;
        } else if (piezo_active && now_us >= piezo_stop_us) {
            piezo_set_active(false);
            piezo_active = false;
        }

        // Task 3: Serial heartbeat once per second
        if (now_us >= next_heartbeat_us) {
            heartbeat_count++;
            uart0_enqueue_heartbeat(heartbeat_count, (uint32_t)(now_us / 1000000ull));
            next_heartbeat_us += HEARTBEAT_INTERVAL_US;
        }

        // Task 4: Poll UART0 RX and echo received characters (dec/hex/bin)
        uart0_rx_poll();

        // Task 5: Poll UART1 (CH9350) for framed 0x57 0xAB HID packets
        ch9350_rx_poll();

        // Drain software TX ring buffer into UART0 hardware TX FIFO
        uart0_tx_poll();

        // Task 6: Glide 32x32 XOR box across the 20x15 grid and bounce off border
        if (now_us >= next_video_step_us) {
            fb_xor_box(box_x, box_y);

            if ((box_dx > 0 && box_x >= BOX_MAX_X) || (box_dx < 0 && box_x <= BOX_MIN_X)) {
                box_dx = -box_dx;
            }
            if ((box_dy > 0 && box_y >= BOX_MAX_Y) || (box_dy < 0 && box_y <= BOX_MIN_Y)) {
                box_dy = -box_dy;
            }
            box_x = (uint32_t)((int32_t)box_x + box_dx);
            box_y = (uint32_t)((int32_t)box_y + box_dy);

            fb_xor_box(box_x, box_y);
            next_video_step_us += VIDEO_STEP_INTERVAL_US;
        }
    }
}
