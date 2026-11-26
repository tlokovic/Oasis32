/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — System Control Services (BIOS_BLK_SYS, 0x00-0x0F)
 * ============================================================================
 * Exposes:
 *   - sys_version              ()          -> a0 = (major<<16)|(minor<<8)|patch
 *   - sys_reboot               ()          -> full RP2350 Watchdog/PSM reset
 *   - sys_set_os_ecall_handler (a0=fn_ptr) -> a0 = ERR_OK or ERR_INVALID_ARG
 *
 * References:
 *   - rp2350-datasheet.pdf §7.4.4 (PSM_WDSEL, pp. 455-458)
 *   - rp2350-datasheet.pdf §12.9.6 (WATCHDOG_CTRL.TRIGGER, pp. 1107-1108)
 *   - docs/ExecutionModel.md §5.2 (OS ecall extension hook)
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "hw/rp2350_regs.h"
#include "bios_config.h"
#include "bios_ram.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * sys_version() -> a0 = packed (major << 16) | (minor << 8) | patch
 * ---------------------------------------------------------------------------- */
.global sys_version
.type sys_version, @function
sys_version:
    li      a0, BIOS_VERSION_PACKED
    ret
.size sys_version, . - sys_version

/* ----------------------------------------------------------------------------
 * sys_reboot() -> triggers full RP2350 hardware reset (never returns)
 * ---------------------------------------------------------------------------- */
.global sys_reboot
.type sys_reboot, @function
sys_reboot:
    /* Mask Core 0 interrupts so nothing interferes during reset sequence */
    csrci   mstatus, MSTATUS_MIE_BIT

    /* Configure PSM to reset both cores, SRAM, XIP, clocks, and peripherals
     * (leaving ROSC/XOSC running so the PSM stays clocked) */
    li      t0, PSM_BASE
    li      t1, PSM_WDSEL_FULL_RESET
    sw      t1, PSM_WDSEL_OFF(t0)

    /* Clear Boot ROM watchdog reboot magic (SCRATCH4) for a clean cold boot */
    li      t0, WATCHDOG_BASE
    sw      zero, WATCHDOG_SCRATCH4_OFF(t0)

    /* Trigger immediate hardware watchdog reset */
    li      t1, WATCHDOG_CTRL_TRIGGER_BIT
    sw      t1, WATCHDOG_CTRL_OFF(t0)
1:
    wfi
    j       1b
.size sys_reboot, . - sys_reboot

/* ----------------------------------------------------------------------------
 * sys_set_os_ecall_handler(a0 = fn_ptr) -> a0 = ERR_OK or ERR_INVALID_ARG
 *   Accepts 0 (clear handler) or a 2-byte-aligned address in User SRAM
 *   [USER_RAM_BASE, USER_RAM_END).
 * ---------------------------------------------------------------------------- */
.global sys_set_os_ecall_handler
.type sys_set_os_ecall_handler, @function
sys_set_os_ecall_handler:
    beqz    a0, 1f                          /* 0 = unregister OS handler */

    /* Must be at least 2-byte aligned (RV32IMAC) and inside User SRAM */
    andi    t0, a0, 1
    bnez    t0, 2f
    li      t0, USER_RAM_BASE
    bltu    a0, t0, 2f
    li      t0, (USER_RAM_BASE + USER_RAM_SIZE - 2)
    bgtu    a0, t0, 2f
1:
    li      t0, BIOS_OS_ECALL_HANDLER_ADDR
    sw      a0, 0(t0)
    li      a0, ERR_OK
    ret
2:
    li      a0, ERR_INVALID_ARG
    ret
.size sys_set_os_ecall_handler, . - sys_set_os_ecall_handler
