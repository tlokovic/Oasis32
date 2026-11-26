/*
 * ============================================================================
 * Oasis32 BIOS Private — XIP Flash Layout & PICOBIN IMAGE_DEF Constants
 * ============================================================================
 * PRIVATE TO bios/ — NEVER exposed to disks/ or docs/ProgrammersReference.md.
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Reference:
 *   - rp2350-datasheet.pdf §5.9.5 (PICOBIN IMAGE_DEF), p. 390
 *   - riscv-privileged.pdf §3.1.7 (mtvec Vectored Mode), p. 45
 *   - docs/MemoryMap.md §4
 * ============================================================================
 */

#ifndef OASIS32_BIOS_FLASH_H
#define OASIS32_BIOS_FLASH_H

/* XIP Cached Flash Window (4 MB populated on Raspberry Pi Pico 2) */
#define BIOS_FLASH_BASE             0x10000000
#define BIOS_FLASH_SIZE             0x00400000  /* 4 MB */

/* Boot ROM scans the first 4 KB of Flash for a valid PICOBIN IMAGE_DEF */
#define BIOS_BOOT_WINDOW_SIZE       0x00001000

/* Minimum viable RP2350 RISC-V IMAGE_DEF (Table 504, p. 390) */
#define PICOBIN_MARKER_START        0xFFFFDED3
#define PICOBIN_IMAGE_TYPE_RISCV    0x11010142  /* EXE | RISCV | RP2350 */
#define PICOBIN_ITEM_LAST_1WORD     0x000001FF
#define PICOBIN_NEXT_BLOCK_SELF     0x00000000
#define PICOBIN_MARKER_END          0xAB123579

/* Vectored mtvec alignment & mode bit (riscv-privileged.pdf §3.1.7, p. 45) */
#define BIOS_MTVEC_ALIGN            256
#define BIOS_MTVEC_MODE_VECTORED    1

#endif /* OASIS32_BIOS_FLASH_H */
