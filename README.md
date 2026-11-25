# Oasis32 — RISC-V Fantasy Retro Computer

![Assembled Left Side](images/assembled_left_side.jpg)
![Assembled Left Side](images/assembled_right_side.jpg)

## Overview

**Oasis32** is a 32-bit "fantasy retro" computer that combines the simple hardware interfaces
of 80's computers with modern affordances so that it's actually fun to program.

From retro computers, we get simple memory-mapped hardware that does not require third-party drivers, libraries, or SDKs. We also get a complete Programmers Reference Manual that fully
describes the behaviors and interfaces of the system for programmers.

From the modern age, we get the RISC-V instruction set, HDMI, SD Card removable storage, USB keyboard/mouse, and USB serial for talking to modern computers. The system has 520KB of
RAM, most of which is available to user code.

The result is a well-documented foundation that can be programmed from the ground up with zero third-party code. The goal is *not* to converge on existing standards such as C, Posix, UNIX, and FAT32, but rather to develop an "alternate history" tech stack that relies as little as possible on outside standards or libraries.

## Features

* **Bare-Metal 32-Bit RISC-V Architecture:** Powered by an RP2350 Hazard3 RISC-V core at 126 MHz with **464 KB of contiguous User SRAM** (plus 44 KB of directly accessible video memory), running in a flat, transparent single-core execution model with zero third-party SDKs, drivers, or libraries.
* **640×480 @ 60 Hz Monochrome HDMI Display (Dedicated Video Coprocessor):**
  * RP2350 Core 1 acts as a permanent, hidden **Video Coprocessor (PPU/CRTC)** driving HSTX DVI output with **0% video overhead** on the main CPU.
  * **Unified Graphics + Text Overlay (No Mode Switching):** Combines a `640×480` 1 bpp monochrome framebuffer (`38.4 KB`) with an `80×60` character text buffer (`4.8 KB`) and a **user-modifiable 256-glyph `8×8` font in RAM** (`2 KB`), composited live on every scanline via bitwise `OR`. Zeroing the text buffer yields pure graphics; zeroing the framebuffer yields pure 80×60 text; using both gives a non-destructive text overlay.
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
*  For the internal Flash and 520 KB SRAM layout, see [Memory Map](docs/MemoryMap.md).

## Development Status

Hardware has been designed, built, and tested with both
[C++](test_harness/cpp) and [RISC-V Assembly](test_harness/asm) test
harnesses. BIOS and ABI design are in progress.

For more detailed roadmap and status, see [Roadmap](ROADMAP.md).
