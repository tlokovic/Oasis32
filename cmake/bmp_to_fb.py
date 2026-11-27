#!/usr/bin/env python3
"""Convert a 640x480 1-bit uncompressed BMP into an Oasis32 raw framebuffer.

Oasis32 FRAMEBUF format (docs/VideoArchitecture.md, include/abi/memory_map.h):
  - Resolution : 640 x 480 pixels (1 bpp, 80 bytes/row, 38,400 bytes total)
  - Row order  : Top-down (y = 0 at offset 0, y = 479 at offset 38,320)
  - Bit order  : LSB-left (bit 0 = leftmost pixel x = 0, bit 7 = x = 7)
  - Polarity   : 1 = white (lit), 0 = black (dark)

Standard 1-bit Windows BMP stores pixels MSB-left, may be bottom-up (biHeight > 0)
or top-down (biHeight < 0), and may order its 2-color palette either [black, white]
or [white, black]. This script normalizes all three into native Oasis32 format.
"""

import struct
import sys

FB_WIDTH = 640
FB_HEIGHT = 480
FB_STRIDE = FB_WIDTH // 8
FB_SIZE = FB_STRIDE * FB_HEIGHT


def _make_lut(invert: bool) -> bytes:
    """Build 256-byte lookup table: optional invert + MSB-left -> LSB-left."""
    table = bytearray(256)
    for val in range(256):
        b = (val ^ 0xFF) if invert else val
        rev = 0
        for bit in range(8):
            if b & (1 << bit):
                rev |= 1 << (7 - bit)
        table[val] = rev
    return bytes(table)


def convert_bmp_to_fb(src_path: str, dst_path: str) -> None:
    with open(src_path, "rb") as f:
        data = f.read()

    if len(data) < 54 or data[0:2] != b"BM":
        sys.exit(f"error: {src_path} is not a valid BMP file")

    (pixel_offset,) = struct.unpack_from("<I", data, 10)
    (dib_size,) = struct.unpack_from("<I", data, 14)
    if dib_size < 40 or len(data) < 14 + dib_size + 8:
        sys.exit(f"error: {src_path} has unsupported DIB header size ({dib_size})")

    width, height, planes, bpp, compression = struct.unpack_from(
        "<iiHHI", data, 18
    )

    abs_height = abs(height)
    if width != FB_WIDTH or abs_height != FB_HEIGHT:
        sys.exit(
            f"error: {src_path} dimensions {width}x{abs_height} "
            f"(expected {FB_WIDTH}x{FB_HEIGHT})"
        )
    if planes != 1 or bpp != 1 or compression != 0:
        sys.exit(
            f"error: {src_path} must be 1-bit uncompressed BMP "
            f"(got planes={planes}, bpp={bpp}, compression={compression})"
        )

    # 2-entry BMP palette immediately follows the DIB header (B, G, R, reserved)
    pal_off = 14 + dib_size
    b0, g0, r0, _a0, b1, g1, r1, _a1 = struct.unpack_from("<BBBBBBBB", data, pal_off)
    lum0 = r0 + g0 + b0
    lum1 = r1 + g1 + b1
    invert = lum0 > lum1

    bmp_stride = ((width + 31) // 32) * 4
    needed = pixel_offset + bmp_stride * abs_height
    if len(data) < needed:
        sys.exit(
            f"error: {src_path} truncated ({len(data)} bytes < {needed} required)"
        )

    lut = _make_lut(invert)
    row_indices = (
        range(abs_height - 1, -1, -1) if height > 0 else range(abs_height)
    )

    out = bytearray(FB_SIZE)
    dst_off = 0
    for row in row_indices:
        src_off = pixel_offset + row * bmp_stride
        out[dst_off : dst_off + FB_STRIDE] = data[
            src_off : src_off + FB_STRIDE
        ].translate(lut)
        dst_off += FB_STRIDE

    with open(dst_path, "wb") as f:
        f.write(out)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input.bmp> <output.bin>")
    convert_bmp_to_fb(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
