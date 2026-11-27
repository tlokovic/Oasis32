# Oasis32 — Boot Behavior

## 1. Philosophy: A "Boot from Removable Disk" Computer

**Oasis32** is designed in the tradition of classic microcomputers (such as the IBM PC, CP/M machines, and the Commodore 64): it is a **"boot from removable disk" computer** with **no built-in operating system**.

Rather than flashing a monolithic OS into the Pico 2's onboard flash memory, the onboard flash holds only a compact, permanent **System ROM (BIOS & Bootloader)**. Once this System ROM stabilizes, the Pico 2 rarely—or never—needs to be re-flashed over USB in `BOOTSEL` mode. Instead, what the computer does on power-up or reset is determined entirely by the **boot disk** inserted into the SD card slot.

Programming and using the machine becomes a matter of populating SD cards with standalone demos, games, hardware utilities, or full operating systems, inserting a card, and pressing the Reset button.

---

## 2. Two-Stage Boot Chain & Memory Architecture

The RP2350 already contains an immutable silicon Boot ROM, so our architecture forms a clean multi-stage boot chain across three distinct memory regions:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ Stage 0: RP2350 Silicon Boot ROM         0x0000_0000 – 0x0000_7FFF     │
│ (32 KB immutable mask ROM)                                             │
│   • Handles USB BOOTSEL (UF2 flashing)                                 │
│   • Scans external flash for a valid PICOBIN IMAGE_DEF block           │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ Jumps to Flash entry point
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Stage 1: System ROM / BIOS               0x1000_0000+ (XIP Flash)      │
│ (Flashed once via UF2; treated as immutable once stabilized)           │
│   1. Hardware Bring-Up (POST / Init): clocks, PLLs, resets, pads, I/O  │
│   2. Resident BIOS / HAL Services: reusable low-level hardware drivers │
│   3. SD Bootloader: reads Boot Header (LBA 0), copies payload to SRAM  │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ fence.i + jump to Entry Point
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Stage 2: Bootable Disk Payload           0x2000_0000 – 0x2007_FFFF     │
│ (Loaded into 512 KB Main SRAM, Banks 0–7; plus 8 KB Scratch Banks 8–9) │
│   • Standalone demo, game, monitor, or full OS kernel + shell          │
│   • Calls back into Stage 1's Resident BIOS ABI for hardware I/O       │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key RP2350 Physical Memory Regions

| Region | Physical Address Range | Size | Role in System Architecture | Datasheet Citation |
|:---|:---|:---:|:---|:---|
| **Silicon Boot ROM** | `0x0000_0000`–`0x0000_7FFF` | 32 KB | Immutable Stage-0 ROM built into RP2350 silicon. | `rp2350-datasheet.pdf §2.2.1, p. 26` |
| **XIP Cached Flash** | `0x1000_0000`–`0x13FF_FFFF` | 4 MB* | Hosts Stage-1 **System ROM / BIOS** (Execute-In-Place). | `rp2350-datasheet.pdf §2.2.2, p. 26` |
| **Main SRAM (Banks 0–7)** | `0x2000_0000`–`0x2007_FFFF` | 512 KB | Framebuffer, BIOS state, and Stage-2 **Boot Payloads**. | `rp2350-datasheet.pdf §4.2, p. 312` |
| **Scratchpad SRAM (Banks 8–9)** | `0x2008_0000`–`0x2008_1FFF` | 8 KB | Non-striped 4 KB scratchpad banks (e.g., per-core stacks). | `rp2350-datasheet.pdf §4.2, p. 312` |

*\*The RP2350 XIP window maps up to 64 MB; the Raspberry Pi Pico 2 board populates 4 MB of external QSPI flash.*

---

## 3. Architectural Components

### 3.1 Silicon Boot ROM (Stage 0)
The immutable 32 KB mask ROM inside the RP2350 (`rp2350-datasheet.pdf §2.2.1, p. 26`). It is responsible for low-level chip startup, `BOOTSEL` USB Mass Storage mode, and locating the `PICOBIN` `IMAGE_DEF` metadata block in external flash to launch our Stage-1 System ROM in Hazard3 RISC-V mode.

### 3.2 System ROM / BIOS Firmware (Stage 1)
Our permanent, bare-metal RISC-V assembly firmware stored in QSPI Flash and executed via Execute-In-Place (`XIP_BASE` = `0x1000_0000`). Like a classic **BIOS** (*Basic Input/Output System*), it has three responsibilities:

1. **Hardware Initialization (Bring-Up / POST):**
   * Configure the 12 MHz `XOSC` crystal, `PLL_SYS`, and system/peripheral clock multiplexers.
   * Deassert peripheral resets in `RESETS` and clear RP2350 pad isolation (`ISO`) bits in `PADS_BANK0`.
   * Initialize core peripherals: DVI/HSTX video output, `UART0` (debug serial), `UART1` (CH9350 keyboard/mouse), `SPI0` (SD card), `PWM` (piezo buzzer), `TIMER0`, and status LEDs.
2. **Resident BIOS / HAL Services:**
   * Keep low-level hardware-access routines permanently resident in XIP Flash so that SD-loaded software does not need to re-implement drivers for the display, keyboard/mouse, SD block I/O, serial port, timer, buzzer, or LEDs.
3. **Startup Splash, Auto-Boot & Interactive Boot Menu:**
   * Display a 640×480 startup splash bitmap (framed by a 5-pixel white outer border to ensure reliable DVI monitor/capture-card signal lock-on), play the startup tune, and hold for 3 seconds.
   * Immediately check for an inserted SD card (`GP6`) with a valid packed 32-byte `"OA32"` **Boot Image Header** at LBA 0; if present and valid, automatically attempt to boot from it.
   * Otherwise (no disk inserted, invalid header, or boot error), present an interactive boot menu on the 80×60 DVI text display (controlled via USB keyboard) with live SD card/header status polling, allowing the user to boot from an SD card (`ENTER`), boot a raw binary `.oa32` disk image streamed directly into SRAM over `UART0` (`1`), write a raw binary `.oa32` disk image received over `UART0` to an SD card (`2`), or run the built-in hardware demo (`3`).
   * Perform the SD SPI initialization handshake, read and validate the packed 32-byte `"OA32"` **Boot Image Header**, copy the **Boot Payload** into User SRAM, verify its IEEE **CRC-32** checksum, synchronize the instruction stream (`fence.i`), and jump to the payload's entry point.

### 3.3 Stable ROM ABI (Application Binary Interface)
Because software on SD cards is assembled and linked independently of the System ROM, it must be able to call resident BIOS routines without breaking if the System ROM is ever updated or bug-fixed. Oasis32 decouples callers from Flash addresses using a RISC-V **`ecall` trap dispatcher** (`a7` service ID, `a0–a5` arguments, `a0` return value). For the complete privilege, interrupt, and `ecall` runtime contract, see [ExecutionModel.md](ExecutionModel.md).

### 3.4 Bootable Disk Image Format
Oasis32 uses a single, uniform raw binary **Disk Image Format** (`.oa32`) both when stored raw on an SD card (starting at **LBA 0**) and when transmitted raw over the serial port (`UART0`, 115,200 baud 8N1, no flow control).

The image begins with a **packed 32-byte little-endian Boot Image Header**, followed immediately by the raw payload bytes at offset `0x20` (`32`):

| Offset | Size | Field | Encoding / Description |
|:---:|:---:|:---|:---|
| `0x00` | 4 bytes | `magic` | 4 ASCII bytes `"OA32"` (`0x4F, 0x41, 0x33, 0x32` in byte order; `0x3233414F` as a little-endian 32-bit word). Identifies a valid Oasis32 disk image. |
| `0x04` | 4 bytes | `load_addr` | 32-bit little-endian SRAM address where payload byte 0 is copied (must lie within User SRAM). |
| `0x08` | 4 bytes | `entry_addr` | 32-bit little-endian SRAM address to jump to when booting (must lie within User SRAM). |
| `0x0C` | 4 bytes | `payload_size` | 32-bit little-endian payload length in bytes (total disk image size minus the 32-byte header). `load_addr + payload_size` must lie within User SRAM. |
| `0x10` | 4 bytes | `crc32` | 32-bit little-endian standard IEEE 802.3 CRC-32 (polynomial `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF`) computed over the `payload_size` raw payload bytes. |
| `0x14` | 12 bytes | `reserved` | Reserved for future header extensions; must be zero (`0x00`) in ABI `0.1.0`. |
| `0x20` | `payload_size` bytes | `payload` | Raw Stage-2 payload bytes. On SD cards, the first up to 480 bytes share LBA 0 with the header, and subsequent bytes continue contiguously across LBA 1, LBA 2, etc. (trailing bytes in the final 512-byte sector are zero-padded when written). |

### 3.5 Startup Sequence, Boot Menu & Serial Transfer Workflow
The startup splash and interactive boot menu render directly on the 640×480 / 80×60 DVI display using the resident `BIOS_BLK_TEXT` and `BIOS_BLK_INPUT` (CH9350 USB keyboard) services, while raw `.oa32` disk image transfers (`1` and `2`) stream over the debug serial port (`UART0`, 115,200 baud 8N1).

#### Startup Splash & Automatic SD Boot
On power-up or reset, after completing hardware initialization (POST):
1. **Splash Screen:** The System ROM copies the embedded 640×480 splash bitmap into `FRAMEBUF` with a 5-pixel white outer border `(0,0)–(639,479)` (critical for reliable DVI monitor and capture-card active-frame lock-on), plays the startup tune on the piezo buzzer, holds the splash for 3 seconds, and clears `FRAMEBUF`.
2. **Automatic Boot Attempt:** Immediately after the splash screen, the System ROM checks SD card presence via `GP6` (`CD`).
   * If a disk is inserted, it initializes the card over `SPI0`, reads LBA 0, and validates the 32-byte `"OA32"` Boot Image Header (`magic`, `load_addr`, `entry_addr`, and `payload_size` bounds within User SRAM).
   * If the header is valid, the System ROM **immediately attempts to boot from the SD card** (copying the payload to `load_addr`, verifying `crc32`, executing `fence.i`, and jumping to `entry_addr`) without stopping at the menu.
   * If no disk is inserted, if the header is invalid, or if the automatic boot attempt fails (e.g., SD I/O error or CRC-32 mismatch), the System ROM falls through to the interactive boot menu.

#### Interactive Boot Menu & Live Disk Polling
When the boot menu is active, the System ROM displays the ROM version banner and four options on the 80×60 DVI text console:

```text
  [ENTER]  Boot from SD Card
  [1]      Boot from disk image read from serial
  [2]      Write disk image read from serial to SD Card
  [3]      Run built-in hardware demo
```

While waiting for keyboard input, the menu loop **frequently polls SD card presence (`GP6`)** and dynamically updates the menu display and option availability according to the current disk state:

| Disk State | `[ENTER]` Boot from SD Card | `[2]` Write Disk Image from Serial | Polling & Re-Evaluation Behavior |
|:---|:---|:---|:---|
| **No disk inserted** | Shown with `[disabled, no disk inserted]`; **disabled** (key ignored) | Shown with `[disabled, no disk inserted]`; **disabled** (key ignored) | Polls `GP6` frequently. As soon as a card is inserted, initializes the card, validates LBA 0's `"OA32"` header, and redraws the menu into one of the two inserted states below. |
| **Disk inserted, invalid header** | Shown with `[disabled, not a valid OA32 header]`; **disabled** (key ignored) | **Enabled** (no disabled suffix—allows writing a valid image onto a blank or non-OA32 card) | Polls `GP6` regularly, but **does not re-read LBA 0 while the card remains seated** (an invalid header will not change while sitting idle). Only updates if the disk is removed (or upon returning to the menu after option `2` writes a new image). |
| **Disk inserted, valid `"OA32"` header** | **Enabled** (no disabled suffix) | **Enabled** (no disabled suffix) | Polls `GP6` regularly; if the disk is removed, immediately redraws the menu into the *No disk inserted* state. |

#### Menu Options
* **`ENTER` — Boot from SD Card:**
  * Enabled only when a disk with a valid `"OA32"` header is inserted (otherwise disabled with `[disabled, no disk inserted]` or `[disabled, not a valid OA32 header]`).
  * Reads the payload bytes from the SD card (starting at byte offset `32` of LBA 0, then continuing across LBA 1..N) into `load_addr`, verifies the payload against `crc32`, executes `fence.i`, and jumps to `entry_addr`.
* **`1` — Boot from Disk Image Read from Serial (RAM-Only):**
  * Always enabled regardless of SD card state.
  * Prints `"Boot from serial: Transmit .oa32 file to boot from"` over `UART0`, then reads a raw binary `.oa32` disk image from `UART0` (reading the 32-byte header first to validate `magic` and bounds and learn `payload_size`, then streaming `payload_size` raw bytes directly into `load_addr` in User SRAM **without writing to the SD card**).
  * Supports cancelling before the first byte arrives (`ESC` / `Ctrl-C`, which never collides with byte 0 `'O'` = `0x4F`) and a mid-transfer stall timeout if the host stops sending mid-image.
  * Verifies the received payload against `crc32`, executes `fence.i`, and jumps to `entry_addr`.
  * Supports rapid host-to-target edit-assemble-test iteration with zero SD card swapping or wear.
* **`2` — Write Disk Image Read from Serial to SD Card:**
  * Enabled whenever an SD card is inserted, regardless of whether its current LBA 0 header is valid (disabled with `[disabled, no disk inserted]` when no card is present).
  * Prints `"Write SD card from serial: Transmit .oa32 file to write"` over `UART0`, then reads the raw binary `.oa32` disk image from `UART0` into a **User SRAM staging buffer first**, validates the 32-byte `"OA32"` header and verifies `crc32`, and only then writes the raw image (header + payload, zero-padding the tail of the final 512-byte sector) to the SD card starting at LBA 0.
  * *Why buffer in SRAM first?* `UART0` has no hardware flow control (`CTS`/`RTS`) and only a 32-byte RX FIFO, whereas an SD card flash write (`CMD24`) can stall for 10–250 ms. Buffering the complete image in User SRAM before touching the SD card completely eliminates UART FIFO overrun risk for all bootable images that fit in User SRAM.
  * Once the write completes, returns to the boot menu (re-evaluating the card's header so `[ENTER]` becomes enabled for the newly written disk) or equivalently resets.
* **`3` — Run Built-In Hardware Demo:**
  * Always enabled regardless of SD card state.
  * Launches the Flash-resident hardware demo (`hardware_demo`), which exercises all hardware subsystems (serial, timer, LEDs, piezo buzzer, keyboard/mouse, SD card, and DVI video) strictly through the public BIOS `ecall` ABI (`include/abi/`).
  * Provides rapid on-device diagnostics and regression testing of every BIOS subsystem without requiring an SD card or serial transfer—particularly useful during BIOS cleanups and refactorings. Runs until Reset.

#### Validation & Error Recovery
If any boot or transfer path—including post-splash automatic SD boot—encounters an error (such as an invalid `"OA32"` magic number, a `load_addr`/`entry_addr`/`payload_size` outside User SRAM, a CRC-32 mismatch, a serial transfer timeout, or an SD I/O failure), the System ROM prints a descriptive error message and returns to the boot menu.

### 3.6 Bootable Disk Images / Stage-2 Payloads
Any software written to an SD card—ranging from tiny standalone graphics demos and games to a full operating system kernel, filesystem, and interactive shell.

* **SRAM Execution:** Payloads are linked to execute from User SRAM (`0x2000_0000`–`0x2007_FFFF`, excluding the BIOS-reserved region). Because the bootloader writes the payload's machine code into SRAM via data stores before jumping to it, the bootloader executes RISC-V's `fence.i` instruction prior to transfer so the instruction fetch pipeline observes the newly written instructions.
* **Development Workflow:** To run new software on the computer, assemble and link a payload targeting User SRAM on a host machine (automatically emitting the 32-byte `"OA32"` Boot Image Header with its patched CRC-32), and stream the raw `.oa32` binary over `UART0` (e.g., via Tera Term `Send file...` in Binary mode or a host serial tool)—using menu option `1` for instant RAM-only testing or menu option `2` to write a persistent boot disk onto an SD card.

---

## 4. Separation of Firmware and Software

This architecture establishes a clean boundary between two distinct layers of the project:

* **System ROM (BIOS & Bootloader) — Flash-Resident:** Stable, minimal, hardware-facing firmware. Changes infrequently once validated.
* **Boot Disks (Demos, Games, Monitor, OS) — SD-Card-Resident:** Rapidly iterable, swappable software that interacts with the machine strictly through the System ROM's BIOS ABI.

---

## 5. Repository Structure & Representational Foundation

To enforce the boundary between the Flash-resident System ROM and SD-card-resident software, the codebase is organized into a **two-layer include model** backed by build-system visibility rules.

### 5.1 Directory Layout

```text
Oasis32/
├── cmake/
│   └── oasis32.cmake            # Shared bare-metal & .ld.S preprocessing helpers
├── include/                     # PUBLIC ABI (visible to both bios/ and disks/)
│   ├── abi/
│   │   ├── memory_map.h         # Flash/SRAM regions, BIOS vs. User SRAM boundary
│   │   ├── boot_header.h        # LBA 0 Boot Image Header magic, offsets, flags
│   │   ├── bios_abi.h           # ABI entry point, service IDs / vectors, error codes
│   │   └── devices.h            # Public device constants (display geometry, HID, LEDs)
│   └── ld/
│       └── sd_payload.ld.S      # Shared linker script template for SD payloads
├── bios/                        # Stage-1 System ROM (Flash-resident)
│   ├── CMakeLists.txt
│   ├── internal/                # PRIVATE TO BIOS (never exposed to disks/)
│   │   ├── hw/                  # RP2350 silicon register maps & Oasis32 pin wiring
│   │   ├── bios_ram.h           # Private BIOS SRAM buffers, driver state, DMA blocks
│   │   ├── bios_flash.h         # PICOBIN IMAGE_DEF & internal ROM layout
│   │   └── bios_config.h        # Clock/PLL tuning, UART divisors, DMA channel map
│   ├── ld/
│   │   └── bios.ld.S            # BIOS linker script template
│   └── src/                     # Modular BIOS .S source files
└── disks/                       # Stage-2 Bootable SD-Card Payloads
    └── ...
```

*(Note: `test_harness/` from Phases 1–2 is preserved unmodified as a standalone hardware-verification reference.)*

### 5.2 Visibility Boundaries

* **Public ABI (`include/`):** Holds only the stable binary contract shared between Stage 1 (BIOS) and Stage 2 (SD payloads)—memory map boundaries, LBA 0 boot header layout, BIOS ABI entry points/service IDs, public device constants, and the shared SD payload linker template. Changes here are treated as breaking contracts.
* **BIOS Private (`bios/internal/`):** Holds all RP2350 silicon register definitions, Oasis32 board pin wiring (`hw/`), internal BIOS SRAM layouts, PICOBIN metadata, clock/PLL tuning, and DMA channel assignments. Keeping these strictly private ensures SD-card software hews exclusively to the published BIOS ABI and allows BIOS internals to be refactored without breaking existing boot disks.

### 5.3 Single Source of Truth Across Assembly & Linker Scripts

To avoid duplicating addresses or sizes between assembly sources and linker scripts:

* **Pure `#define` Headers (`.h`):** Shared constant headers contain only `#define` integer/hex expressions and `/* ... */` comments—no GAS `.equ` directives, no C types, and no integer suffixes like `U`/`UL` (which GNU `ld` rejects). Assembly-only helpers (such as GAS `.macro` wrappers) live in separate `.inc` files or are guarded with `#ifdef __ASSEMBLER__`.
* **Preprocessed Linker Scripts (`.ld.S`):** Both `bios/ld/bios.ld.S` and `include/ld/sd_payload.ld.S` are C-preprocessed into `.ld` files in the build directory at build time using the existing RISC-V toolchain (`riscv32-unknown-elf-gcc -E -P -x c`) with `-MD -MF` dependency files (`DEPFILE`) so edits to any included `.h` file automatically trigger re-preprocessing and relinking.

### 5.4 Build-Time Enforcement (`cmake/oasis32.cmake`)

A shared CMake helper module enforces the architectural boundary mechanically:

* Exposes `include/abi/` via a header-only `INTERFACE` target (`oasis32_abi`).
* Grants `bios/` access to both `oasis32_abi` and its own `PRIVATE` `bios/internal/` include path.
* Grants `disks/` targets access **only** to `oasis32_abi` and the shared preprocessed `sd_payload.ld`, so any accidental attempt by SD-card code to include a BIOS-private or raw hardware header fails at build time.

