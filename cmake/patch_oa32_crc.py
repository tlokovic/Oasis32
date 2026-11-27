#!/usr/bin/env python3
"""Patch the IEEE 802.3 CRC-32 checksum into an Oasis32 (.oa32) disk image.

Header layout (packed 32-byte little-endian, include/abi/boot_header.h):
  0x00: magic        (uint32_t, 0x3233414F = "OA32")
  0x04: load_addr    (uint32_t)
  0x08: entry_addr   (uint32_t)
  0x0C: payload_size (uint32_t)
  0x10: crc32        (uint32_t, IEEE 802.3 CRC-32 over payload bytes)
  0x14: reserved     (12 bytes, zero)
  0x20: payload      (payload_size raw bytes)
"""

import struct
import sys
import zlib

BOOT_HEADER_SIZE = 32
BOOT_HEADER_MAGIC = 0x3233414F
BOOT_HEADER_OFF_CRC32 = 0x10


def patch_oa32(path: str) -> None:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    if len(data) < BOOT_HEADER_SIZE:
        sys.exit(
            f"error: {path} is too small ({len(data)} bytes < {BOOT_HEADER_SIZE})"
        )

    magic, _load_addr, _entry_addr, payload_size = struct.unpack_from(
        "<IIII", data, 0
    )
    if magic != BOOT_HEADER_MAGIC:
        sys.exit(
            f"error: {path} bad magic 0x{magic:08X} (expected 0x{BOOT_HEADER_MAGIC:08X})"
        )

    actual_payload_size = len(data) - BOOT_HEADER_SIZE
    if payload_size != actual_payload_size:
        sys.exit(
            f"error: {path} payload_size mismatch "
            f"(header={payload_size}, file={actual_payload_size})"
        )

    crc = zlib.crc32(data[BOOT_HEADER_SIZE:]) & 0xFFFFFFFF
    struct.pack_into("<I", data, BOOT_HEADER_OFF_CRC32, crc)

    with open(path, "wb") as f:
        f.write(data)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <image.oa32>")
    patch_oa32(sys.argv[1])


if __name__ == "__main__":
    main()
