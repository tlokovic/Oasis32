# Oasis32 — 32-bit RISC-V Retro-Inspired Computer

<img src="images/assembled_left_side.jpg" width="48%"> <img src="images/assembled_right_side.jpg" width="48%">

<img src="images/assembled_closeup_reset.jpg" width="48%"> <img src="images/assembled_closeup_power.jpg" width="48%">

## Overview

**Oasis32** is a complete retro-inspired computer built around a Raspberry Pi Pico 2. It provides video, keyboard, mouse, removable SD card storage, and more, all accessible through simple memory-mapped interfaces, with no complex protocols such as USB. The result is a computer that can be programmed 100% without third-party drivers, libraries, or SDKs, and can be understood top-to-bottom by a single person.

Oasis32 intentionally combines the simple architecture of a 1980s computer (single core, single thread, no memory protection) with modern affordances that make low-level programming actually fun (32-bit RISC-V instruction set, 520KB of RAM, elegant syscall ABIs).

The goal is *not* to converge on mainstream standards like C, POSIX, UNIX, or FAT32. Instead, Oasis32 is a foundation for exploring a from-scratch homebrew software stack, including custom BIOS, OS, filesystem, tools, and applications.

The system supports cross-assembling from modern hosts, but the long-term aspiration is a self-hosted machine that can be programmed entirely on its own.

## Features

* **Bare-Metal 32-Bit RISC-V Architecture:** Powered by an RP2350 Hazard3 RISC-V core at 126 MHz with **464 KB of contiguous User SRAM** (plus **48 KB** of directly accessible video memory = 512 KB total public Main SRAM), running in a flat, transparent single-core execution model with zero third-party SDKs, drivers, or libraries.
* **640×480 @ 60 Hz Monochrome HDMI Display (Dedicated Video Coprocessor):**
  * RP2350 Core 1 acts as a permanent, hidden **Video Coprocessor (PPU/CRTC)** driving HSTX DVI output with **0% video overhead** on the main CPU.
  * **Unified Graphics + Text Overlay (No Mode Switching):** Combines a `640×480` 1 bpp monochrome framebuffer (`38,400 B`) with an `80×60` character text buffer (`4,800 B`) and a **user-modifiable 256-glyph `8×8` font in RAM** (`2,048 B`), composited live on every scanline via bitwise `OR`. Zeroing the text buffer yields pure graphics; zeroing the framebuffer yields pure 80×60 text; using both gives a non-destructive text overlay.
  * **Hardware Sprite Engine:** **16 simultaneous masked `16×16` sprites** backed by **56 animation/tile patterns** in video RAM (with Sprite 0 conventionally serving as a floating hardware mouse cursor), supporting transparency masks, H/V flip, above/below-text layering, and frame-latched or dynamic raster updates with zero per-scanline flicker.
* **Permanent System ROM (BIOS) & Stable `ecall` Syscall ABI:**
  * Flash-resident BIOS isolates hardware details behind clean RISC-V `ecall` syscalls, giving disk-loaded software simple, address-independent access to:
    * **USB Keyboard & Mouse** (handled in silicon via a CH9350 HID-to-UART bridge—no software USB stack required)
    * **SD Card Storage** (raw 512-byte LBA block I/O with card-detect hot-swapping support)
    * **USB-C Serial Port** (presents to host PCs as a standard serial device usable from PuTTY or host scripts)
    * **Monotonic Microsecond Timer & VSYNC Frame Sync**
    * **Three User-Controllable Status LEDs** (Red, Green, Blue)
    * **Piezo Buzzer** (PWM tone generation)
* **Classic "Boot from Removable Disk" & Serial Development Workflow:**
  * **Boot from Removable SD Card:** No built-in OS—insert a card containing an `"OA32"` disk image and boot directly into demos, utilities, games, or a custom OS.
  * **Boot from Serial (RAM-Only):** Stream a Base64-encoded disk image over the USB-C serial port straight into RAM and execute immediately for rapid host-to-target iteration with zero SD card swapping or wear.
  * **Write SD Cards Over Serial:** Stream a Base64-encoded disk image over USB-C serial from the built-in boot menu to write persistent bootable SD cards directly on the machine.

## Documentation

*  For hardware details, see [Hardware](docs/Hardware.md).
*  For boot behavior, see [Booting Behavior](docs/BootBehavior.md).
*  For execution, interrupt, and `ecall` ABI design, see [Execution Model](docs/ExecutionModel.md).
*  For the Core 1 Video Coprocessor, framebuffer, and text overlay design, see [Video Architecture](docs/VideoArchitecture.md).
*  For the internal Flash and RAM layout, see [Memory Map](docs/MemoryMap.md).

## Development Status

Hardware has been designed, built, and tested with both
[C++](test_harness/cpp) and [RISC-V Assembly](test_harness/asm) test
harnesses. BIOS and ABI design are in progress.

For more detailed roadmap and status, see [Roadmap](ROADMAP.md).
