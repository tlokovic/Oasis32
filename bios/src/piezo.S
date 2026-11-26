/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Piezo Buzzer Driver (PWM Slice 3, Channel A on GP22)
 * ============================================================================
 * Configures PWM3 with DIV = 126.0 (126 MHz / 126 = 1 MHz counter tick) and
 * exposes piezo_tone(freq_hz) matching BIOS_AUDIO_TONE (0x60):
 *   - freq_hz == 0          -> silence (CC = 0, 0% duty)
 *   - 16 <= freq_hz <= 20000 -> TOP = (1,000,000 / freq_hz) - 1, CC = period/2
 *   - otherwise             -> ERR_INVALID_ARG (-2)
 *
 * References:
 *   - rp2350-datasheet.pdf §12.5.3 (PWM), p. 984
 *   - rp2350-datasheet.pdf §9.11.1 (IO_BANK0), §9.11.3 (PADS_BANK0)
 * ============================================================================
 */

#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "hw/rp2350_regs.h"
#include "hw/oasis32_pins.h"
#include "bios_config.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * piezo_init(): Configure GP22 (PWM3 A) at 1 MHz tick, initially silent
 * ---------------------------------------------------------------------------- */
.global piezo_init
.type piezo_init, @function
piezo_init:
    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_PWM
    sw      t1, IO_PIEZO_CTRL_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, (PADS_ISO_BIT | PADS_OD_BIT)
    sw      t1, PADS_PIEZO_OFF(t0)

    li      t0, PWM_BASE
    sw      zero, PWM_CH3_CSR_OFF(t0)       /* Disable slice while configuring */
    li      t1, CFG_PWM_PIEZO_DIV_126
    sw      t1, PWM_CH3_DIV_OFF(t0)         /* 126 MHz / 126.0 = 1 MHz tick */
    li      t1, 999
    sw      t1, PWM_CH3_TOP_OFF(t0)         /* Default 1 kHz period */
    sw      zero, PWM_CH3_CC_OFF(t0)        /* 0% duty = silent */
    sw      zero, PWM_CH3_CTR_OFF(t0)
    li      t1, 1
    sw      t1, PWM_CH3_CSR_OFF(t0)         /* EN=1, free-running */
    ret
.size piezo_init, . - piezo_init

/* ----------------------------------------------------------------------------
 * piezo_tone(a0 = freq_hz) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 * ---------------------------------------------------------------------------- */
.global piezo_tone
.type piezo_tone, @function
piezo_tone:
    beqz    a0, 1f

    li      t0, AUDIO_FREQ_MIN
    bltu    a0, t0, 2f
    li      t0, AUDIO_FREQ_MAX
    bgtu    a0, t0, 2f

    /* period = 1,000,000 / freq_hz; TOP = period - 1; CC = period >> 1 */
    li      t0, 1000000
    divu    t1, t0, a0
    addi    t2, t1, -1
    srli    t3, t1, 1

    li      t0, PWM_BASE
    sw      t2, PWM_CH3_TOP_OFF(t0)
    sw      t3, PWM_CH3_CC_OFF(t0)
    sw      zero, PWM_CH3_CTR_OFF(t0)       /* Avoid wrap delay when shrinking TOP */
    li      a0, ERR_OK
    ret
1:
    li      t0, PWM_BASE
    sw      zero, PWM_CH3_CC_OFF(t0)        /* 0% duty = silent */
    li      a0, ERR_OK
    ret
2:
    li      a0, ERR_INVALID_ARG
    ret
.size piezo_tone, . - piezo_tone
