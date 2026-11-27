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
 * Scratchpad Bank 8 (4 KB, non-striped): Core 0 BIOS Boot & IRQ Stacks
 *   - 0x20080000-0x20080BFF (3 KB): Core 0 foreground BIOS/boot-menu stack
 *   - 0x20080C00-0x20080FFF (1 KB): Core 0 private IRQ stack (mscratch)
 * Keeping these disjoint ensures Core 0 IRQs never clobber foreground BIOS
 * frames (e.g. hardware_demo / boot menu) before a Stage-2 payload runs.
 * ---------------------------------------------------------------------------- */
#define BIOS_SCRATCH8_BASE          0x20080000
#define BIOS_SCRATCH8_SIZE          0x00001000
#define BIOS_CORE0_STACK_TOP        0x20080C00  /* Loaded into sp at boot */
#define BIOS_CORE0_IRQ_STACK_TOP    0x20081000  /* Loaded into mscratch for IRQs */

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
/* Planned (BIOS_BLK_TEXT): 0x50100504 uint32_t packed cursor state
 *   [blink_frames:8 | visible:8 | row:8 | col:8] — single-word atomic sw/lw
 *   between Core 0 (BIOS_TEXT_* syscalls) and Core 1 (VBLANK latch). */

/* Named slots inside BIOS_MISC_STATE_BASE (0x50100540) */
#define BIOS_OS_ECALL_HANDLER_ADDR  0x50100540  /* uint32_t fn ptr (0 = none) */
#define BIOS_SD_FLAGS_ADDR          0x50100544  /* uint32_t SD_STATUS_READY|SDHC */
#define BIOS_SD_SECTORS_ADDR        0x50100548  /* uint32_t total 512-B sectors */
#define BIOS_SD_CD_STABLE_ADDR      0x5010054C  /* uint32_t debounced CD (0/1) */
#define BIOS_SD_CD_LAST_RAW_ADDR    0x50100550  /* uint32_t last raw CD (0/1) */
#define BIOS_SD_CD_CHANGE_US_ADDR   0x50100554  /* uint32_t last raw CD edge us */

#endif /* OASIS32_BIOS_RAM_H */
