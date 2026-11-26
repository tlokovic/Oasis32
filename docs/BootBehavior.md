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
3. **Interactive Boot Menu, SD Bootloader & Serial Loader:**
   * Present an interactive boot menu (initially over `UART0`; later in DVI text mode) allowing the user to boot from an SD card (`ENTER`), boot a Base64-encoded disk image streamed directly into SRAM over `UART0` (`1`), write a Base64-encoded disk image received over `UART0` to an SD card (`2`), or run the built-in hardware demo (`3`).
   * Detect an inserted SD card (`GP6`), perform the SPI initialization handshake, read and validate the packed 16-byte `"OA32"` **Boot Image Header**, copy the **Boot Payload** into User SRAM, synchronize the instruction stream (`fence.i`), and jump to the payload's entry point.

### 3.3 Stable ROM ABI (Application Binary Interface)
Because software on SD cards is assembled and linked independently of the System ROM, it must be able to call resident BIOS routines without breaking if the System ROM is ever updated or bug-fixed. Oasis32 decouples callers from Flash addresses using a RISC-V **`ecall` trap dispatcher** (`a7` service ID, `a0–a5` arguments, `a0` return value). For the complete privilege, interrupt, and `ecall` runtime contract, see [ExecutionModel.md](ExecutionModel.md).

### 3.4 Bootable Disk Image Format
Oasis32 uses a single, uniform binary **Disk Image Format** both when stored raw on an SD card (starting at **LBA 0**) and when transmitted over the serial port (`UART0`) in standard **Base64** encoding.

The image begins with a **packed 16-byte little-endian Boot Image Header**, followed immediately by the raw payload bytes at offset `0x10` (`16`):

| Offset | Size | Field | Encoding / Description |
|:---:|:---:|:---|:---|
| `0x00` | 4 bytes | `magic` | 4 ASCII bytes `"OA32"` (`0x4F, 0x41, 0x33, 0x32` in byte order; `0x3233414F` as a little-endian 32-bit word). Identifies a valid Oasis32 disk image. |
| `0x04` | 4 bytes | `load_addr` | 32-bit little-endian SRAM address where payload byte 0 is copied (must lie within User SRAM). |
| `0x08` | 4 bytes | `entry_addr` | 32-bit little-endian SRAM address to jump to when booting (must lie within User SRAM). |
| `0x0C` | 4 bytes | `payload_size` | 32-bit little-endian payload length in bytes (total disk image size minus the 16-byte header). `load_addr + payload_size` must lie within User SRAM. |
| `0x10` | `payload_size` bytes | `payload` | Raw Stage-2 payload bytes. On SD cards, the first up to 496 bytes share LBA 0 with the header, and subsequent bytes continue contiguously across LBA 1, LBA 2, etc. (trailing bytes in the final 512-byte sector are zero-padded when written). |

### 3.5 Startup Boot Menu & Serial Transfer Workflow
Because text-mode font rendering on DVI is not yet implemented in the initial System ROM, the startup boot menu operates over the debug serial port (`UART0`, 115,200 baud 8N1). Once DVI text-mode rendering is added later, the same menu workflow will transition to the DVI display.

On power-up or reset, after completing hardware initialization (POST), the System ROM prints a splash message followed by the boot menu:

```text
 - ENTER to boot from SD Card
 - 1 to boot from disk image read from serial
 - 2 to write disk image read from serial
 - 3 to run a hardware demo
```

#### Menu Options
* **`ENTER` — Boot from SD Card:**
  * Checks SD card presence via `GP6` (`CD`). If no card is inserted, prints `"Insert boot disk"` and waits until a card is inserted.
  * Initializes the SD card over `SPI0`, reads LBA 0, and validates the 16-byte `"OA32"` header (`magic`, `load_addr`, `entry_addr`, and `payload_size` bounds within User SRAM).
  * Copies the payload bytes (starting at byte offset `16` of LBA 0, then continuing across LBA 1..N) to `load_addr`, executes `fence.i`, and jumps to `entry_addr`.
* **`1` — Boot from Disk Image Read from Serial (RAM-Only):**
  * Reads a Base64-encoded disk image from `UART0` (ignoring whitespace/newlines, decoding the 16-byte header first to learn `payload_size`, and stopping automatically once all `16 + payload_size` decoded bytes have been received).
  * Validates the header, copies the payload directly into `load_addr` in User SRAM **without writing to the SD card**, executes `fence.i`, and jumps to `entry_addr`.
  * Supports rapid host-to-target edit-assemble-test iteration with zero SD card swapping or wear.
* **`2` — Write Disk Image Read from Serial to SD Card:**
  * Checks SD card presence via `GP6` (`CD`). If no card is inserted, prints `"Insert disk to write"` and waits until a card is inserted.
  * Reads and decodes the Base64-encoded disk image from `UART0` into a **User SRAM staging buffer first**, validates the 16-byte `"OA32"` header, and only then writes the raw image (header + payload, zero-padding the tail of the final 512-byte sector) to the SD card starting at LBA 0.
  * *Why buffer in SRAM first?* `UART0` has no hardware flow control (`CTS`/`RTS`) and only a 32-byte RX FIFO, whereas an SD card flash write (`CMD24`) can stall for 10–250 ms. Buffering the complete decoded image in User SRAM before touching the SD card completely eliminates UART FIFO overrun risk for all bootable images that fit in User SRAM.
  * Once the write completes, returns to the boot menu (or equivalently resets).
* **`3` — Run Built-In Hardware Demo:**
  * Launches the Flash-resident hardware demo (`hardware_demo`), which exercises all hardware subsystems (serial, timer, LEDs, piezo buzzer, keyboard/mouse, SD card, and DVI video) strictly through the public BIOS `ecall` ABI (`include/abi/`).
  * Provides rapid on-device diagnostics and regression testing of every BIOS subsystem without requiring an SD card or serial transfer—particularly useful during BIOS cleanups and refactorings. Runs until Reset.

#### Validation & Error Recovery
If any boot or transfer path encounters an error—such as an invalid `"OA32"` magic number, a `load_addr`/`entry_addr`/`payload_size` outside User SRAM, malformed Base64 input, or an SD I/O failure—the System ROM prints a descriptive error message and returns to the boot menu.

### 3.6 Bootable Disk Images / Stage-2 Payloads
Any software written to an SD card—ranging from tiny standalone graphics demos and games to a full operating system kernel, filesystem, and interactive shell.

* **SRAM Execution:** Payloads are linked to execute from User SRAM (`0x2000_0000`–`0x2007_FFFF`, excluding the BIOS-reserved region). Because the bootloader writes the payload's machine code into SRAM via data stores before jumping to it, the bootloader executes RISC-V's `fence.i` instruction prior to transfer so the instruction fetch pipeline observes the newly written instructions.
* **Development Workflow:** To run new software on the computer, assemble and link a payload targeting User SRAM on a host machine, prepend the 16-byte `"OA32"` Boot Image Header, Base64-encode the resulting image, and send it over `UART0`—using menu option `1` for instant RAM-only testing or menu option `2` to write a persistent boot disk onto an SD card.

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

