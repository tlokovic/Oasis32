/*
 * ============================================================================
 * Oasis32 Public ABI — Bootable Disk Image Header ("OA32")
 * ============================================================================
 * Packed 16-byte little-endian header placed at LBA 0 (offset 0x00) of a
 * bootable SD card image or at the start of a Base64-encoded serial image.
 * Raw payload bytes begin immediately at offset 0x10 (16).
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Reference: docs/BootBehavior.md §3.4
 * ============================================================================
 */

#ifndef OASIS32_ABI_BOOT_HEADER_H
#define OASIS32_ABI_BOOT_HEADER_H

/* Magic word: ASCII "OA32" (bytes 0x4F, 0x41, 0x33, 0x32 little-endian) */
#define BOOT_HEADER_MAGIC           0x3233414F

/* Packed header size and byte offsets */
#define BOOT_HEADER_SIZE            16
#define BOOT_HEADER_OFF_MAGIC       0x00    /* uint32_t: BOOT_HEADER_MAGIC */
#define BOOT_HEADER_OFF_LOAD_ADDR   0x04    /* uint32_t: SRAM destination */
#define BOOT_HEADER_OFF_ENTRY_ADDR  0x08    /* uint32_t: SRAM entry point */
#define BOOT_HEADER_OFF_PAYLOAD_SZ  0x0C    /* uint32_t: payload byte length */
#define BOOT_HEADER_OFF_PAYLOAD     0x10    /* start of raw payload bytes */

/* Number of payload bytes sharing LBA 0 with the 16-byte header (512 - 16) */
#define BOOT_HEADER_LBA0_PAYLOAD_MAX 496

#endif /* OASIS32_ABI_BOOT_HEADER_H */
