/**
 * Pico 2 Desert Island Computer - Phase 1 Hardware Test Harness (Sub-Phase 1b)
 *
 * Non-blocking cooperative polling loop verifying:
 *   - Status LEDs: Red (GP26) -> Green (GP27) -> Blue (GP28), advancing every 1 s
 *   - Piezo Buzzer: GP22 (PWM3 A), 1 kHz tone for 100 ms every 5 s
 *   - Hardware Reset: RUN pin (Pin 30) cleanly restarts sequence
 */

#include <stdbool.h>
#include <stdint.h>

#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h"
#include "pico/stdlib.h"

// Hardware pin assignments (see README.md)
#define PIN_LED_RED     26u
#define PIN_LED_GREEN   27u
#define PIN_LED_BLUE    28u
#define PIN_PIEZO       22u   // PWM3 A (rp2350-datasheet.pdf §12.5.2, Table 1183)

// Scheduling intervals (microseconds, driven by 64-bit 1 MHz system timer)
#define LED_STEP_INTERVAL_US   1000000ull  // 1 s
#define PIEZO_PERIOD_US        3000000ull  // 5 s
#define PIEZO_DURATION_US       100000ull  // 100 ms

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

    // Free-running 64-bit microsecond hardware timer (TIMER0)
    uint64_t now_us = time_us_64();

    // Start immediately on Red LED and schedule next step in 1 s
    uint led_index = 0;
    leds_set_active(led_index);
    uint64_t next_led_step_us = now_us + LED_STEP_INTERVAL_US;

    // Trigger an initial 100 ms beep on boot/reset, then repeat every 5 s
    bool piezo_active = true;
    piezo_set_active(true);
    uint64_t piezo_stop_us = now_us + PIEZO_DURATION_US;
    uint64_t next_piezo_start_us = now_us + PIEZO_PERIOD_US;

    // Non-blocking cooperative polling loop
    while (true) {
        now_us = time_us_64();

        // Task 1: Cycle Red -> Green -> Blue LEDs once per second
        if (now_us >= next_led_step_us) {
            led_index = (led_index + 1u) % 3u;
            leds_set_active(led_index);
            next_led_step_us += LED_STEP_INTERVAL_US;
        }

        // Task 2: Piezo 1 kHz beep for 100 ms every 5 seconds
        if (!piezo_active && now_us >= next_piezo_start_us) {
            piezo_set_active(true);
            piezo_active = true;
            piezo_stop_us = now_us + PIEZO_DURATION_US;
            next_piezo_start_us += PIEZO_PERIOD_US;
        } else if (piezo_active && now_us >= piezo_stop_us) {
            piezo_set_active(false);
            piezo_active = false;
        }
    }
}
