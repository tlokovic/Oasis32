/*
 * ============================================================================
 * Oasis32 Public ABI — Shared Stage-2 SD Payload Linker Script Template
 * ============================================================================
 * Preprocessed at build time via `gcc -E -P -x c` with include/ on the
 * include path so User SRAM bounds and "OA32" header constants come strictly
 * from abi/memory_map.h and abi/boot_header.h.
 *
 * Layout trick (zero-boilerplate "OA32" header + exact SRAM addresses):
 *   - `.boot_header` is placed at LMA (USER_RAM_BASE - 32) = 0x1FFFFFE0 so
 *     `objcopy -Obinary` emits the 32-byte packed "OA32" header immediately
 *     followed (with zero padding) by the raw payload starting at offset 32.
 *   - The `crc32` word at +0x10 is emitted as 0 by the linker and patched
 *     post-build by `cmake/patch_oa32_crc.py` inside `oasis32_add_disk_executable`.
 *   - `.text`/`.rodata`/`.data`/`.bss` are linked directly at USER_RAM_BASE
 *     (0x20000000), so all runtime addresses and objdump listings match 1:1.
 *
 * Reference: docs/MemoryMap.md §2.1, docs/BootBehavior.md §3.4 & §5.3
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/boot_header.h"

MEMORY
{
    BOOT_HDR (r)   : ORIGIN = (USER_RAM_BASE - BOOT_HEADER_SIZE), LENGTH = BOOT_HEADER_SIZE
    USER_RAM (rwx) : ORIGIN = USER_RAM_BASE, LENGTH = USER_RAM_SIZE
}

ENTRY(_start)

SECTIONS
{
    /* Packed 32-byte "OA32" Boot Image Header (emitted at file offset 0) */
    .boot_header :
    {
        LONG(BOOT_HEADER_MAGIC);                /* +0x00: "OA32" (0x3233414F) */
        LONG(__payload_start);                  /* +0x04: load_addr           */
        LONG(_start);                           /* +0x08: entry_addr          */
        LONG(__payload_end - __payload_start);  /* +0x0C: payload_size        */
        LONG(0);                                /* +0x10: crc32 (patched)     */
        LONG(0);                                /* +0x14: reserved[0..3]      */
        LONG(0);                                /* +0x18: reserved[4..7]      */
        LONG(0);                                /* +0x1C: reserved[8..11]     */
    } > BOOT_HDR

    /* Stage-2 payload (emitted at file offset 32, executed at USER_RAM_BASE) */
    .text :
    {
        __payload_start = .;
        KEEP(*(.text.entry))
        *(.text .text.*)
        . = ALIGN(4);
    } > USER_RAM

    .rodata :
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > USER_RAM

    .data :
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        __payload_end = .;
    } > USER_RAM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > USER_RAM

    __payload_size = __payload_end - __payload_start;
    __stack_top    = USER_STACK_TOP;
}
