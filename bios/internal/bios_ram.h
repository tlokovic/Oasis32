/*
 * ============================================================================
 * Oasis32 BIOS Private — Scratchpad SRAM & USB DPRAM Layout
 * ============================================================================
 * PRIVATE TO bios/ — NEVER exposed to disks/ or docs/ProgrammersReference.md.
 *
 * All BIOS-private stacks, scanline buffers, and driver state live strictly in
 * Scratchpad Banks 8-9 (8 KB) and USB DPRAM (4 KB), leaving 100% of Main SRAM
 * (512 KB) user-facing.
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Reference: docs/MemoryMap.md §2.2-§2.3
 * ============================================================================
 */

#ifndef OASIS32_BIOS_RAM_H
#define OASIS32_BIOS_RAM_H

/* ----------------------------------------------------------------------------
 * Scratchpad Bank 8 (4 KB, non-striped): Core 0 BIOS IRQ & Boot Stack
 * ---------------------------------------------------------------------------- */
#define BIOS_SCRATCH8_BASE          0x20080000
#define BIOS_SCRATCH8_SIZE          0x00001000
#define BIOS_CORE0_STACK_TOP        0x20081000  /* Loaded into sp at boot & mscratch */

/* ----------------------------------------------------------------------------
 * Scratchpad Bank 9 (4 KB, non-striped): Core 1 Video Coprocessor
 * ---------------------------------------------------------------------------- */
#define BIOS_SCRATCH9_BASE          0x20081000
#define BIOS_SCRATCH9_SIZE          0x00001000

#define BIOS_CORE1_LINE_A           0x20081000  /* 80 B ping-pong scanline A */
#define BIOS_CORE1_LINE_B           0x20081050  /* 80 B ping-pong scanline B */
#define BIOS_CORE1_CMD_LIST         0x200810A0  /* 352 B HSTX DMA cmd lists & state */
#define BIOS_CORE1_OAM_LATCH        0x20081200  /* 128 B frame-latched OAM copy */
#define BIOS_CORE1_STACK_BASE       0x20081280  /* 3,456 B Core 1 stack floor */
#define BIOS_CORE1_STACK_TOP        0x20082000  /* Core 1 initial sp */

/* ----------------------------------------------------------------------------
 * USB DPRAM (4 KB, data-only): BIOS-Private Driver State & Buffers
 * Requires deasserting RESET_BIT_USBCTRL before access (USB stays disabled).
 * ---------------------------------------------------------------------------- */
#define BIOS_DPRAM_BASE             0x50100000
#define BIOS_DPRAM_SIZE             0x00001000

#define BIOS_SD_SECTOR_BUF          0x50100000  /* 512 B LBA staging buffer */
#define BIOS_HID_STATE_BASE         0x50100200  /* 512 B CH9350 parser & queues */
#define BIOS_UART0_STATE_BASE       0x50100400  /* 256 B UART0 RX ring & state */
#define BIOS_VIDEO_SYNC_BASE        0x50100500  /* 64 B Core 1 -> Core 0 sync */
#define BIOS_MISC_STATE_BASE        0x50100540  /* 192 B OS ecall ptr, SD/LED/piezo */
#define BIOS_DPRAM_FREE_BASE        0x50100600  /* 2,560 B unallocated headroom */

/* Named slots inside BIOS_VIDEO_SYNC_BASE (0x50100500) */
#define BIOS_VSYNC_COUNT_ADDR       0x50100500  /* uint32_t monotonic frame count */

/* Named slots inside BIOS_MISC_STATE_BASE (0x50100540) */
#define BIOS_OS_ECALL_HANDLER_ADDR  0x50100540  /* uint32_t fn ptr (0 = none) */

#endif /* OASIS32_BIOS_RAM_H */
