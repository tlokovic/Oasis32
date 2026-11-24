/*
 * Bare-Metal Linker Script for Raspberry Pi Pico 2 (RP2350, Hazard3 RISC-V)
 * =========================================================================
 * Zero third-party libraries or SDK linker fragments.
 *
 * Physical Memory Map References:
 *   - rp2350-datasheet.pdf §2.2 (Address Map), pp. 25–28
 *   - rp2350-datasheet.pdf §4.2 (SRAM), p. 312
 *   - pico-2-datasheet.pdf §1 (4 MB QSPI Flash on Pico 2)
 */

MEMORY
{
    /*
     * XIP Cached Flash Window (0x10000000 - 0x103FFFFF, 4 MB on Pico 2).
     * The RP2350 Boot ROM configures basic XIP access and scans the first
     * 4 kB (0x10000000 - 0x10000FFF) for a valid PICOBIN IMAGE_DEF block
     * (rp2350-datasheet.pdf §5.1.5.2, p. 330; §5.9.5, p. 390).
     */
    FLASH (rx) : ORIGIN = 0x10000000, LENGTH = 4M

    /*
     * On-chip SRAM (520 kB total):
     *   - 0x20000000 - 0x2003FFFF : Banks 0-3 (256 kB, 4-way word-striped)
     *   - 0x20040000 - 0x2007FFFF : Banks 4-7 (256 kB, 4-way word-striped)
     *   - 0x20080000 - 0x20080FFF : Bank 8    (4 kB, non-striped scratchpad)
     *   - 0x20081000 - 0x20081FFF : Bank 9    (4 kB, non-striped scratchpad)
     * (rp2350-datasheet.pdf §4.2, p. 312)
     */
    RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 520K
}

/*
 * Declare the ELF entry point symbol for debuggers, objdump, and picotool.
 * On RP2350 RISC-V without an explicit ENTRY_POINT item in IMAGE_DEF, the
 * Boot ROM jumps to the lowest address of the image (0x10000000), where
 * .text.boot places _start (rp2350-datasheet.pdf §5.9.5.2, p. 390).
 */
ENTRY(_start)

SECTIONS
{
    /*
     * Executable code, PICOBIN metadata, and read-only constants in Flash.
     */
    .text :
    {
        /*
         * 1. Boot entry code MUST be at 0x10000000 (the lowest flash address)
         *    because our minimal 20-byte RISC-V IMAGE_DEF omits an explicit
         *    ENTRY_POINT item and relies on the Boot ROM's default RISC-V
         *    entry behavior (rp2350-datasheet.pdf §5.9.5.2, p. 390).
         */
        KEEP(*(.text.boot))

        /*
         * 2. PICOBIN IMAGE_DEF metadata block (word-aligned, placed right
         *    after .text.boot so it is guaranteed to sit well inside the
         *    Boot ROM's 4 kB scan window: 0x10000000 - 0x10000FFF).
         *    KEEP() prevents --gc-sections from stripping unreferenced metadata.
         */
        . = ALIGN(4);
        KEEP(*(.picobin_block))

        /*
         * 3. Remaining program instructions and read-only constants.
         */
        . = ALIGN(4);
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > FLASH

    /* End of flash image (LMA source if initialized .data is added later) */
    __etext = .;

    /*
     * Initialized read-write data in SRAM (LMA in FLASH, VMA in RAM).
     * Unused by the minimal blink program, but defined cleanly for future
     * Phase 2 expansion.
     */
    .data : AT(__etext)
    {
        . = ALIGN(4);
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM

    /*
     * Zero-initialized data in SRAM (NOLOAD so it consumes zero flash space).
     */
    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /*
     * Top of Core 0 stack at the end of SRAM (0x20082000), 16-byte aligned
     * per the standard RISC-V ilp32 calling convention. The stack grows
     * downward toward lower addresses.
     */
    __stack_top = (ORIGIN(RAM) + LENGTH(RAM)) & ~0xF;
}
