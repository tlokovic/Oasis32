/*
 * ============================================================================
 * Oasis32 Public ABI — Bootable Disk Image Header ("OA32")
 * ============================================================================
 * Packed 32-byte little-endian header placed at LBA 0 (offset 0x00) of a
 * bootable SD card image or at the start of a raw binary serial image.
 * Raw payload bytes begin immediately at offset 0x20 (32).
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
#define BOOT_HEADER_SIZE            32
#define BOOT_HEADER_OFF_MAGIC       0x00    /* uint32_t: BOOT_HEADER_MAGIC */
#define BOOT_HEADER_OFF_LOAD_ADDR   0x04    /* uint32_t: SRAM destination */
#define BOOT_HEADER_OFF_ENTRY_ADDR  0x08    /* uint32_t: SRAM entry point */
#define BOOT_HEADER_OFF_PAYLOAD_SZ  0x0C    /* uint32_t: payload byte length */
#define BOOT_HEADER_OFF_CRC32       0x10    /* uint32_t: IEEE 802.3 CRC-32 of payload */
#define BOOT_HEADER_OFF_RESERVED    0x14    /* 12 bytes: reserved (zero in ABI 0.1.0) */
#define BOOT_HEADER_OFF_PAYLOAD     0x20    /* start of raw payload bytes */

/* Number of payload bytes sharing LBA 0 with the 32-byte header (512 - 32) */
#define BOOT_HEADER_LBA0_PAYLOAD_MAX 480

#endif /* OASIS32_ABI_BOOT_HEADER_H */
