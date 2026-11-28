#!/usr/bin/env python3
"""Send an Oasis32 (.oa32) disk image over UART0 (115200 8N1, no flow control).

Auto-detects the Silicon Labs CP2102N USB-to-UART bridge (VID 0x10C4,
PID 0xEA60) via pyserial, or accepts an explicit --port / OASIS32_PORT override.

Usage:
    python send_oa32.py <image.oa32> [--port COM3] [--baud 115200]
"""

import argparse
import os
import struct
import sys
import time

BOOT_HEADER_SIZE = 32
BOOT_HEADER_MAGIC = 0x3233414F
CP210X_VID = 0x10C4
CP210X_PID = 0xEA60
DEFAULT_BAUD = 115200
CHUNK_SIZE = 4096


def _import_pyserial():
    try:
        import serial  # type: ignore
        from serial.tools import list_ports  # type: ignore
    except ImportError:
        sys.exit(
            "error: pyserial is not installed for this Python interpreter.\n"
            f"Install it with:\n  \"{sys.executable}\" -m pip install pyserial"
        )
    return serial, list_ports


def find_oasis32_port(list_ports, explicit_port: str | None) -> str:
    if explicit_port:
        return explicit_port

    env_port = os.environ.get("OASIS32_PORT")
    if env_port:
        return env_port

    ports = list(list_ports.comports())
    if not ports:
        sys.exit("error: no serial ports detected.")

    matches = [p for p in ports if p.vid == CP210X_VID and p.pid == CP210X_PID]
    if not matches:
        matches = [
            p for p in ports if "CP210" in (p.description or "").upper()
        ]

    if len(matches) == 1:
        port = matches[0]
        print(f"Auto-detected Oasis32 serial port: {port.device} ({port.description})")
        return port.device

    if len(matches) > 1:
        listing = "\n".join(f"  {p.device}: {p.description}" for p in matches)
        sys.exit(
            "error: multiple CP210x serial ports found. "
            f"Specify one with --port or OASIS32_PORT:\n{listing}"
        )

    listing = "\n".join(
        f"  {p.device}: {p.description} (VID={p.vid}, PID={p.pid})"
        for p in ports
    )
    sys.exit(
        "error: no Silicon Labs CP210x USB-to-UART bridge found.\n"
        f"Available ports:\n{listing}\n"
        "Specify a port manually with --port or OASIS32_PORT."
    )


def load_and_validate_oa32(path: str) -> tuple[bytes, int, int, int, int]:
    if not os.path.isfile(path):
        sys.exit(f"error: file not found: {path}")

    with open(path, "rb") as f:
        data = f.read()

    if len(data) < BOOT_HEADER_SIZE:
        sys.exit(
            f"error: {path} is too small ({len(data)} bytes < {BOOT_HEADER_SIZE})"
        )

    magic, load_addr, entry_addr, payload_size, crc32 = struct.unpack_from(
        "<IIIII", data, 0
    )
    if magic != BOOT_HEADER_MAGIC:
        sys.exit(
            f"error: {path} bad magic 0x{magic:08X} "
            f"(expected 0x{BOOT_HEADER_MAGIC:08X} 'OA32')"
        )

    actual_payload_size = len(data) - BOOT_HEADER_SIZE
    if payload_size != actual_payload_size:
        sys.exit(
            f"error: {path} payload_size mismatch "
            f"(header={payload_size}, file={actual_payload_size})"
        )

    return data, load_addr, entry_addr, payload_size, crc32


def send_image(path: str, port_arg: str | None, baud: int) -> None:
    serial, list_ports = _import_pyserial()
    data, load_addr, entry_addr, payload_size, crc32 = load_and_validate_oa32(path)
    port_name = find_oasis32_port(list_ports, port_arg)

    print(
        f"Sending {os.path.basename(path)} ({len(data)} bytes: "
        f"32 B header + {payload_size} B payload, "
        f"load=0x{load_addr:08X}, entry=0x{entry_addr:08X}, crc32=0x{crc32:08X}) "
        f"to {port_name} @ {baud} 8N1..."
    )

    try:
        with serial.Serial(
            port=port_name,
            baudrate=baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=1,
            write_timeout=10,
            xonxoff=False,
            rtscts=False,
            dsrdtr=False,
        ) as ser:
            ser.reset_input_buffer()
            ser.reset_output_buffer()

            start = time.monotonic()
            total = len(data)
            sent = 0
            while sent < total:
                chunk = data[sent : sent + CHUNK_SIZE]
                written = ser.write(chunk)
                if written is None or written <= 0:
                    sys.exit("error: serial write stalled.")
                sent += written
            ser.flush()
            elapsed = time.monotonic() - start
    except serial.SerialException as exc:
        sys.exit(f"error: could not write to {port_name}: {exc}")

    rate = (len(data) / elapsed) if elapsed > 0 else 0.0
    print(f"Sent {len(data)} bytes in {elapsed:.2f} s ({rate:.0f} B/s).")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Send an Oasis32 (.oa32) disk image over serial."
    )
    parser.add_argument("image", help="Path to the .oa32 disk image")
    parser.add_argument(
        "--port",
        default=None,
        help="Serial port (default: auto-detect CP2102N or $OASIS32_PORT)",
    )
    parser.add_argument(
        "--baud",
        type=int,
        default=DEFAULT_BAUD,
        help=f"Baud rate (default: {DEFAULT_BAUD})",
    )
    args = parser.parse_args()
    send_image(args.image, args.port, args.baud)


if __name__ == "__main__":
    main()
