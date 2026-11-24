/**
 * Pico 2 Desert Island Computer - Phase 1 Hardware Test Harness (Sub-Phase 1c)
 *
 * Non-blocking cooperative polling loop verifying:
 *   - Status LEDs: Red (GP26) -> Green (GP27) -> Blue (GP28), advancing every 1 s
 *   - Piezo Buzzer: GP22 (PWM3 A), 1 kHz tone for 100 ms every 3 s
 *   - Hardware Reset: RUN pin (Pin 30) cleanly restarts sequence
 *   - Debug Serial (CP2102N): UART0 (GP0 TX, GP1 RX) at 115200 8N1
 *       * Boot banner on startup
 *       * 1-second incrementing heartbeat message
 *       * Non-blocking RX polling with dec/hex/bin formatted echo
 */

#include <stdbool.h>
#include <stdint.h>

#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h"
#include "hardware/uart.h"
#include "pico/stdlib.h"

// Hardware pin assignments (see README.md)
#define PIN_UART0_TX     0u   // UART0 TX (rp2350-datasheet.pdf §9.4, Table 677)
#define PIN_UART0_RX     1u   // UART0 RX (rp2350-datasheet.pdf §9.4, Table 677)
#define PIN_PIEZO       22u   // PWM3 A   (rp2350-datasheet.pdf §12.5.2, Table 1183)
#define PIN_LED_RED     26u
#define PIN_LED_GREEN   27u
#define PIN_LED_BLUE    28u

// Debug UART0 configuration (PL011, rp2350-datasheet.pdf §12.1)
#define UART_DEBUG              uart0
#define UART_DEBUG_BAUD         115200u
#define UART_TX_RING_SIZE       512u   // Power of 2 for cheap bitmask wrap
#define UART_TX_RING_MASK       (UART_TX_RING_SIZE - 1u)

// Scheduling intervals (microseconds, driven by 64-bit 1 MHz system timer)
#define LED_STEP_INTERVAL_US     1000000ull  // 1 s
#define HEARTBEAT_INTERVAL_US    1000000ull  // 1 s
#define PIEZO_PERIOD_US          3000000ull  // 3 s
#define PIEZO_DURATION_US         100000ull  // 100 ms

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

static const uint LED_PINS[3] = {
    PIN_LED_RED,
    PIN_LED_GREEN,
    PIN_LED_BLUE,
};

static uint piezo_slice;
static uint piezo_channel;

// Software TX ring buffer for strictly non-blocking UART0 output.
// The PL011 hardware TX FIFO holds 32 bytes (rp2350-datasheet.pdf §12.1.2.4);
// buffering formatted lines here prevents busy-waiting when a line > 32 bytes.
static uint8_t uart_tx_ring[UART_TX_RING_SIZE];
static uint32_t uart_tx_head = 0u;
static uint32_t uart_tx_tail = 0u;

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
    uart0_tx_enqueue_str("Pico 2 Desert Island - Test Harness (1c)\r\n");
    uart0_tx_enqueue_str("UART0: 115200 8N1 (GP0 TX, GP1 RX)\r\n");
    uart0_tx_enqueue_str("========================================\r\n");
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
    leds_init();
    piezo_init();
    uart0_init();

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

        // Drain software TX ring buffer into UART0 hardware TX FIFO
        uart0_tx_poll();
    }
}
