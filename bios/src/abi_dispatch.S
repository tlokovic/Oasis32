/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Vectored mtvec Trap Table & ecall ABI Dispatcher
 * ============================================================================
 * Installs the RP2350 Hazard3 Vectored Mode (MODE=1) trap table in .text.mtvec
 * (256-byte aligned inside the first 4 KB of Flash, bios/ld/bios.ld.S).
 *
 * Trap Routing (docs/ExecutionModel.md §3 & §5):
 *   - BASE + 0x00 (Sync exceptions):
 *       * mcause == 11 (M-mode ecall) -> Resident BIOS ABI Dispatcher
 *         - Saves ra, mepc+4, mstatus on caller's stack (16-byte aligned)
 *         - Re-enables mstatus.MIE during service execution
 *         - Dispatches a7 in 0x0000-0x00FF (BIOS) or >= 0x0100 (OS hook)
 *         - Restores mstatus/mepc with MIE=0, returns via mret
 *       * Other mcause -> BIOS fault halt (reports fault over UART0)
 *   - BASE + 0x2C (Cause 11: MEIP / Xh3irq):
 *       * Placeholder for Core 0 peripheral IRQs (swaps sp <-> mscratch)
 *
 * References:
 *   - riscv-privileged.pdf §3.1.6-§3.1.12 (mstatus, mtvec, mepc, mcause)
 *   - docs/ExecutionModel.md §3, §5
 * ============================================================================
 */

#include "abi/bios_abi.h"
#include "hw/rp2350_regs.h"
#include "bios_ram.h"

/* ============================================================================
 * 1. Vectored mtvec Table (256-byte aligned, uncompressed 4-byte entries)
 * ============================================================================ */
.section .text.mtvec, "ax"
.option push
.option norvc

.global mtvec_table
mtvec_table:
    j       trap_sync_entry             /* +0x00: Synchronous exceptions (ecall, faults) */
    j       trap_unhandled_irq          /* +0x04: Cause 1  (reserved) */
    j       trap_unhandled_irq          /* +0x08: Cause 2  (reserved) */
    j       trap_unhandled_irq          /* +0x0C: Cause 3  (MSIP) */
    j       trap_unhandled_irq          /* +0x10: Cause 4  (reserved) */
    j       trap_unhandled_irq          /* +0x14: Cause 5  (reserved) */
    j       trap_unhandled_irq          /* +0x18: Cause 6  (reserved) */
    j       trap_unhandled_irq          /* +0x1C: Cause 7  (MTIP) */
    j       trap_unhandled_irq          /* +0x20: Cause 8  (reserved) */
    j       trap_unhandled_irq          /* +0x24: Cause 9  (reserved) */
    j       trap_unhandled_irq          /* +0x28: Cause 10 (reserved) */
    j       trap_meip_entry             /* +0x2C: Cause 11 (MEIP / Hazard3 Xh3irq) */

.option pop

/* ============================================================================
 * 2. Synchronous Trap Entry & Resident BIOS ecall Dispatcher
 * ============================================================================ */
.section .text, "ax"

.type trap_sync_entry, @function
trap_sync_entry:
    csrr    t0, mcause
    li      t1, MCAUSE_ECALL_M
    bne     t0, t1, trap_fault

    /* M-mode ecall: save caller ra, advanced mepc, and mstatus on caller stack */
    addi    sp, sp, -16
    sw      ra, 12(sp)
    csrr    t0, mepc
    addi    t0, t0, 4                   /* Advance past 4-byte ecall instruction */
    sw      t0, 8(sp)
    csrr    t1, mstatus
    sw      t1, 4(sp)

    /* Re-enable global interrupts so Core 0 IRQs stay live during BIOS calls */
    csrsi   mstatus, MSTATUS_MIE_BIT

    /* Partition check: a7 >= OS_SVC_BASE (0x0100) -> OS extension hook */
    li      t0, OS_SVC_BASE
    bgeu    a7, t0, ecall_os_extension

    /* ------------------------------------------------------------------------
     * Resident BIOS Service Dispatch (0x0000 - 0x00FF)
     *   0x10-0x13: Serial Console Services (UART0)
     *   0x50:      Timer Services (TIMER0 1 us monotonic clock)
     *   0x60:      Audio Services (Piezo Buzzer)
     *   0x70-0x71: Status LED Services (Red/Green/Blue)
     * ------------------------------------------------------------------------ */
    li      t0, BIOS_SERIAL_READ
    beq     a7, t0, svc_serial_read
    li      t0, BIOS_SERIAL_TRY_READ
    beq     a7, t0, svc_serial_try_read
    li      t0, BIOS_SERIAL_WRITE
    beq     a7, t0, svc_serial_write
    li      t0, BIOS_SERIAL_TRY_WRITE
    beq     a7, t0, svc_serial_try_write
    li      t0, BIOS_TIME_US
    beq     a7, t0, svc_time_us
    li      t0, BIOS_AUDIO_TONE
    beq     a7, t0, svc_audio_tone
    li      t0, BIOS_LED_WRITE
    beq     a7, t0, svc_led_write
    li      t0, BIOS_LED_READ
    beq     a7, t0, svc_led_read

    li      a0, ERR_UNSUPPORTED
    j       ecall_return

svc_serial_read:
    call    uart0_read
    j       ecall_return

svc_serial_try_read:
    call    uart0_try_read
    j       ecall_return

svc_serial_write:
    call    uart0_write
    j       ecall_return

svc_serial_try_write:
    call    uart0_try_write
    j       ecall_return

svc_time_us:
    call    timer_read_us
    j       ecall_return

svc_audio_tone:
    call    piezo_tone
    j       ecall_return

svc_led_write:
    call    led_write
    j       ecall_return

svc_led_read:
    call    led_read
    j       ecall_return

ecall_os_extension:
    li      t0, BIOS_OS_ECALL_HANDLER_ADDR
    lw      t0, 0(t0)
    beqz    t0, 1f
    jalr    ra, t0, 0
    j       ecall_return
1:
    li      a0, ERR_UNSUPPORTED

ecall_return:
    /* Mask MIE while restoring mepc/mstatus so an IRQ cannot clobber them */
    csrci   mstatus, MSTATUS_MIE_BIT
    lw      t0, 8(sp)
    csrw    mepc, t0
    lw      t1, 4(sp)
    csrw    mstatus, t1
    lw      ra, 12(sp)
    addi    sp, sp, 16
    mret
.size trap_sync_entry, . - trap_sync_entry

/* ============================================================================
 * 3. Unhandled Synchronous Fault & Placeholder IRQ Handlers
 * ============================================================================ */
.type trap_fault, @function
trap_fault:
    la      a0, str_bios_fault
    call    uart0_puts
1:
    wfi
    j       1b
.size trap_fault, . - trap_fault

.type trap_meip_entry, @function
trap_meip_entry:
trap_unhandled_irq:
    mret
.size trap_meip_entry, . - trap_meip_entry

.section .rodata, "a"
str_bios_fault:
    .asciz "\r\n[BIOS FATAL] Unhandled synchronous trap.\r\n"
