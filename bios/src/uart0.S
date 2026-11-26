/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Debug Serial Driver (PL011 UART0 @ 115200 8N1)
 * ============================================================================
 * Exposes the four fundamental byte primitives matching BIOS_SERIAL_* ABI:
 *   - uart0_read      ()        -> a0 = byte (0..255)  [blocking]
 *   - uart0_try_read  ()        -> a0 = byte (0..255)  or ERR_EMPTY (-3)
 *   - uart0_write     (a0=byte) -> a0 = ERR_OK (0)     [blocking]
 *   - uart0_try_write (a0=byte) -> a0 = ERR_OK (0)     or ERR_BUSY (-4)
 * Plus internal BIOS helper:
 *   - uart0_puts      (a0=cstr) -> prints NUL-terminated string
 *
 * Reference: rp2350-datasheet.pdf §12.1.8 (UART0), pp. 883-895
 * ============================================================================
 */

#include "abi/bios_abi.h"
#include "hw/rp2350_regs.h"
#include "hw/oasis32_pins.h"
#include "bios_config.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * uart0_init: Configure GP0/GP1 and PL011 UART0 for 115200 8N1 with FIFOs
 * ---------------------------------------------------------------------------- */
.global uart0_init
.type uart0_init, @function
uart0_init:
    li      t0, UART0_BASE
    sw      zero, UART_CR_OFF(t0)       /* Disable UART while configuring */

    li      t1, CFG_UART_IBRD_115200
    sw      t1, UART_IBRD_OFF(t0)       /* IBRD = 68 */
    li      t1, CFG_UART_FBRD_115200
    sw      t1, UART_FBRD_OFF(t0)       /* FBRD = 23 -> 115200.00 bps exact */
    li      t1, UART_LCR_8N1_FIFO
    sw      t1, UART_LCR_H_OFF(t0)      /* 8N1 + 32-byte FIFOs (latches BRD) */
    li      t1, UART_CR_EN_TX_RX
    sw      t1, UART_CR_OFF(t0)         /* UARTEN | TXE | RXE */

    /* Route GP0 -> UART0 TX, GP1 -> UART0 RX (Function 2) */
    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_UART
    sw      t1, IO_UART0_TX_CTRL_OFF(t0)
    sw      t1, IO_UART0_RX_CTRL_OFF(t0)

    /* Clear RP2350 pad isolation (ISO) on GP0/GP1; enable IE & PUE on GP1 RX */
    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, (PADS_ISO_BIT | PADS_OD_BIT)
    sw      t1, PADS_UART0_TX_OFF(t0)
    li      t1, (PADS_ISO_BIT | PADS_PDE_BIT)
    sw      t1, PADS_UART0_RX_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_SET
    li      t1, (PADS_IE_BIT | PADS_PUE_BIT)
    sw      t1, PADS_UART0_RX_OFF(t0)
    ret
.size uart0_init, . - uart0_init

/* ----------------------------------------------------------------------------
 * uart0_read() -> a0 = received byte (0..255), blocking
 * ---------------------------------------------------------------------------- */
.global uart0_read
.type uart0_read, @function
uart0_read:
    li      t0, UART0_BASE
1:
    lw      t1, UART_FR_OFF(t0)
    andi    t1, t1, UART_FR_RXFE_BIT
    bnez    t1, 1b                      /* Spin while RX FIFO is empty */
    lw      a0, UART_DR_OFF(t0)
    andi    a0, a0, 0xFF
    ret
.size uart0_read, . - uart0_read

/* ----------------------------------------------------------------------------
 * uart0_try_read() -> a0 = received byte (0..255) or ERR_EMPTY (-3)
 * ---------------------------------------------------------------------------- */
.global uart0_try_read
.type uart0_try_read, @function
uart0_try_read:
    li      t0, UART0_BASE
    lw      t1, UART_FR_OFF(t0)
    andi    t1, t1, UART_FR_RXFE_BIT
    bnez    t1, 1f
    lw      a0, UART_DR_OFF(t0)
    andi    a0, a0, 0xFF
    ret
1:
    li      a0, ERR_EMPTY
    ret
.size uart0_try_read, . - uart0_try_read

/* ----------------------------------------------------------------------------
 * uart0_write(a0 = byte) -> a0 = ERR_OK (0), blocking
 * ---------------------------------------------------------------------------- */
.global uart0_write
.type uart0_write, @function
uart0_write:
    li      t0, UART0_BASE
1:
    lw      t1, UART_FR_OFF(t0)
    andi    t1, t1, UART_FR_TXFF_BIT
    bnez    t1, 1b                      /* Spin while TX FIFO is full */
    andi    a0, a0, 0xFF
    sw      a0, UART_DR_OFF(t0)
    li      a0, ERR_OK
    ret
.size uart0_write, . - uart0_write

/* ----------------------------------------------------------------------------
 * uart0_try_write(a0 = byte) -> a0 = ERR_OK (0) or ERR_BUSY (-4)
 * ---------------------------------------------------------------------------- */
.global uart0_try_write
.type uart0_try_write, @function
uart0_try_write:
    li      t0, UART0_BASE
    lw      t1, UART_FR_OFF(t0)
    andi    t1, t1, UART_FR_TXFF_BIT
    bnez    t1, 1f
    andi    a0, a0, 0xFF
    sw      a0, UART_DR_OFF(t0)
    li      a0, ERR_OK
    ret
1:
    li      a0, ERR_BUSY
    ret
.size uart0_try_write, . - uart0_try_write

/* ----------------------------------------------------------------------------
 * uart0_puts(a0 = NUL-terminated string pointer)
 * ---------------------------------------------------------------------------- */
.global uart0_puts
.type uart0_puts, @function
uart0_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0
1:
    lbu     a0, 0(s0)
    beqz    a0, 2f
    call    uart0_write
    addi    s0, s0, 1
    j       1b
2:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size uart0_puts, . - uart0_puts
