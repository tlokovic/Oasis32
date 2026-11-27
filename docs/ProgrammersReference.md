# Oasis32 Programmer's Reference

**System Architecture, Memory Map, Video Subsystem & Resident BIOS ABI Specification**

| | |
|:---|:---|
| **Target System** | Oasis32 32-bit RISC-V Microcomputer |
| **Declared ISA** | `RV32IMAC_Zifencei` (32-bit little-endian, nominal 126 MHz) |
| **Calling Convention** | RISC-V `ILP32` |
| **BIOS ABI Version** | `0.1.0` (`0x00000100`) |

This manual is the authoritative, self-contained specification for programming the **Oasis32** computer. It defines the machine model, memory map, bootable disk format, video memory layouts, and resident BIOS `ecall` services required to build standalone demos, games, utilities, and complete operating systems from bare-metal RISC-V assembly.

Everything a programmer needs—and is permitted—to rely on is specified within these pages and the accompanying public headers under `include/abi/`. Any hardware or firmware behavior not documented here is an internal implementation detail and must not be depended upon.

---

## Preface

### Purpose, Audience & Scope

This manual defines the complete technical contract between Oasis32's resident System ROM (BIOS) and software loaded onto the machine from an SD card or over the serial port.

**Audience.** It is written for programmers building bare-metal RISC-V software for Oasis32—ranging from small graphics demos, games, and hardware utilities to full operating systems, shells, filesystems, and language toolchains. Readers are assumed to be comfortable with basic RISC-V assembly, hexadecimal/binary arithmetic, and memory-mapped data structures.

**Scope.** This document specifies:
* The programmer-visible CPU architecture, execution rules, and memory map.
* The bootable disk image format, interactive bootloader user interface, and guaranteed machine state at program entry.
* The unified 640×480 display memory layouts (bitmap framebuffer, programmable font, text overlay, and hardware sprite engine).
* The `ecall` calling convention, error codes, OS syscall extension hook, and every resident BIOS service.
* Practical guidance for cross-compiling Oasis32 software on a host computer and deploying disk images over the serial port.
* Self-contained reference appendices for keycodes, character sets, BIOS services, and public ABI headers (`include/abi/`).

Internal System ROM implementation details, physical board wiring, and underlying peripheral controller registers are intentionally outside the scope of this manual. Software written strictly against the contracts defined here will remain portable across future System ROM revisions.

### External References

This manual is designed to be self-contained for all Oasis32-specific behavior—including memory layouts, display formats, keycodes, character sets, and BIOS services. For the underlying RISC-V instruction encodings and standard calling conventions, it defers **only** to two standard specifications:

1. **The RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture** — scoped strictly to Oasis32's declared ISA string, **`RV32IMAC_Zifencei`**:
   * **`RV32I`:** Base 32-bit integer instructions.
   * **`M`:** Standard integer multiplication and division (`mul`, `div`, `rem`, etc.).
   * **`A`:** Standard atomic memory instructions (`lr.w`, `sc.w`, `amo*`).
   * **`C`:** Standard 16-bit compressed instructions.
   * **`Zifencei`:** Instruction-fetch fence (`fence.i`) for synchronizing dynamically loaded code.
   * *(Volume II: Privileged Architecture, `Zicsr`, and all vendor-specific extensions are explicitly excluded.)*
2. **The RISC-V ELF psABI Specification (`ILP32`)** — defines standard ABI register names, caller-saved vs. callee-saved register rules, 16-byte stack alignment, and integer data widths (`int`/`long`/pointer = 32 bits).

### Document Conventions

* **Byte Order & Data Sizes:** Oasis32 is **little-endian** (the least significant byte of a multi-byte value is stored at the lowest memory address). Throughout this manual, a *byte* is 8 bits (`uint8_t`/`int8_t`), a *halfword* is 16 bits (`uint16_t`/`int16_t`), a *word* is 32 bits (`uint32_t`/`int32_t`), and a *doubleword* is 64 bits.
* **Numeric Notation:** Hexadecimal numbers use the `0x` prefix; underscores (such as `0x2007_4000`) are used in prose and tables for readability and are omitted in assembly/header literals. Binary values use the `0b` prefix. Unprefixed numbers are decimal.
* **Bit Numbering & Field Notation:** `bit 0` is always the least significant bit (LSB). Multi-bit fields are written `bits [hi:lo]` inclusive (for example, `bits [7:0]` is the low byte of a 32-bit word).
* **Address & Value Ranges:** Ranges written `A`–`B` or `A..B` are **inclusive** of both endpoints. Half-open intervals written `[A, B)` include `A` and exclude `B`.
* **Register Names:** General-purpose registers are referred to by their standard RISC-V ABI names (`zero`, `ra`, `sp`, `gp`, `tp`, `t0–t6`, `s0–s11`, `a0–a7`).
* **BIOS Return Convention:** Every resident BIOS service returns a signed 32-bit integer in `a0` where `a0 >= 0` signals success and `a0 < 0` signals a standardized negative error code (`ERR_*`).
* **Symbolic Constants:** Identifiers in `ALL_CAPS` (such as `USER_RAM_BASE`, `VIDEO_FRAMEBUF_BASE`, `BIOS_TEXT_PUTC`, or `KEY_ENTER`) correspond verbatim to `#define` constants provided in the public ABI headers under `include/abi/`.

---

## 1. System Architecture & Machine Model

### 1.1 CPU & Instruction Set Architecture

Oasis32 presents a **single-core, single-threaded, 32-bit little-endian RISC-V** processor operating in a flat 32-bit physical address space with no virtual memory or address translation.

| Property | Specification |
|:---|:---|
| **Word Width & Endianness** | 32-bit (`XLEN = 32`), little-endian |
| **Execution Model** | Single-core, single-threaded, flat address space |
| **Nominal System Clock** | `126 MHz` (~`7.94 ns` per cycle) |
| **Declared ISA String** | `RV32IMAC_Zifencei` |
| **Calling Convention** | RISC-V `ILP32` (32 general-purpose registers `x0`–`x31`, 16-byte stack alignment) |

#### Supported Extensions (`RV32IMAC_Zifencei`)

| Extension | Scope & Role on Oasis32 |
|:---|:---|
| **`RV32I`** | Base 32-bit integer instruction set, including `ecall` for invoking BIOS and OS services. |
| **`M`** | Hardware integer multiplication and division (`mul`, `mulh*`, `div`, `divu`, `rem`, `remu`). |
| **`A`** | Standard atomic memory operations (`lr.w`, `sc.w`, `amo*`). |
| **`C`** | 16-bit compressed instructions for compact code density; instruction addresses are 2-byte aligned. |
| **`Zifencei`** | Instruction-fetch synchronization (`fence.i`). Required after writing or loading machine code into User SRAM (e.g., by an OS program loader or self-hosted assembler) before jumping to it. |

#### Excluded Instructions & Timing Guidance
* **Strictly Unprivileged:** `Zicsr` (CSR access instructions), privileged instructions (such as `mret` and `wfi`), floating-point extensions (`F`/`D`), and all vendor-specific extensions are **excluded** from the Oasis32 ISA contract. Oasis32 disk builds targeting `-march=rv32imac_zifencei` enforce this boundary automatically at assemble time.
* **Timing Independence:** While the processor runs at a nominal `126 MHz`, software should never rely on hand-tuned instruction delay loops for real-time pacing. Use `BIOS_TIME_US` (`0x50`) for microsecond timing and `BIOS_VIDEO_WAIT_VSYNC` (`0x21`) for 60 Hz frame synchronization.

### 1.2 Hardware Overview (Programmer's View)

From a programmer's perspective, Oasis32 is a clean, self-contained microcomputer with two direct memory regions (User SRAM and Public Video RAM) and a permanent Resident System ROM (BIOS) that abstracts all I/O peripherals behind `ecall`:

```text
                       ┌────────────────────────────────────┐
                       │       Oasis32 32-bit CPU           │
                       │   RV32IMAC_Zifencei @ 126 MHz      │
                       └────────┬──────────────────┬────────┘
                                │                  │
               Direct Load/Store│                  │ ecall (a7 = Service ID)
                                ▼                  ▼
┌────────────────────────────────────────┐   ┌──────────────────────────────────┐
│           512 KB Public SRAM           │   │    Resident System ROM (BIOS)    │
│                                        │   │                                  │
│  ┌──────────────────────────────────┐  │   │  • System Control & OS Hook      │
│  │ User SRAM (464 KB)               │  │   │  • Serial Port                   │
│  │ 0x2000_0000 – 0x2007_3FFF        │  │   │  • Video Sync & Font Reset       │
│  │ Code, Data, Heap, Stack          │  │   │  • Text Console & Blink Cursor   │
│  └──────────────────────────────────┘  │   │  • Keyboard & Mouse (Buffered)   │
│  ┌──────────────────────────────────┐  │   │  • SD Card Storage (512 B LBA)   │
│  │ Public Video RAM (48 KB)         │  │   │  • Monotonic 64-bit Timer (1 us) │
│  │ 0x2007_4000 – 0x2007_FFFF        │──┼──▶│  • Piezo Audio (16–20,000 Hz)    │
│  │ FRAMEBUF, FONT_RAM, TEXT_BUF,    │  │   │  • Status LEDs (Red/Green/Blue)  │
│  │ VIDEO_CTRL, SPRITE_OAM/PAT       │  │   └──────────────────────────────────┘
│  └──────────────────┬───────────────┘  │
└─────────────────────┼──────────────────┘
                      │ Autonomous Scanout (Zero CPU Overhead)
                      ▼
       ┌──────────────────────────────┐
       │   640×480 @ 60 Hz Display    │
       │  Bitmap + 80×60 Text Overlay │
       │  + 16 Masked 16×16 Sprites   │
       └──────────────────────────────┘
```

#### Subsystem Summary

| Subsystem | Capabilities | Access Interface |
|:---|:---|:---|
| **User Memory** | `464 KB` contiguous read/write/execute SRAM (`0x2000_0000`–`0x2007_3FFF`). | Direct load/store & instruction fetch |
| **Display & Sprites** | `640×480 @ 60 Hz` monochrome bitmap, `80×60` OR-composited text overlay, programmable `256`-glyph `8×8` CP437 font, `16` masked `16×16` hardware sprites (`58` patterns). | Direct load/store to Video RAM (`0x2007_4000`–`0x2007_FFFF`) + `BIOS_BLK_VIDEO` (`0x20`) |
| **Text Console** | Managed `80×60` cursor, character/string output with `\n`/`\r`/`\b`, line wrap, auto-scroll, manual scroll, and non-destructive hardware blinking cursor. | `BIOS_BLK_TEXT` (`0x80`) |
| **Keyboard** | Interrupt-buffered `32`-event queue, hardware-independent keycodes, modifier tracking, `6`-key state snapshot, US ASCII translation, configurable typematic repeat. | `BIOS_BLK_INPUT` (`0x30`–`0x36`) |
| **Mouse** | Screen-space tracking (`0..639 × 0..479`), separate `16`-event motion/wheel and button queues, live state snapshot, and coordinate warping. | `BIOS_BLK_INPUT` (`0x38`–`0x3F`) |
| **Removable Storage** | Raw `512`-byte LBA sector read/write, capacity query, and debounced hot-swap card detection. | `BIOS_BLK_SD` (`0x40`) |
| **Serial Port** | Full-duplex `115,200` baud, 8N1 byte stream (no hardware flow control) for host terminal I/O and boot transfers. | `BIOS_BLK_SERIAL` (`0x10`) |
| **System Timer** | Free-running `64`-bit monotonic counter ticking at `1 MHz` (`1 µs` resolution) since reset. | `BIOS_BLK_TIME` (`0x50`) |
| **Audio** | Single-channel square-wave piezo buzzer (`16`–`20,000 Hz`, `0` = silent). | `BIOS_BLK_AUDIO` (`0x60`) |
| **Status LEDs** | Three individually controllable indicator LEDs (Red, Green, Blue). | `BIOS_BLK_LED` (`0x70`) |
| **System Control** | BIOS version query, full hardware reset, and OS `ecall` extension hook (`a7 >= 0x0100`). | `BIOS_BLK_SYS` (`0x00`) |

All display refresh and background input buffering operate autonomously with zero polling burden on Oasis32 software. Programs simply write pixels, glyphs, or sprite descriptors into Public Video RAM and poll or block on BIOS services as needed.

### 1.3 Execution Rules & Honor-System Boundaries

In the tradition of classic microcomputers, Oasis32 executes loaded programs directly on the processor without virtual memory or runtime hardware memory protection. The boundary between Oasis32 software and the Resident System ROM is maintained by **architectural contract** (backed by assemble-time checks in the disk build toolchain).

#### Permitted Operations
Oasis32 software is free to:
* Execute any standard **`RV32IMAC_Zifencei`** instruction located within **User SRAM** (`0x2000_0000`–`0x2007_3FFF`).
* Read and write anywhere in **User SRAM** (`0x2000_0000`–`0x2007_3FFF`) and **Public Video RAM** (`0x2007_4000`–`0x2007_FFFF`).
* Invoke Resident BIOS services (`a7 = 0x0000`–`0x00FF`) and OS extensions (`a7 >= 0x0100`) using `ecall`.
* Register a custom `ecall` dispatcher inside User SRAM via `BIOS_SYS_SET_OS_ECALL_HANDLER` (`0x02`).

#### Prohibited Operations
Oasis32 software must **never**:
* **Access CSRs or Privileged Instructions:** Do not execute CSR instructions (`Zicsr`), trap-return/sleep instructions (`mret`, `wfi`), or vendor-specific extensions. Trap vectors, interrupt masks, and system status registers belong exclusively to the System ROM.
* **Access Reserved or Unmapped Addresses:** Do not read, write, or branch to any address outside User SRAM and Public Video RAM. Never hardcode System ROM addresses or attempt direct memory-mapped peripheral I/O.
* **Execute Code from Video RAM:** Treat Public Video RAM (`0x2007_4000`–`0x2007_FFFF`) as data-only.
* **Pass Out-of-Range Pointers to BIOS Services:** Any buffer, string, or callback pointer passed to a BIOS `ecall` must lie completely within User SRAM (BIOS services validate pointer bounds and reject out-of-range addresses with `ERR_INVALID_ARG`).

#### Why These Boundaries Matter
Violating these rules results in undefined behavior: modifying system state can stall background keyboard/mouse input, corrupt display scanout, or crash the machine outright. Conversely, software that strictly honors these rules is guaranteed to remain portable across future System ROM updates—including any future revision that enables hardware-enforced privilege or memory protection.

### 1.4 Interrupt Transparency & Runtime Faults

#### Transparent Background Servicing
All background hardware activity—including display refresh, keyboard/mouse event capture, and typematic key repeat—is completely transparent to Oasis32 software:

* **Bit-for-Bit Register Preservation:** A background hardware interrupt may occur between any two instructions and is guaranteed to return with every general-purpose register (`x1`–`x31`) and the program counter completely unchanged.
* **Isolated Interrupt Stack:** Background interrupts execute on an internal BIOS stack and **never** touch the program's stack pointer (`sp`). Programs do not need to reserve extra stack space or write special interrupt-safe boilerplate for background events. *(Explicit `ecall` calls do use a small amount of the caller's stack; see §4.1.)*

#### Synchronous Runtime Faults
If Oasis32 software triggers a synchronous processor exception other than `ecall`—such as an illegal instruction, an unaligned memory access, or a bus fault from accessing an unmapped address—the BIOS catches the trap, prints a diagnostic report over the serial port, and halts the machine until Reset:

```text
[BIOS FATAL] Unhandled sync trap: mcause=0x00000002 mepc=0x20000148 mtval=0x00000000
```

| Field | Debugging Meaning |
|:---|:---|
| **`mcause`** | RISC-V synchronous exception code (e.g., `0x2` = illegal instruction, `0x4`/`0x6` = misaligned load/store, `0x5`/`0x7` = load/store access fault). |
| **`mepc`** | Address of the faulting instruction in User SRAM (match against your `.dis` disassembly listing). |
| **`mtval`** | Trap-specific value (typically the faulting memory address or offending instruction encoding, or `0` if unavailable). |

---

## 2. Memory Map

### 2.1 Address Space Overview

Oasis32 exposes a single contiguous **512 KB** (`524,288` bytes) public RAM window spanning `0x2000_0000`–`0x2007_FFFF`, divided into **464 KB of User SRAM** and **48 KB of Public Video RAM**. Every address outside this window is reserved and off-limits to Oasis32 software.

```text
0xFFFF_FFFF ┌──────────────────────────────────────────────────────────────┐
            │  Reserved / Off-Limits                                       │
0x2008_0000 ╞══════════════════════════════════════════════════════════════╡
            │  Public Video Memory Block — 48 KB (49,152 B), R/W Data      │
            │    0x2007_F180–0x2007_FFFF   SPRITE_PAT  (3,712 B)           │
            │    0x2007_F100–0x2007_F17F   SPRITE_OAM    (128 B)           │
            │    0x2007_F0C0–0x2007_F0FF   VIDEO_CTRL     (64 B)           │
            │    0x2007_DE00–0x2007_F0BF   TEXT_BUF    (4,800 B)           │
            │    0x2007_D600–0x2007_DDFF   FONT_RAM    (2,048 B)           │
            │    0x2007_4000–0x2007_D5FF   FRAMEBUF   (38,400 B)           │
0x2007_4000 ╞══════════════════════════════════════════════════════════════╡ ◀ USER_STACK_TOP
            │                                                              │
            │  User SRAM — 464 KB (475,136 B), R/W/X                       │
            │    • Program code (.text), constants (.rodata), data (.data) │
            │    • Uninitialized globals (.bss) and dynamic heap (↑)       │
            │    • Program stack (starts at 0x2007_4000, grows ↓)          │
            │                                                              │
0x2000_0000 ╞══════════════════════════════════════════════════════════════╡ ◀ USER_RAM_BASE
            │  Reserved / Off-Limits                                       │
0x0000_0000 └──────────────────────────────────────────────────────────────┘
```

#### Top-Level Address Map

| Region | Symbolic Constants | Address Range (Incl.) | Size (Bytes) | Size (Hex) | Permitted Access |
|:---|:---|:---|---:|---:|:---|
| **Reserved (Low)** | — | `0x0000_0000`–`0x1FFF_FFFF` | — | — | **Prohibited** |
| **User SRAM** | `USER_RAM_BASE` .. `USER_RAM_END` | `0x2000_0000`–`0x2007_3FFF` | `475,136` | `0x0007_4000` | Read / Write / Execute |
| **Public Video RAM** | `VIDEO_RAM_BASE` .. `VIDEO_RAM_END` | `0x2007_4000`–`0x2007_FFFF` | `49,152` | `0x0000_C000` | Read / Write (Data Only) |
| **Reserved (High)** | — | `0x2008_0000`–`0xFFFF_FFFF` | — | — | **Prohibited** |

All symbolic memory-map constants are defined in `include/abi/memory_map.h`. Software should reference these constants rather than hardcoding raw addresses.

### 2.2 User SRAM (`USER_RAM_BASE`–`USER_RAM_END`)
*TODO: Document the 464 KB (`475,136` bytes, `0x2000_0000`–`0x2007_3FFF`) contiguous User SRAM window: typical placement of `.text`, `.rodata`, `.data`, `.bss`, upward-growing heap, and downward-growing user stack initialized to `USER_STACK_TOP` (`0x2007_4000`, 16-byte aligned per `ILP32`). Warn explicitly about stack overflow/underflow behavior in the absence of hardware guard pages (overflow corrupts `.bss`/heap/code; underflow above `0x2007_4000` corrupts the top of `FRAMEBUF`).*

### 2.3 Public Video Memory Block (`VIDEO_RAM_BASE`–`VIDEO_RAM_END`)
*TODO: Provide a complete address/size/alignment table of the 48 KB (`49,152` bytes, `0x2007_4000`–`0x2007_FFFF`) video region (`FRAMEBUF`, `FONT_RAM`, `TEXT_BUF`, `VIDEO_CTRL`, `SPRITE_OAM`, `SPRITE_PAT`) with their symbolic constants from `include/abi/memory_map.h`, cross-referencing Chapter 5 for detailed bit/struct layouts.*

### 2.4 Linking Against the Memory Map (`memory_map.h` & `sd_payload.ld.S`)
*TODO: Explain how Oasis32 programs consume `include/abi/memory_map.h` and the shared preprocessed linker script `include/ld/sd_payload.ld.S` (including exported linker symbols such as `__payload_start`, `__payload_end`, `__payload_size`, `__bss_start`, `__bss_end`, and `__stack_top`, and the `.text.entry` placement convention).*

---

## 3. Boot Process, Disk Image Format & Startup State

### 3.1 Bootable Disk Image Format (`"OA32"`)
*TODO: Specify the exact binary layout of an Oasis32 disk image (used identically on raw SD cards starting at LBA 0 and over serial in Base64): the packed 16-byte little-endian Boot Image Header (`magic = 0x3233414F` / `"OA32"`, `load_addr`, `entry_addr`, `payload_size`) and raw payload starting at byte offset `0x10` (16), sharing up to 496 bytes of LBA 0 and continuing across LBA 1..N with zero-padding at the end of the final 512-byte sector. Document the bootloader's bounds-validation rules (User SRAM bounds, 32-bit overflow checks) and `include/abi/boot_header.h` constants.*

### 3.2 Bootloader Interface & Startup Menu (User Guide)
*TODO: Provide complete user documentation for operating the interactive startup bootloader over the serial console (connecting a host terminal at 115,200 baud, 8N1, no flow control). Document the power-up splash screen, exact menu layout, and step-by-step usage for all four options: `ENTER` (boot from SD card), `1` (boot a Base64-encoded `.oa32` disk image directly into User SRAM without touching the SD card), `2` (receive a Base64-encoded `.oa32` image into User SRAM, validate it, and write it raw to an SD card starting at LBA 0), and `3` (run the built-in hardware diagnostic demo). Document interactive prompts (`"Insert boot disk"` / `"Insert disk to write"`), Base64 framing rules (whitespace ignored, stops automatically after `16 + payload_size` decoded bytes), error messages, and recovery back to the boot menu. (Note: verify final exact prompt wording once Sub-Phase 3c is implemented.)*

### 3.3 Guaranteed Machine State at Entry (`_start`)
*TODO: Specify every guaranteed register, memory, and peripheral invariant when the BIOS bootloader transfers control to `entry_addr` (after executing `fence.i`):*
- *CPU & Stack: `sp = USER_STACK_TOP` (`0x2007_4000`, 16-byte aligned); all other GPRs unspecified.*
- *Memory & `.bss`: `[load_addr, load_addr + payload_size)` holds the verified payload bytes; **the program's `_start` is responsible for zeroing `[__bss_start, __bss_end)`** (since `.bss` is not encoded in the 16-byte `"OA32"` header). Unloaded regions of User SRAM are unspecified.*
- *Clean Peripheral Handoff: Before jumping to `entry_addr`, the bootloader resets Video RAM (`FRAMEBUF`, `TEXT_BUF`, `SPRITE_OAM`, `SPRITE_PAT` zeroed; default CP437 font loaded in `FONT_RAM`; `VIDEO_CTRL.LATCH_OAM = 1`), resets the text console cursor to `(0, 0)` hidden (`vis = 0`, `blink = 0`), flushes all keyboard/mouse queues, centers the mouse at `(320, 240)`, restores default keyboard repeat (`500 ms` delay, `50 ms` rate), silences the piezo buzzer, turns all 3 status LEDs off, and leaves `os_ecall_handler = 0`.*
- *SD Card: If booted via `ENTER`, the SD card is already initialized (`SD_STATUS_PRESENT | SD_STATUS_READY`); if booted via serial (`1`), a card may or may not be present/initialized (call `BIOS_SD_STATUS` / `BIOS_SD_INIT` before block I/O).*

### 3.4 Program Termination, Exit & Reboot Semantics
*TODO: Clarify that boot payloads are entered via a one-way jump (there is no caller to `ret` to). Document how a program should idle cleanly (e.g., event loop) or perform a clean full system restart via `BIOS_SYS_REBOOT` (as well as hardware reset button behavior).*

---

## 4. BIOS ABI & Calling Contract

### 4.1 Invoking BIOS Services (`ecall`)
*TODO: Specify the exact RISC-V `ecall` calling contract: `a7` holds the service ID, `a0–a5` pass up to 6 word-sized arguments, `a0` (and for select calls, `a1–a5`) return results. State `ILP32` register preservation guarantees (`s0–s11`, `sp`, `gp`, `tp`, `ra` preserved; `t0–t6` and unspecified `a0–a7` caller-saved/clobberable), caller stack headroom expectations (~64–128 bytes for the trap frame and service locals), and the fact that background I/O remains live during blocking BIOS calls.*

### 4.2 Return Values & Standardized Error Codes
*TODO: Document the uniform signed-integer return convention in `a0` (`a0 >= 0` indicates success, `a0 < 0` indicates error, enabling single-instruction `bltz a0, ...` error checks) and tabulate all standardized error codes from `include/abi/bios_abi.h`: `ERR_OK (0)`, `ERR_UNSUPPORTED (-1)`, `ERR_INVALID_ARG (-2)`, `ERR_EMPTY (-3)`, `ERR_BUSY (-4)`, `ERR_IO (-5)`, and `ERR_NO_DEVICE (-6)`.*

### 4.3 Service ID Partitioning & Subsystem Blocks
*TODO: Document the split between Resident BIOS services (`0x0000`–`0x00FF`) and OS extensions (`0x0100+`), and summarize the 16-ID subsystem blocks (`0x00` System, `0x10` Serial, `0x20` Video, `0x30` Input, `0x40` Storage, `0x50` Timer, `0x60` Audio, `0x70` LEDs, `0x80` Text Console, `0x90–0xFF` Reserved).*

### 4.4 Extending `ecall` for an Operating System
*TODO: Document how an operating system registers its own syscall dispatcher for `a7 >= 0x0100` using `BIOS_SYS_SET_OS_ECALL_HANDLER` (alignment and User SRAM range requirements, clearing with `0`). Explain the exact register state on entry to the OS handler (`a0–a5` arguments, `a7` service ID, standard `ret` return via `ra` with result in `a0`), and highlight **nested `ecall` re-entrancy** (an OS syscall handler may freely invoke BIOS `ecall` services such as `BIOS_SD_READ` or `BIOS_TEXT_PUTS`).*

---

## 5. Video Subsystem & Display Programming

### 5.1 Unified Display Architecture
*TODO: Explain the 640×480 @ 60 Hz monochrome unified display model (zero mode switching) and illustrate the deterministic 4-layer scanline compositing pipeline:*
1. *`FRAMEBUF` (bottom bitmap layer)*
2. *Behind-text sprites (`BEHIND_TEXT = 1`, Slot 15 → Slot 0)*
3. *`TEXT_BUF` / `FONT_RAM` (OR-composited) + non-destructive hardware text cursor inversion (`^ 0xFF`)*
4. *In-front sprites (`BEHIND_TEXT = 0`, Slot 15 → Slot 0)*

*Explain how pure graphics mode, pure 80×60 text mode, and combined text-over-graphics overlay all emerge naturally from this single pipeline.*

### 5.2 Bitmap Framebuffer (`FRAMEBUF`)
*TODO: Specify `VIDEO_FRAMEBUF_BASE` (`0x2007_4000`, `38,400` bytes): 640×480 @ 1 bpp, `80`-byte (`20`-word) scanline stride, exact byte/bit addressing formulas for pixel `(x, y)` (`byte = y * 80 + (x >> 3)`, `bit = x & 7`), **LSB-left pixel order** (bit 0 = leftmost pixel in each byte, bit 7 = rightmost), and polarity (`1` = white/lit, `0` = black/dark).*

### 5.3 Programmable Font (`FONT_RAM`) & Text Overlay (`TEXT_BUF`)
*TODO: Specify `VIDEO_FONT_RAM_BASE` (`0x2007_D600`, `2,048` bytes) in glyph-major order (`FONT_RAM[ch * 8 + row]`, row `0` = top, row `7` = bottom, LSB-left pixel order) and `VIDEO_TEXT_BUF_BASE` (`0x2007_DE00`, `4,800` bytes) as an 80×60 cell grid (`TEXT_BUF[row * 80 + col]`). Document the default IBM Code Page 437 font, the transparent glyph `0x00` convention, runtime custom glyph / 8×8 tile redefinition, and restoring the default font via `BIOS_VIDEO_RESET_FONT`.*

### 5.4 Hardware Sprite Engine (`SPRITE_OAM`, `SPRITE_PAT`, `VIDEO_CTRL`)

#### 5.4.1 Sprite Pattern Format (`SPRITE_PAT`)
*TODO: Document `VIDEO_SPRITE_PAT_BASE` (`0x2007_F180`, `3,712` bytes): 58 patterns × 64 bytes each, split into a 32-byte Pixel Plane (`+0x00`, 16 × `uint16_t`) and a 32-byte Mask Plane (`+0x20`, 16 × `uint16_t`), LSB-left bit order (`bit 0` = column 0, `bit 15` = column 15). Explain the 3 pixel states (Transparent, Opaque Black, Opaque White) and how to build crisp outlined cursors/sprites.*

#### 5.4.2 OAM Slot Descriptor Format (`SPRITE_OAM`)
*TODO: Document `VIDEO_SPRITE_OAM_BASE` (`0x2007_F100`, `128` bytes): 16 slots × 8 bytes each (`x`, `y`, `pattern`, `flags`, `reserved`). Specify signed clipping ranges (`x` in `-15..639`, `y` in `-15..479`), the atomic 32-bit `sw` update idiom for `[y:16 | x:16]`, pattern index range (`0..57`, out-of-range skipped), and every bit of `flags` (`ENABLE`, `HFLIP`, `VFLIP`, `BEHIND_TEXT`, and `BLEND` modes: Opaque `(bg & ~mask) | pixels`, OR `bg | pixels`, XOR `bg ^ pixels`).*

#### 5.4.3 Priority Order & Mouse Cursor Convention
*TODO: Explain the Slot 15 → Slot 0 draw order (lower slot index = higher visual priority) within each layer, and the convention of reserving Sprite 0 (`BEHIND_TEXT = 0`) for the floating hardware mouse cursor. Note that all 16 sprites may overlap on the same scanline with zero drop-out or flicker.*

#### 5.4.4 Frame Latching vs. Dynamic Beam-Racing (`VIDEO_CTRL`)
*TODO: Document `VIDEO_CTRL_BASE` (`0x2007_F0C0`, 64 bytes) and `VIDEO_CTRL_FLAGS_OFF` (`+0x00`), specifically `VIDEO_CTRL_LATCH_OAM_BIT` (`bit 0`): `1` (boot default) latches `SPRITE_OAM` once per frame during VBLANK for tear-free updates; `0` reads `SPRITE_OAM` live per scanline for raster/beam-racing effects.*

### 5.5 VSYNC Synchronization & Video BIOS Services
*TODO: Explain tear-free 60 Hz animation pacing using `BIOS_VIDEO_FRAME_COUNT` and `BIOS_VIDEO_WAIT_VSYNC`, and cross-reference Section 6.3 for exact syscall signatures.*

---

## 6. Resident BIOS Services Reference

*TODO: Define the uniform per-syscall specification template used throughout Chapter 6: Service ID, Synopsis, Inputs, Outputs, Blocking/Non-Blocking behavior, Error Codes, and Behavioral Notes.*

### 6.1 System Control (`BIOS_BLK_SYS`, `0x00`–`0x0F`)
*TODO: Full reference entries for:*
- *`BIOS_SYS_VERSION` (`0x00`) — packed `(major << 16) | (minor << 8) | patch`.*
- *`BIOS_SYS_REBOOT` (`0x01`) — full hardware reset (does not return).*
- *`BIOS_SYS_SET_OS_ECALL_HANDLER` (`0x02`) — register/clear OS dispatcher (`0` or 2-byte-aligned address in User SRAM).*

### 6.2 Serial Port (`BIOS_BLK_SERIAL`, `0x10`–`0x1F`)
*TODO: Overview of the fixed 115,200 baud 8N1 serial port (no hardware flow control; 8-bit clean binary/text byte stream), followed by full reference entries for:*
- *`BIOS_SERIAL_READ` (`0x10`) — blocking byte read (`0..255`).*
- *`BIOS_SERIAL_TRY_READ` (`0x11`) — non-blocking byte read or `ERR_EMPTY`.*
- *`BIOS_SERIAL_WRITE` (`0x12`) — blocking byte write.*
- *`BIOS_SERIAL_TRY_WRITE` (`0x13`) — non-blocking byte write or `ERR_BUSY`.*

### 6.3 Video Services (`BIOS_BLK_VIDEO`, `0x20`–`0x2F`)
*TODO: Full reference entries for:*
- *`BIOS_VIDEO_FRAME_COUNT` (`0x20`) — monotonic 32-bit VSYNC frame counter.*
- *`BIOS_VIDEO_WAIT_VSYNC` (`0x21`) — block until next VSYNC boundary, returning the new frame counter.*
- *`BIOS_VIDEO_RESET_FONT` (`0x22`) — reload the default 2 KB CP437 8×8 font into `FONT_RAM`.*

### 6.4 Keyboard & Mouse Input (`BIOS_BLK_INPUT`, `0x30`–`0x3F`)

#### 6.4.1 Keyboard Event Model, Modifiers & Typematic Repeat
*TODO: Document the interrupt-buffered 32-entry keyboard event queue, the packed 32-bit `key_event` bit layout (`[7:0]` Oasis32 keycode, `[15:8]` `KEY_MOD_*` bitmask, `bit 16` `KEY_EVENT_DOWN_BIT`, `bit 17` `KEY_EVENT_REPEAT_BIT`), 6-key rollover state snapshots, modifier key press/release events (`0xE0`–`0xE7`), and timer-driven typematic repeat (boot default: `500 ms` delay, `50 ms` rate; `0` disables; flush cancels active repeat).*

#### 6.4.2 Keyboard Services
*TODO: Full reference entries for:*
- *`BIOS_KEYBOARD_READ` (`0x30`) — blocking event dequeue.*
- *`BIOS_KEYBOARD_TRY_READ` (`0x31`) — non-blocking event dequeue or `ERR_EMPTY`.*
- *`BIOS_KEYBOARD_FLUSH` (`0x32`) — clear queue and cancel active typematic repeat.*
- *`BIOS_KEYBOARD_STATE` (`0x33`) — write up to 6 active keycodes (zero-padded to 8 bytes) into a User SRAM buffer, returning count in `a0` and modifiers in `a1`.*
- *`BIOS_KEYBOARD_KEYCODE_TO_ASCII` (`0x34`) — Shift-aware US layout translation to printable ASCII (`0x20`–`0x7E`) or `0`.*
- *`BIOS_KEYBOARD_SET_REPEAT` (`0x35`) — configure repeat delay and interval (`0..65535` ms).*
- *`BIOS_KEYBOARD_GET_REPEAT` (`0x36`) — query current repeat delay and interval.*

#### 6.4.3 Mouse Event Model & Screen-Space Coordinates
*TODO: Document BIOS-maintained screen-space mouse tracking (clamped to `0..639 × 0..479`, initialized to center `(320, 240)` at boot), the two separate 16-entry queues (motion/wheel vs. button transitions), the packed `btn_event` bit layout (`[7:0]` changed button mask, `[15:8]` new full button state, `bit 16` `MOUSE_EVENT_DOWN_BIT`), and captured `(x, y)` coordinates on button events.*

#### 6.4.4 Mouse Services
*TODO: Full reference entries for:*
- *`BIOS_MOUSE_POS_READ` (`0x38`) / `BIOS_MOUSE_POS_TRY_READ` (`0x39`) — return `(x, y, dx, dy, dwheel)` in `a1–a5`.*
- *`BIOS_MOUSE_POS_FLUSH` (`0x3A`) — clear motion queue.*
- *`BIOS_MOUSE_BUTTON_READ` (`0x3B`) / `BIOS_MOUSE_BUTTON_TRY_READ` (`0x3C`) — return `(btn_event, x, y)` in `a0–a2`.*
- *`BIOS_MOUSE_BUTTON_FLUSH` (`0x3D`) — clear button queue.*
- *`BIOS_MOUSE_STATE` (`0x3E`) — live snapshot of `(buttons, x, y)`.*
- *`BIOS_MOUSE_SET_POS` (`0x3F`) — warp mouse coordinates within `0..639 × 0..479`.*

### 6.5 SD Card Block Storage (`BIOS_BLK_SD`, `0x40`–`0x4F`)
*TODO: Document the raw 512-byte LBA block storage model, card-detect debouncing and hot-swap invalidation rules (removing a card clears `SD_STATUS_READY`, requiring `BIOS_SD_INIT` after reinsertion), User SRAM buffer validation (`[buf_ptr, buf_ptr + 512)`), and LBA bounds checking. Full reference entries for:*
- *`BIOS_SD_STATUS` (`0x40`) — returns `SD_STATUS_PRESENT`, `SD_STATUS_READY`, `SD_STATUS_SDHC` bitmask.*
- *`BIOS_SD_INIT` (`0x41`) — initialize/re-initialize inserted card.*
- *`BIOS_SD_READ` (`0x42`) — synchronous 512-byte sector read.*
- *`BIOS_SD_WRITE` (`0x43`) — synchronous 512-byte sector write.*
- *`BIOS_SD_CAPACITY` (`0x44`) — return total 512-byte sector count in `a1`.*

### 6.6 Monotonic Microsecond Timer (`BIOS_BLK_TIME`, `0x50`–`0x5F`)
*TODO: Document the 64-bit 1 MHz (1 µs) monotonic clock starting at power-up/reset, rollover-safe 32-bit/64-bit elapsed-time subtraction idioms, and the full reference entry for:*
- *`BIOS_TIME_US` (`0x50`) — atomic 64-bit microsecond timestamp (`a0 = us_lo`, `a1 = us_hi`).*

### 6.7 Piezo Audio (`BIOS_BLK_AUDIO`, `0x60`–`0x6F`)
*TODO: Document square-wave tone generation, valid frequency range (`16..20,000` Hz; `0` = silence), and integer microsecond-period quantization at high frequencies. Full reference entry for:*
- *`BIOS_AUDIO_TONE` (`0x60`) — set buzzer frequency or silence.*

### 6.8 Status LEDs (`BIOS_BLK_LED`, `0x70`–`0x7F`)
*TODO: Document the three logical status LEDs (`LED_RED = 0`, `LED_GREEN = 1`, `LED_BLUE = 2`) and full reference entries for:*
- *`BIOS_LED_WRITE` (`0x70`) — set LED off (`0`) or on (nonzero).*
- *`BIOS_LED_READ` (`0x71`) — query current LED state (`0` or `1`).*

### 6.9 Text Console & Hardware Cursor (`BIOS_BLK_TEXT`, `0x80`–`0x8F`)
*TODO: Document the BIOS-managed 80×60 text console layered atop `TEXT_BUF`, including non-destructive hardware blinking cursor inversion (never mutates `TEXT_BUF` or `FONT_RAM`), control character behavior (`\n` Unix newline, `\r` carriage return, `\b` cursor-left with reverse line wrap), automatic line wrapping and upward scrolling past row 59, and interaction with direct writes to `TEXT_BUF`. Full reference entries for:*
- *`BIOS_TEXT_CLEAR` (`0x80`)*
- *`BIOS_TEXT_PUTC` (`0x81`)*
- *`BIOS_TEXT_PUTS` (`0x82`)*
- *`BIOS_TEXT_SET_CURSOR_POS` (`0x83`)*
- *`BIOS_TEXT_GET_CURSOR_POS` (`0x84`)*
- *`BIOS_TEXT_SET_CURSOR_STATE` (`0x85`)*
- *`BIOS_TEXT_SCROLL_UP` (`0x86`)*
- *`BIOS_TEXT_SCROLL_DOWN` (`0x87`)*

---

## 7. Cross-Compiling & Deploying Disk Images

### 7.1 Toolchain & Required Flags
*TODO: Specify the host RISC-V cross-toolchain (`riscv32-unknown-elf-gcc`, `objcopy`, `objdump`) and the exact bare-metal compile/link flags required for Oasis32 disk payloads (`-march=rv32imac_zifencei -mabi=ilp32 -nostdlib -nostartfiles -nodefaultlibs -Wl,--build-id=none`). Explain how to include `include/abi/*.h` and preprocess `include/ld/sd_payload.ld.S`.*

### 7.2 Building Disk Images (CMake & Manual CLI)
*TODO: Document both workflows for producing a bootable `.oa32` disk image:*
- *Using the project's `oasis32_add_disk_executable()` helper in `cmake/oasis32.cmake` (which automatically enforces the `oasis32_abi` boundary, preprocesses `sd_payload.ld.S`, and emits `.elf`, `.dis`, `.map`, and `.oa32`).*
- *A standalone manual CLI sequence (`gcc -E -P -x c` to preprocess `sd_payload.ld.S`, `gcc` to assemble/link, and `objcopy -Obinary` to emit `.oa32`) for programmers building outside CMake.*
*Briefly note minimal `_start` startup requirements (`.section .text.entry`, zeroing `[__bss_start, __bss_end)`).*

### 7.3 Encoding & Sending Disk Images Over Serial
*TODO: Provide step-by-step host instructions for Base64-encoding a `.oa32` image and streaming it to Oasis32 over the 115,200 baud 8N1 USB-C serial port for both **Option `1` (RAM-only boot)** for rapid edit-assemble-test iteration and **Option `2` (write to SD card)** for persistent boot disks. Include practical examples for common host environments (PowerShell / Windows, macOS / Linux `base64`, and terminal-emulator "send text file" or simple Python `pyserial` transfer) and troubleshooting tips (ensuring 115,200 8N1, no flow control, clean Base64 padding, and verifying transfer completion).*

---

## Appendices

### Appendix A: Keyboard Keycodes & Modifier Reference
*TODO: Provide a compact, self-contained table of all Oasis32 keycodes from `include/abi/keycodes.h` (Letters `0x04–0x1D`, Digits `0x1E–0x27`, Control/Punctuation `0x28–0x39`, Function Keys `0x3A–0x45`, Navigation `0x46–0x53`, Numeric Keypad `0x54–0x63`, Modifiers `0xE0–0xE7`), the `KEY_MOD_*` bitmask table, and the exact Unshifted/Shifted ASCII outputs of `BIOS_KEYBOARD_KEYCODE_TO_ASCII`.*

### Appendix B: ASCII & Default CP437 Character Set Reference
*TODO: Include a compact 7-bit ASCII table (`0x00–0x7F`, highlighting control codes handled by `BIOS_TEXT_PUTC`) plus a quick reference summary of the default IBM Code Page 437 high-byte glyphs (`0x80–0xFF`: box drawing, block shading, accented letters, math symbols) and the empty/transparent `0x00` glyph rule.*

### Appendix C: BIOS `ecall` Quick Reference Card
*TODO: A single consolidated cheat-sheet table listing every BIOS service ID (`0x00`–`0x87`), symbolic name, input registers, output registers, blocking/non-blocking flag, and possible error codes for rapid lookup while coding in assembly.*

### Appendix D: Public ABI Header (`include/abi/*.h`) Symbol Index
*TODO: A compact index grouping all public `#define` constants by header file (`memory_map.h`, `boot_header.h`, `bios_abi.h`, `devices.h`, `keycodes.h`) so programmers know which header to `#include` for any constant.*
