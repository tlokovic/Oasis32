# Oasis32 — System Architecture

## 1. Philosophy: A "Boot from Removable Disk" Computer

**Oasis32** (the Pico 2 Desert Island Computer) is designed in the tradition of classic microcomputers (such as the IBM PC, CP/M machines, and the Commodore 64): it is a **"boot from removable disk" computer** with **no built-in operating system**.

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
3. **SD Bootloader (Chainloader):**
   * Detect an inserted SD card (`GP6`), perform the SPI initialization handshake, read and validate the **Boot Image Header**, copy the **Boot Payload** from the SD card into SRAM, synchronize the instruction stream (`fence.i`), and jump to the payload's entry point.

### 3.3 Stable ROM ABI (Application Binary Interface)
Because software on SD cards is assembled and linked independently of the System ROM, it must be able to call resident BIOS routines without breaking if the System ROM is ever updated or bug-fixed. A **Stable ROM ABI** decouples callers from internal ROM addresses using a fixed contract (such as a fixed-address Jump Table or a RISC-V `ecall` trap dispatcher—see [Open Questions](#5-open-questions)).

### 3.4 Boot Sector / Boot Image Header (SD Card)
Bootable SD cards carry a small, structured **Boot Image Header** at a well-known block location (typically **LBA 0**, the first 512-byte sector). Conceptually, this header describes how the bootloader should load and launch the disk:

* **Magic Number / Signature:** Identifies the SD card as a valid Oasis32 boot disk (preventing the bootloader from executing unformatted or non-bootable cards).
* **Header Version / Flags:** Allows future format extensions while maintaining backward compatibility.
* **Load Address:** Target address in SRAM (`0x2000_0000`–`0x2007_FFFF`) where the payload will be copied (or a fixed conventional load address).
* **Payload Size:** Number of bytes or 512-byte sectors to read from subsequent LBAs on the SD card.
* **Entry Point:** The SRAM address to which the bootloader transfers execution after loading completes.
* **Checksum / CRC *(optional)*:** Verifies payload integrity before transferring control.

### 3.5 Bootable Disk Images / Stage-2 Payloads
Any software written to an SD card—ranging from tiny standalone graphics demos and games to a full operating system kernel, filesystem, and interactive shell.

* **SRAM Execution:** Payloads are linked to execute from SRAM (`0x2000_0000`–`0x2007_FFFF`). Because the bootloader writes the payload's machine code into SRAM via data stores before jumping to it, the bootloader executes RISC-V's `fence.i` instruction prior to transfer so the instruction fetch pipeline observes the newly written instructions.
* **Development Workflow:** To run new software on the computer, you assemble/link a payload targeting SRAM on a host machine, prepend the Boot Image Header to produce a disk image, write it to an SD card, insert the card into the Pico 2, and press Reset.

---

## 4. Separation of Firmware and Software

This architecture establishes a clean boundary between two distinct layers of the project:

* **System ROM (BIOS & Bootloader) — Flash-Resident:** Stable, minimal, hardware-facing firmware. Changes infrequently once validated.
* **Boot Disks (Demos, Games, Monitor, OS) — SD-Card-Resident:** Rapidly iterable, swappable software that relies on the System ROM's BIOS ABI (or optionally takes direct control of hardware when desired).

---

## 5. Open Questions

The following architectural decisions are intentionally deferred and will be resolved during System ROM design:

1. **No-Card / Invalid-Disk Fallback Behavior:**
   What should the System ROM do on power-up or reset if no SD card is inserted, or if the inserted card does not contain a valid Boot Image Header?
   * *Option A:* Display a status screen/prompt (e.g., `"Insert Boot Disk"`) on DVI and `UART0` and poll until a valid card is inserted.
   * *Option B:* Drop into a minimal built-in ROM Monitor (over `UART0` and/or DVI) for diagnostics, memory inspection, or manual boot retry.
   * *Option C:* A combination of both (e.g., prompt for a boot disk with a keypress option to enter a minimal ROM monitor).

2. **Resident BIOS Calling Mechanism (ROM ABI):**
   How should SRAM-loaded payloads invoke the resident BIOS routines in XIP Flash?
   * *Option A — Fixed Jump Table (Vector Table):* A table of jump instructions at a fixed, well-known flash address (similar to the Commodore 64 KERNAL or CP/M BIOS). Simple, zero trap overhead, and direct `jal` calls.
   * *Option B — `ecall` Trap / Syscall Interface:* Callers place a service ID in a register and execute RISC-V `ecall`, trapping into a single ROM dispatcher (similar to PC BIOS `INT` services or RISC-V SBI). Cleanly supports privilege separation later if desired, with slightly more dispatch overhead.

3. **Host-to-SD-Card Workflow During Cross-Development:**
   Until the computer's own OS is mature enough for self-hosted development ("true desert island" mode), software will be cross-assembled on Windows and written to SD cards that do **not** use FAT32 (since designing a custom filesystem is part of the project). How should assembled images be transferred onto raw SD cards?
   * *Option A — Raw Block Imaging on Windows (Card Reader):* Assemble the payload and prepend the Boot Image Header into a flat `.img` file on Windows, then write raw sectors directly to the SD card via an elevated imaging tool or script (targeting `\\.\PhysicalDriveN`, e.g., `dd` for Windows, Win32DiskImager, or a custom Python/PowerShell script). Fast for large images and requires zero extra BIOS code, at the cost of physically swapping cards, needing Administrator privileges, guarding against targeting the wrong drive, and dismissing Windows "format disk" prompts.
     * *Refinement (MBR Wrapper):* Optionally placing a minimal MBR partition table at LBA 0 (marking our custom region with a non-Windows partition type) can prevent Windows from nagging to format the card while still leaving the filesystem 100% custom.
   * *Option B — Serial Disk-Writer Mode in BIOS over `UART0` (CP2102N):* Boot Oasis32 into a special BIOS transfer mode (our own "BOOTSEL over serial") that receives data over the `UART0` debug port and writes it directly to the SD card—eliminating physical card swapping altogether. Framing choices include:
     * *ASCII Text Encoding (Base64, Intel HEX, or Motorola S-Record):* Requires no custom host sender—encoded output (e.g., from `objcopy -O ihex` or a Base64 encoder) can be pasted or piped straight into a terminal like PuTTY. Intel HEX/S-Record also provide built-in per-line checksums.
     * *Standard Serial Protocol (XMODEM / YMODEM):* Packetized binary transfer with built-in CRCs and retransmission, natively supported by common serial terminals (e.g., Tera Term) and simple host scripts.
     * *Custom Framed Binary Protocol + Host Script:* A small Windows script (e.g., Python `pyserial`) sends length-prefixed, CRC-checked blocks directly from the build step—fastest over UART (especially if `UART0` is run above 115,200 baud).
   * *Option C — Hybrid Serial "Load-to-SRAM + Optional Commit-to-SD":* An extension of Option B where the BIOS serial loader can stream a program straight into SRAM and run it immediately for rapid edit-assemble-test cycles (with zero SD card wear), and only write the image to the SD card when ready to make a persistent boot disk.
   * *Option D — Minimal BIOS RAM-Loader + On-Demand Disk-Writer Utility:* Keep the flash-resident BIOS as small as possible by including only a tiny serial-to-SRAM loader (no SD-write logic in flash); when you want to populate an SD card, first push a standalone disk-writer utility into SRAM over `UART0`, then use it to write the target disk image to the SD card.

