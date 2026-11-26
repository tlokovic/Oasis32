/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Status LED Driver (SIO GP26=Red, GP27=Green, GP28=Blue)
 * ============================================================================
 * Exposes the two LED primitives matching BIOS_LED_* ABI:
 *   - led_write (a0=idx, a1=state) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 *   - led_read  (a0=idx)           -> a0 = 0|1        or ERR_INVALID_ARG (-2)
 *
 * References:
 *   - rp2350-datasheet.pdf §3.1.11 (SIO), Table 17, pp. 49-51
 *   - rp2350-datasheet.pdf §9.11.1 (IO_BANK0), §9.11.3 (PADS_BANK0)
 * ============================================================================
 */

#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "hw/rp2350_regs.h"
#include "hw/oasis32_pins.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * leds_init(): Configure GP26 (Red), GP27 (Green), GP28 (Blue) as SIO outputs
 * ---------------------------------------------------------------------------- */
.global leds_init
.type leds_init, @function
leds_init:
    li      t0, SIO_BASE
    li      t1, SIO_LED_ALL_MASK
    sw      t1, SIO_GPIO_OUT_CLR_OFF(t0)    /* Start all LEDs OFF */
    sw      t1, SIO_GPIO_OE_SET_OFF(t0)     /* Enable SIO output drivers */

    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_SIO
    sw      t1, IO_LED_RED_CTRL_OFF(t0)
    sw      t1, IO_LED_GREEN_CTRL_OFF(t0)
    sw      t1, IO_LED_BLUE_CTRL_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, (PADS_ISO_BIT | PADS_OD_BIT)
    sw      t1, PADS_LED_RED_OFF(t0)
    sw      t1, PADS_LED_GREEN_OFF(t0)
    sw      t1, PADS_LED_BLUE_OFF(t0)
    ret
.size leds_init, . - leds_init

/* ----------------------------------------------------------------------------
 * led_write(a0 = idx [0..2], a1 = state [0=off, nonzero=on]) -> a0 = ERR_*
 * ---------------------------------------------------------------------------- */
.global led_write
.type led_write, @function
led_write:
    li      t0, LED_COUNT
    bgeu    a0, t0, 2f

    addi    t0, a0, 26                      /* GP26=Red, GP27=Green, GP28=Blue */
    li      t1, 1
    sll     t1, t1, t0
    li      t2, SIO_BASE
    beqz    a1, 1f
    sw      t1, SIO_GPIO_OUT_SET_OFF(t2)
    li      a0, ERR_OK
    ret
1:
    sw      t1, SIO_GPIO_OUT_CLR_OFF(t2)
    li      a0, ERR_OK
    ret
2:
    li      a0, ERR_INVALID_ARG
    ret
.size led_write, . - led_write

/* ----------------------------------------------------------------------------
 * led_read(a0 = idx [0..2]) -> a0 = 0|1 or ERR_INVALID_ARG (-2)
 * ---------------------------------------------------------------------------- */
.global led_read
.type led_read, @function
led_read:
    li      t0, LED_COUNT
    bgeu    a0, t0, 1f

    li      t2, SIO_BASE
    lw      t1, SIO_GPIO_OUT_OFF(t2)
    addi    t0, a0, 26
    srl     a0, t1, t0
    andi    a0, a0, 1
    ret
1:
    li      a0, ERR_INVALID_ARG
    ret
.size led_read, . - led_read
