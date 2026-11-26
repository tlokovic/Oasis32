/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Main Entry Point
 * ============================================================================
 * During incremental Phase 3b bring-up, bios_main delegates to hardware_demo()
 * to exercise each resident driver strictly through the public ecall BIOS ABI.
 * In Sub-Phase 3c/3d this will transition to the interactive boot menu and
 * Stage-1 SD bootloader.
 * ============================================================================
 */

.section .text, "ax"

.global bios_main
.type bios_main, @function
bios_main:
    call    play_startup_tune
    call    hardware_demo
1:
    wfi
    j       1b
.size bios_main, . - bios_main
