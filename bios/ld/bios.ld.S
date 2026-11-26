/*
 * ============================================================================
 * Oasis32 Stage-1 System ROM (BIOS) — Preprocessed Linker Script Template
 * ============================================================================
 * Preprocessed at build time via `gcc -E -P -x c` using bios/internal/ headers.
 *
 * Key invariants enforced here:
 *   1. .text.boot sits at 0x10000000 (lowest flash address, default entry).
 *   2. .picobin_block sits immediately after .text.boot (well inside 4 KB).
 *   3. .text.mtvec is 256-byte aligned (required for Vectored mtvec MODE=1).
 *   4. ZERO BIOS sections are placed in Main SRAM (0x20000000-0x2007FFFF);
 *      all private BIOS RAM lives in Scratchpad Banks 8-9 and USB DPRAM.
 *
 * Reference: docs/MemoryMap.md §4, docs/ExecutionModel.md §3
 * ============================================================================
 */

#include "bios_flash.h"
#include "bios_ram.h"

MEMORY
{
    FLASH    (rx) : ORIGIN = BIOS_FLASH_BASE,    LENGTH = BIOS_FLASH_SIZE
    SCRATCH8 (rw) : ORIGIN = BIOS_SCRATCH8_BASE, LENGTH = BIOS_SCRATCH8_SIZE
    SCRATCH9 (rw) : ORIGIN = BIOS_SCRATCH9_BASE, LENGTH = BIOS_SCRATCH9_SIZE
    DPRAM    (rw) : ORIGIN = BIOS_DPRAM_BASE,    LENGTH = BIOS_DPRAM_SIZE
}

ENTRY(_start)

SECTIONS
{
    .text :
    {
        /* 1. Reset entry at 0x10000000 */
        KEEP(*(.text.boot))

        /* 2. PICOBIN IMAGE_DEF block (guaranteed inside first 4 KB) */
        . = ALIGN(4);
        KEEP(*(.picobin_block))

        /* 3. Vectored mtvec trap table (256-byte aligned, inside first 4 KB) */
        . = ALIGN(BIOS_MTVEC_ALIGN);
        __mtvec_base = .;
        KEEP(*(.text.mtvec))
        __boot_window_end = .;

        /* 4. Remaining BIOS code and read-only data (XIP Flash) */
        . = ALIGN(4);
        *(.text .text.*)
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > FLASH

    /* Verify boot metadata and trap vector fit in the first 4 KB window */
    ASSERT((__boot_window_end - BIOS_FLASH_BASE) <= BIOS_BOOT_WINDOW_SIZE,
           "PICOBIN IMAGE_DEF / mtvec exceeded the 4 KB boot scan window")

    __bios_flash_end = .;

    /* Private BIOS stack symbols (no Flash LMA needed) */
    __core0_stack_top = BIOS_CORE0_STACK_TOP;
    __core1_stack_top = BIOS_CORE1_STACK_TOP;
}
