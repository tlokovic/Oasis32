# Oasis32 Programmer's Reference

**System Architecture, Memory Map, Video Subsystem & Resident BIOS ABI Specification**

| | |
|:---|:---|
| **Target System** | Oasis32 32-bit RISC-V Microcomputer |
| **Declared ISA** | `RV32IMAC_Zifencei` (32-bit little-endian, nominal 126 MHz) |
| **Calling Convention** | RISC-V `ILP32` |
| **BIOS ABI Version** | `0.1.0` (`0x0000_0100`) |

This manual is the authoritative, self-contained specification for programming the **Oasis32** computer in bare-metal RISC-V assembly, defining its machine model, memory map, disk format, video layouts, and resident BIOS `ecall` ABI.

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

This manual is self-contained for all Oasis32-specific behavior—including memory layouts, display formats, keycodes, character sets, and BIOS services. For underlying RISC-V instruction encodings and standard calling conventions, it defers **only** to two standard specifications:

1. **The RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture** — scoped strictly to Oasis32's declared ISA string, **`RV32IMAC_Zifencei`** (see §1.1 for the extension breakdown and exclusions).
2. **The RISC-V ELF psABI Specification (`ILP32`)** — standard ABI register names, caller-saved vs. callee-saved rules, 16-byte stack alignment, and 32-bit integer/pointer widths.

### Document Conventions

* **Byte Order & Data Sizes:** Oasis32 is **little-endian** (the least significant byte of a multi-byte value is stored at the lowest memory address). Throughout this manual, a *byte* is 8 bits (`uint8_t`/`int8_t`), a *halfword* is 16 bits (`uint16_t`/`int16_t`), a *word* is 32 bits (`uint32_t`/`int32_t`), and a *doubleword* is 64 bits.
* **Numeric Notation:** Hexadecimal numbers use the `0x` prefix; underscores (such as `0x2007_4000`) are used in prose and tables for readability and are omitted in assembly/header literals. Binary values use the `0b` prefix. Unprefixed numbers are decimal.
* **Bit Numbering & Field Notation:** `bit 0` is always the least significant bit (LSB). Multi-bit fields are written `bits [hi:lo]` inclusive (for example, `bits [7:0]` is the low byte of a 32-bit word).
* **Address & Value Ranges:** Ranges written `A`–`B` or `A..B` are **inclusive** of both endpoints. Half-open intervals written `[A, B)` include `A` and exclude `B`.
* **Register Names:** General-purpose registers are referred to by their standard RISC-V ABI names (`zero`, `ra`, `sp`, `gp`, `tp`, `t0–t6`, `s0–s11`, `a0–a7`).
* **BIOS Return Convention:** Every resident BIOS service that can fail (and all status-returning services) returns a signed 32-bit integer in `a0`, where `a0 >= 0` signals success and `a0 < 0` signals a standardized negative error code (`ERR_*`). Infallible unsigned-counter services (`BIOS_TIME_US`, `BIOS_VIDEO_FRAME_COUNT`, `BIOS_VIDEO_WAIT_VSYNC`) return raw `uint32_t` values in `a0` (see §4.2).
* **Symbolic Constants:** Identifiers in `ALL_CAPS` (such as `USER_RAM_BASE`, `VIDEO_FRAMEBUF_BASE`, `BIOS_TEXT_PUTC`, or `KEY_ENTER`) correspond verbatim to `#define` constants provided in the public ABI headers under `include/abi/`.

---

## 1. System Architecture & Machine Model

### 1.1 CPU & Instruction Set Architecture

Oasis32 presents a **single-core, single-threaded, 32-bit little-endian RISC-V** processor operating in a flat 32-bit physical address space with no virtual memory or address translation.

| Property | Specification |
|:---|:---|
| **Word Width & Endianness** | 32-bit (`XLEN = 32`), little-endian |
| **Execution Model** | Single-core, single-threaded, flat address space |
| **Nominal System Clock** | 126 MHz (~7.94 ns per cycle) |
| **Declared ISA String** | `RV32IMAC_Zifencei` |
| **Calling Convention** | RISC-V `ILP32` (32 general-purpose registers `x0–x31`, 16-byte stack alignment) |

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
* **Timing Independence:** While the processor runs at a nominal 126 MHz, software should never rely on hand-tuned instruction delay loops for real-time pacing. Use `BIOS_TIME_US` (`0x50`) for microsecond timing and `BIOS_VIDEO_WAIT_VSYNC` (`0x21`) for 60 Hz frame synchronization.

### 1.2 Hardware Overview (Programmer's View)

From a programmer's perspective, Oasis32 is a clean, self-contained microcomputer with two direct memory regions (User SRAM and Public Video RAM; see §2) and a permanent Resident System ROM (BIOS) that abstracts all I/O peripherals behind `ecall`:

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
│  │ Code, Data, Heap, Stack          │  │   │  • Keyboard & Mouse (Buffered)   │
│  └──────────────────────────────────┘  │   │  • SD Card Storage (512 B LBA)   │
│                                        │   │  • Monotonic 64-bit Timer (1 us) │
│  ┌──────────────────────────────────┐  │   │  • Piezo Audio (16–20,000 Hz)    │
│  │ Public Video RAM (48 KB)         │  │   │  • Status LEDs (Red/Green/Blue)  │
│  │ Bitmap, Font, Text Overlay,      │◀─┼──▶│  • Video Sync & Font Reset       │
│  │ Control, & Hardware Sprites      │  │   │  • Text Console & Blink Cursor   │
│  └──────────────────┬───────────────┘  │   └──────────────────────────────────┘
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
| **User Memory** | 464 KB contiguous read/write/execute SRAM (§2.2). | Direct load/store & instruction fetch |
| **Display & Sprites** | 640×480 @ 60 Hz monochrome bitmap, 80×60 OR-composited text overlay, programmable 256-glyph 8×8 CP437 font, 16 masked 16×16 hardware sprites (58 patterns). | Direct load/store to Video RAM (§2.3, §5) + `BIOS_BLK_VIDEO` (`0x20`) |
| **Text Console** | Managed 80×60 cursor, character/string output with `\n`/`\r`/`\b`, line wrap, auto-scroll, manual scroll, and non-destructive hardware blinking cursor. | `BIOS_BLK_TEXT` (`0x80`) |
| **Keyboard** | Interrupt-buffered 32-event queue, hardware-independent keycodes, modifier tracking, 6-key state snapshot, US ASCII translation, configurable typematic repeat. | `BIOS_BLK_INPUT` (`0x30`–`0x36`) |
| **Mouse** | Screen-space tracking (`0..639 × 0..479`), separate 16-event motion/wheel and button queues, live state snapshot, and coordinate warping. | `BIOS_BLK_INPUT` (`0x38`–`0x3F`) |
| **Removable Storage** | Raw 512-byte LBA sector read/write, capacity query, and debounced hot-swap card detection. | `BIOS_BLK_SD` (`0x40`) |
| **Serial Port** | Full-duplex 115,200 baud, 8N1 byte stream (no hardware flow control) for host terminal I/O and boot transfers. | `BIOS_BLK_SERIAL` (`0x10`) |
| **System Timer** | Free-running 64-bit monotonic counter ticking at 1 MHz (1 µs resolution) since reset. | `BIOS_BLK_TIME` (`0x50`) |
| **Audio** | Single-channel square-wave piezo buzzer (16–20,000 Hz, `0` = silent). | `BIOS_BLK_AUDIO` (`0x60`) |
| **Status LEDs** | Three individually controllable indicator LEDs (Red, Green, Blue). | `BIOS_BLK_LED` (`0x70`) |
| **System Control** | BIOS version query, full hardware reset, and OS `ecall` extension hook (`a7 >= 0x0100`). | `BIOS_BLK_SYS` (`0x00`) |

All display refresh and background input buffering operate autonomously with zero polling burden on Oasis32 software. Programs simply write pixels, glyphs, or sprite descriptors into Public Video RAM and poll or block on BIOS services as needed.

### 1.3 Execution Rules & Honor-System Boundaries

In the tradition of classic microcomputers, Oasis32 executes loaded programs directly on the processor without virtual memory or runtime hardware memory protection. The boundary between Oasis32 software and the Resident System ROM is maintained by **architectural contract** (backed by assemble-time checks in the disk build toolchain).

#### Permitted Operations
Oasis32 software is free to:
* Execute any standard **`RV32IMAC_Zifencei`** instruction located within **User SRAM** (§2.2).
* Read and write anywhere in **User SRAM** and **Public Video RAM** (§2).
* Invoke Resident BIOS services (`a7 = 0x0000`–`0x00FF`) and OS extensions (`a7 >= 0x0100`) using `ecall`.
* Register a custom `ecall` dispatcher inside User SRAM via `BIOS_SYS_SET_OS_ECALL_HANDLER` (`0x02`).

#### Prohibited Operations
Oasis32 software must **never**:
* **Execute Excluded Instructions:** Do not execute any instruction outside `RV32IMAC_Zifencei` (§1.1). Trap vectors, interrupt masks, and system status registers belong exclusively to the System ROM.
* **Access Reserved or Unmapped Addresses:** Do not read, write, or branch to any address outside User SRAM and Public Video RAM (§2.1). Never hardcode System ROM addresses or attempt direct memory-mapped peripheral I/O.
* **Execute Code from Video RAM:** Treat Public Video RAM as data-only.
* **Pass Out-of-Range Pointers to BIOS Services:** Any non-null buffer, string, or callback pointer passed to a BIOS `ecall` must lie completely within User SRAM (BIOS services validate pointer bounds and reject out-of-range addresses with `ERR_INVALID_ARG`).

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
0x2007_4000 ╞══════════════════════════════════════════════════════════════╡ ◀ USER_STACK_TOP / VIDEO_RAM_BASE
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

User SRAM is a flat, contiguous **464 KB** (`475,136` bytes) read/write/execute memory region owned entirely by the loaded program. The Resident System ROM keeps all internal driver state and background interrupt stacks outside User SRAM, leaving 100% of this window available for application or OS use.

| Constant (`include/abi/memory_map.h`) | Value | Meaning |
|:---|:---|:---|
| `USER_RAM_BASE` | `0x2000_0000` | Inclusive start of User SRAM (default program load base). |
| `USER_RAM_SIZE` | `0x0007_4000` | Total size in bytes (`475,136` bytes = 464 KB). |
| `USER_RAM_END` | `0x2007_3FFF` | Inclusive last byte of User SRAM. |
| `USER_STACK_TOP` | `0x2007_4000` | Exclusive upper bound; initial `sp` value on program entry. |

#### Conventional Program Layout

Programs linked with the standard Oasis32 linker script (§2.4) organize User SRAM from low to high addresses, with the stack growing downward from the top:

```text
0x2007_4000  ── USER_STACK_TOP (= VIDEO_RAM_BASE) ──
             │  User Stack (grows ↓)                │
             │    • Initialized to 0x2007_4000      │
             │    • 16-byte aligned (ILP32)         │
             │                                      │
             │         (Free RAM / Unallocated)     │
             │                                      │
             │  Dynamic Heap (optional, grows ↑)    │
             ├──────────────────────────────────────┤
             │  .bss  (uninitialized globals)       │  ◀ zeroed by _start (§3.3)
             ├──────────────────────────────────────┤
             │  .data (initialized writable data)   │  ┐
             │  .rodata (constants & strings)       │  ├─ Loaded from disk image
             │  .text (.text.entry followed by code)│  ┘
0x2000_0000  ── USER_RAM_BASE ──────────────────────
```

Programs are not forced to use a heap or even start at `0x2000_0000`—an OS loader or multi-stage program may partition User SRAM however it wishes, provided all loaded code, data, and BIOS pointer arguments stay within `[USER_RAM_BASE, USER_STACK_TOP)` and `fence.i` is executed after writing new machine code before jumping to it (§1.1).

#### Alignment Requirements
* **Data Accesses:** Halfword (`lh`/`lhu`/`sh`) accesses must be 2-byte aligned and word (`lw`/`sw`/`amo*`) accesses must be 4-byte aligned. Misaligned loads or stores raise a synchronous trap (`mcause = 0x4` or `0x6`; §1.4).
* **Instruction Fetch:** Because the `C` extension is enabled, instruction addresses must be 2-byte aligned (standard 32-bit instructions may begin on any 2-byte boundary).
* **Stack Alignment:** Per `ILP32`, `sp` must remain **16-byte aligned** at function calls and `ecall` boundaries. `USER_STACK_TOP` (`0x2007_4000`) satisfies this requirement on entry.

#### Stack Headroom, Overflow & Underflow

Because Oasis32 has no virtual memory or hardware guard pages, stack bounds are not checked in hardware:

* **Stack Overflow (`sp` grows downward into `.bss`/heap/code):** Silently corrupts static variables, heap allocations, or program instructions. A hardware access fault (`mcause = 0x5`/`0x7`) only triggers if `sp` under-runs past `0x2000_0000` into the low reserved region.
* **Stack Underflow (`sp` pops above `USER_STACK_TOP`):** Because `VIDEO_RAM_BASE` begins immediately at `0x2007_4000`, writing above `USER_STACK_TOP` silently overwrites the top of `FRAMEBUF`—often appearing as stray lit pixels along the top-left scanlines of the display.
* **`ecall` Stack Usage:** Background interrupts never touch the user stack (§1.4), but synchronous `ecall` invocations temporarily use a small frame on the caller's stack (§4.1). Ensure `sp` points into valid User SRAM with adequate headroom before executing `ecall`.

### 2.3 Public Video Memory Block (`VIDEO_RAM_BASE`–`VIDEO_RAM_END`)

Public Video RAM is a contiguous **48 KB** (`49,152` bytes) read/write, data-only memory block spanning `0x2007_4000`–`0x2007_FFFF` (`VIDEO_RAM_BASE`..`VIDEO_RAM_END`, size `VIDEO_RAM_SIZE = 0x0000_C000`). It is partitioned with zero interior padding into six fixed buffers continuously scanned out at 60 Hz by the display subsystem.

| Sub-Region | Symbolic Constants (`memory_map.h`) | Address Range (Incl.) | Size (Bytes) | Size (Hex) | Alignment | Role & Spec |
|:---|:---|:---|---:|---:|:---:|:---|
| **Bitmap Framebuffer** | `VIDEO_FRAMEBUF_BASE` .. `VIDEO_FRAMEBUF_END`<br>`VIDEO_FRAMEBUF_SIZE` | `0x2007_4000`–`0x2007_D5FF` | `38,400` | `0x0000_9600` | 4 KB | 640×480 1 bpp bitmap (80 B/scanline). See §5.2. |
| **Programmable Font** | `VIDEO_FONT_RAM_BASE` .. `VIDEO_FONT_RAM_END`<br>`VIDEO_FONT_RAM_SIZE` | `0x2007_D600`–`0x2007_DDFF` | `2,048` | `0x0000_0800` | 512 B | 256 × 8-byte 8×8 glyphs (glyph-major, CP437 default). See §5.3. |
| **Text Overlay Grid** | `VIDEO_TEXT_BUF_BASE` .. `VIDEO_TEXT_BUF_END`<br>`VIDEO_TEXT_BUF_SIZE` | `0x2007_DE00`–`0x2007_F0BF` | `4,800` | `0x0000_12C0` | 512 B | 80×60 character cell grid, OR-composited over `FRAMEBUF`. See §5.3, §6.9. |
| **Video Control Block** | `VIDEO_CTRL_BASE` .. `VIDEO_CTRL_END`<br>`VIDEO_CTRL_SIZE` | `0x2007_F0C0`–`0x2007_F0FF` | `64` | `0x0000_0040` | 64 B | Display control flags (`LATCH_OAM` at `+0x00`; rest reserved). See §5.4.4. |
| **Sprite OAM Table** | `VIDEO_SPRITE_OAM_BASE` .. `VIDEO_SPRITE_OAM_END`<br>`VIDEO_SPRITE_OAM_SIZE` | `0x2007_F100`–`0x2007_F17F` | `128` | `0x0000_0080` | 256 B | 16 hardware sprite descriptors (8 B each). See §5.4.2. |
| **Sprite Pattern RAM** | `VIDEO_SPRITE_PAT_BASE` .. `VIDEO_SPRITE_PAT_END`<br>`VIDEO_SPRITE_PAT_SIZE` | `0x2007_F180`–`0x2007_FFFF` | `3,712` | `0x0000_0E80` | 128 B | 58 masked 16×16 2-plane sprite patterns (64 B each). See §5.4.1. |

#### Access Rules & Concurrency Notes
* **Standard Read/Write Data RAM:** All six sub-regions support normal byte, halfword, and word loads and stores (subject to the natural alignment rules in §2.2). Programs may read back their own writes at any time. Public Video RAM is strictly data-only—never branch to or execute instructions from it (§1.3).
* **Live Scanout Visibility:** Writes to `FRAMEBUF`, `FONT_RAM`, `TEXT_BUF`, and `SPRITE_PAT` are observed directly by the display scanner on subsequent scanlines. For tear-free updates, synchronize writes with `BIOS_VIDEO_WAIT_VSYNC` (§5.5). By contrast, `SPRITE_OAM` is latched once per frame during VBLANK by default (`VIDEO_CTRL_LATCH_OAM_BIT = 1`; §5.4.4).
* **Reserved `VIDEO_CTRL` Bytes:** Only `VIDEO_CTRL_FLAGS_OFF` (`+0x00`, bit 0) is defined in BIOS ABI `0.1.0`. Leave bytes `+0x01..+0x3F` untouched (or zero) for forward compatibility.
* **BIOS Coexistence:** `BIOS_BLK_TEXT` services (§6.9) operate directly on `TEXT_BUF`, and `BIOS_VIDEO_RESET_FONT` (§6.3) reloads `FONT_RAM`. Programs may freely mix direct writes to Video RAM with BIOS video/text calls.

### 2.4 Linking Against the Memory Map (`memory_map.h` & `sd_payload.ld.S`)

Rather than hardcoding SRAM or Video RAM addresses in assembly and linker scripts, Oasis32 programs consume the public headers under `include/abi/` as a single source of truth. All `include/abi/*.h` headers contain pure `#define` integer expressions and C-style comments—no GAS `.equ` directives, C types, or `U`/`UL` suffixes—so the same definitions can be `#include`d directly by both RISC-V `.S` sources (assembled via `gcc`) and preprocessed `.ld.S` linker script templates.

#### The Standard Linker Script (`include/ld/sd_payload.ld.S`)

Oasis32 provides a shared linker script template, `include/ld/sd_payload.ld.S`, that imports `abi/memory_map.h` and `abi/boot_header.h` to link standalone programs directly at `USER_RAM_BASE` (`0x2000_0000`) while automatically synthesizing the 32-byte `"OA32"` Boot Image Header (§3.1):

* **Zero-Boilerplate Boot Header:** The script places a `.boot_header` section immediately below User SRAM (`USER_RAM_BASE - 32` = `0x1FFF_FFE0`), populated with `BOOT_HEADER_MAGIC`, `__payload_start`, `_start`, `__payload_size`, a `0` placeholder for `crc32`, and 12 reserved zero bytes. When the linked ELF is flattened with `objcopy -Obinary` and post-processed (§7.2), the 32-byte header (with its patched IEEE CRC-32) lands at file offset `0` and the payload follows immediately at offset `32` (`0x20`) with zero padding, while every runtime symbol in the payload resolves 1:1 to its actual User SRAM address (`0x2000_0000+`).
* **Entry-Point Placement (`.text.entry` & `_start`):** The script declares `ENTRY(_start)` and wraps `*(.text.entry)` in `KEEP(...)` at the very start of `.text`. Place your startup routine in `.section .text.entry, "ax"` with a `.global _start` label so the linker emits it at `USER_RAM_BASE`, writes its address into the header's `entry_addr` field, and preserves it under link-time garbage collection.
* **Non-Loaded `.bss`:** The `.bss` section (including `.sbss` and `COMMON`) is marked `NOLOAD`, so uninitialized globals consume zero bytes in the `.oa32` disk image. Because the bootloader only copies `[__payload_start, __payload_end)`, `_start` is responsible for zeroing `[__bss_start, __bss_end)` before using `.bss` variables (§3.3).

#### Exported Linker Symbols

`sd_payload.ld.S` exports six symbols that assembly code can reference directly (for example, via `la`):

| Symbol | Value / Alignment | Purpose |
|:---|:---|:---|
| `__payload_start` | `USER_RAM_BASE` (`0x2000_0000`) | Inclusive start of loaded payload (`.text`, `.rodata`, `.data`). |
| `__payload_end` | End of `.data` (4-byte aligned) | Exclusive end of loaded payload bytes in the disk image. |
| `__payload_size` | `__payload_end - __payload_start` | Loaded payload byte length (written into the `"OA32"` header). |
| `__bss_start` | Start of `.bss` (4-byte aligned) | Inclusive start of uninitialized globals to be zeroed by `_start`. |
| `__bss_end` | End of `.bss` (4-byte aligned) | Exclusive end of `.bss`; also the natural base for an upward-growing heap. |
| `__stack_top` | `USER_STACK_TOP` (`0x2007_4000`) | Top of the user stack (16-byte aligned). |

Programs with specialized layouts are free to use a custom linker script instead of `sd_payload.ld.S`. Any image booted directly by the BIOS must satisfy User SRAM bounds (§2.2) and the `"OA32"` header format (§3.1); executables loaded later by an OS—or stored on non-bootable disks—may use any format the OS defines, provided they execute within User SRAM (§2.2). For the exact preprocessing, CMake, and CLI commands used to build `.oa32` images, see §7.1–§7.2.

---

## 3. Boot Process, Disk Image Format & Startup State

### 3.1 Bootable Disk Image Format (`"OA32"`)

Oasis32 uses a single, uniform raw binary **Bootable Disk Image Format** (conventionally `.oa32`) for both raw SD boot disks (starting at **LBA 0**) and raw binary serial transfers (§3.2). Non-bootable disks and executables loaded by an operating system are not required to use this format.

An `"OA32"` image consists of a **packed 32-byte little-endian Boot Image Header** followed immediately by `payload_size` raw payload bytes starting at byte offset `0x20` (`32`). All header constants are defined in `include/abi/boot_header.h`.

#### Binary Layout

| Byte Offset | Offset Constant (`boot_header.h`) | Size | Type | Field | Description |
|:---:|:---|:---:|:---:|:---|:---|
| `0x00` | `BOOT_HEADER_OFF_MAGIC` | 4 B | `uint32_t` | `magic` | Magic identifier `BOOT_HEADER_MAGIC` = `0x3233_414F` (ASCII `"OA32"`, byte order `0x4F, 0x41, 0x33, 0x32`). |
| `0x04` | `BOOT_HEADER_OFF_LOAD_ADDR` | 4 B | `uint32_t` | `load_addr` | Destination address in User SRAM where payload byte `0` is copied. |
| `0x08` | `BOOT_HEADER_OFF_ENTRY_ADDR` | 4 B | `uint32_t` | `entry_addr` | Target address in User SRAM jumped to after loading completes. |
| `0x0C` | `BOOT_HEADER_OFF_PAYLOAD_SZ` | 4 B | `uint32_t` | `payload_size` | Payload length in bytes (total image length minus `BOOT_HEADER_SIZE` = `32`). |
| `0x10` | `BOOT_HEADER_OFF_CRC32` | 4 B | `uint32_t` | `crc32` | Standard IEEE 802.3 CRC-32 (polynomial `0xEDB8_8320`, init `0xFFFF_FFFF`, final XOR `0xFFFF_FFFF`) computed over the `payload_size` raw payload bytes. |
| `0x14` | `BOOT_HEADER_OFF_RESERVED` | 12 B | `uint8_t[12]` | `reserved` | Reserved for future header extensions; must be zero (`0x00`) in ABI `0.1.0`. |
| `0x20` | `BOOT_HEADER_OFF_PAYLOAD` | `payload_size` B | `uint8_t[]` | `payload` | Raw payload bytes copied verbatim to `[load_addr, load_addr + payload_size)`. |

#### SD Card Sector Mapping

When stored on an SD card (512-byte sectors), the image starts at **LBA 0** with no partition table or filesystem wrapper required:

```text
LBA 0 (512 B):  [ 32-byte "OA32" Header (0x00..0x1F) ][ Payload bytes 0..479 (up to 480 B) ]
LBA 1 (512 B):  [ Payload bytes 480..991                                                   ]
  ...
LBA N (512 B):  [ Remaining payload bytes ... ][ Zero-padded tail (ignored by bootloader)  ]
LBA N+1 .. end: [ Untouched by BIOS — free for program/OS data or filesystem               ]
```

* **LBA 0 Split:** The first up to `480` payload bytes (`BOOT_HEADER_LBA0_PAYLOAD_MAX = 512 - 32`) share LBA 0 with the header; remaining bytes continue contiguously across LBA 1..N.
* **Sector Count & Padding:** A boot image spans `ceil((32 + payload_size) / 512)` = `(32 + payload_size + 511) / 512` sectors. Trailing bytes in the final sector are zero-padded when written by the BIOS serial writer (§3.2) and ignored when booting.
* **Remaining Disk Space:** Sectors after LBA N are never read or modified by the bootloader and are completely available to the booted program or OS.

#### Header & Integrity Validation Rules

Before transferring control (or writing to SD in Option `2`), the bootloader validates every field of the `"OA32"` header and verifies the payload checksum, rejecting the image (returning to the boot menu with an error message) if any check fails:

1. **Magic Match:** `magic == BOOT_HEADER_MAGIC` (`0x3233_414F`).
2. **Non-Empty Payload:** `payload_size > 0`.
3. **Load Range Within User SRAM (No Wrap-Around):** `load_addr >= USER_RAM_BASE`, `load_addr < USER_STACK_TOP`, and `payload_size <= USER_STACK_TOP - load_addr` — guaranteeing `[load_addr, load_addr + payload_size) ⊆ [USER_RAM_BASE, USER_STACK_TOP)` without 32-bit unsigned overflow.
4. **Valid Entry Point:** `entry_addr >= USER_RAM_BASE`, `entry_addr < USER_STACK_TOP`, and `(entry_addr & 1) == 0` (2-byte aligned per §2.2).
5. **Media Bounds (SD Boot / Write):** For SD operations, the required sector count `(32 + payload_size + 511) / 512` must not exceed the card's reported capacity.
6. **Payload Checksum Match:** The IEEE 802.3 CRC-32 computed over the loaded `payload_size` payload bytes must equal the header's `crc32` field.

*(Note: `.bss` is not represented in the `"OA32"` header; see §2.4 and §3.3.)*

### 3.2 Bootloader Interface & Startup Menu (User Guide)
*TODO: Provide complete user documentation for operating the interactive startup bootloader over the serial console (connecting a host terminal at 115,200 baud, 8N1, no flow control). Document the power-up splash screen, exact menu layout, and step-by-step usage for all four options: `ENTER` (boot from SD card), `1` (boot a raw binary `.oa32` disk image directly into User SRAM without touching the SD card), `2` (receive a raw binary `.oa32` image into User SRAM, validate header and CRC-32, and write it raw to an SD card starting at LBA 0), and `3` (run the built-in hardware diagnostic demo). Document interactive prompts (`"Insert boot disk"` / `"Insert disk to write"`), raw binary framing rules (stops automatically after `32 + payload_size` bytes; `ESC`/`Ctrl-C` cancels before byte 0 `'O'` arrives; idle timeout aborts stalled transfers), error messages, and recovery back to the boot menu. (Note: verify final exact prompt wording once Sub-Phase 3c is implemented.)*

### 3.3 Guaranteed Machine State at Entry (`_start`)

Immediately after validating the `"OA32"` header, loading the payload into `[load_addr, load_addr + payload_size)`, and verifying its IEEE CRC-32 checksum, the bootloader performs a clean peripheral handoff, synchronizes the instruction stream with `fence.i`, initializes the stack pointer, and jumps to `entry_addr`. Every Oasis32 program can rely on the following machine-state guarantees at its first instruction, regardless of whether it was auto-booted from SD, launched from the boot menu, or loaded over the serial port.

#### CPU & Register State

| Resource | Guaranteed State at Entry |
|:---|:---|
| **`pc`** | `entry_addr` from the `"OA32"` header (2-byte aligned, within User SRAM). |
| **`sp` (`x2`)** | `USER_STACK_TOP` (`0x2007_4000`), 16-byte aligned per `ILP32` (§2.2). |
| **`zero` (`x0`)** | Hardwired `0`. |
| **All other GPRs** (`ra`, `gp`, `tp`, `t0–t6`, `s0–s11`, `a0–a7`) | **Unspecified.** Programs must initialize any registers they depend on—including `gp`/`tp` if used—and must **not** treat `ra` as a valid return address (entry is a one-way jump; see §3.4). |
| **Instruction Coherence** | `fence.i` has already been executed after payload loading, so all instructions in `[load_addr, load_addr + payload_size)` are immediately visible to instruction fetch. |

#### Memory State & `.bss` Initialization

* **Loaded Payload:** `[load_addr, load_addr + payload_size)` contains the exact, CRC-32-verified payload bytes from the `"OA32"` image.
* **Unloaded User SRAM:** All bytes of User SRAM outside `[load_addr, load_addr + payload_size)` are **unspecified** and may contain leftover staging data from the bootloader.
* **Program `.bss` Responsibility:** Because `.bss` is marked `NOLOAD` and is not encoded in the 32-byte `"OA32"` header (§2.4, §3.1), **the program's `_start` routine is responsible for zeroing `[__bss_start, __bss_end)`** before reading any uninitialized static or global variables. When linked with `sd_payload.ld.S`, both symbols are 4-byte aligned, permitting a simple word-store zeroing loop.

#### Clean Peripheral & BIOS Handoff State

Before jumping to `entry_addr`, the bootloader resets all user-visible display, input, audio, indicator, and BIOS hook state to a clean baseline:

| Subsystem | Guaranteed State at Entry |
|:---|:---|
| **Bitmap Framebuffer (`FRAMEBUF`)** | Zero-filled (`0x00`; all 640×480 pixels black). |
| **Programmable Font (`FONT_RAM`)** | Default 256-glyph 8×8 IBM Code Page 437 font loaded (equivalent to `BIOS_VIDEO_RESET_FONT`). |
| **Text Overlay (`TEXT_BUF`)** | Zero-filled (`0x00`; all 80×60 cells transparent). |
| **Text Console Cursor** | Positioned at `(col = 0, row = 0)`, hidden (`vis = 0`, `blink = 0`). |
| **Video Control (`VIDEO_CTRL`)** | `VIDEO_CTRL_FLAGS_OFF` (`+0x00`) = `VIDEO_CTRL_LATCH_OAM_BIT` (`0x01`, frame-latched OAM mode enabled); reserved bytes `+0x01..+0x3F` = `0x00`. |
| **Hardware Sprites (`SPRITE_OAM`, `SPRITE_PAT`)** | Zero-filled (`0x00`; all 16 sprite slots disabled and all 58 patterns blank). |
| **Keyboard** | Event queue flushed (empty); typematic repeat restored to boot defaults (`delay = 500 ms`, `rate = 50 ms`). Live state (`BIOS_KEYBOARD_STATE`) reflects keys physically held at entry. |
| **Mouse** | Motion/wheel and button event queues flushed (empty); screen-space position centered at `(320, 240)`. Live button mask (`BIOS_MOUSE_STATE`) reflects buttons physically held at entry. |
| **Audio (Piezo Buzzer)** | Silenced (`AUDIO_FREQ_OFF = 0`). |
| **Status LEDs** | All three LEDs (`LED_RED`, `LED_GREEN`, `LED_BLUE`) turned off (`0`). |
| **OS `ecall` Hook** | Cleared (`0`); `ecall` invocations with `a7 >= 0x0100` return `ERR_UNSUPPORTED` (`-1`) until a handler is registered via `BIOS_SYS_SET_OS_ECALL_HANDLER` (§4.4). |
| **Serial Port** | Active at 115,200 baud, 8N1 (no hardware flow control). Programs sensitive to stray host input should drain any pending RX bytes with `BIOS_SERIAL_TRY_READ`. |
| **System Timer & VSYNC Counter** | Free-running continuously since hardware reset (non-zero monotonic values; **not** reset to `0` at entry). Measure elapsed durations by subtracting an initial reading from `BIOS_TIME_US` or `BIOS_VIDEO_FRAME_COUNT`. |

#### SD Card State (Boot-Path Dependent)

Unlike the peripherals above, SD card initialization state depends on how the program was launched:

* **Booted from SD Card** (auto-boot or menu `ENTER`): A card is seated and already initialized—`BIOS_SD_STATUS` reports `SD_STATUS_PRESENT | SD_STATUS_READY` (plus `SD_STATUS_SDHC` if applicable), so `BIOS_SD_READ` / `BIOS_SD_WRITE` may be issued immediately.
* **Booted over Serial** (menu `1`): An SD card may or may not be inserted or initialized.

For portability across both boot paths, programs that use SD block storage should query `BIOS_SD_STATUS` and call `BIOS_SD_INIT` whenever `SD_STATUS_READY` is clear before issuing block I/O.

### 3.4 Program Termination, Exit & Reboot Semantics

#### One-Way Entry (No Return to Bootloader)

Bootable `"OA32"` payloads are entered via a **one-way jump** to `entry_addr`. There is no caller frame on the stack, `ra` is unspecified (§3.3), and the BIOS does not provide a "return to boot menu" `ret` target.

* **Never `ret` from `_start`:** Executing `ret` or falling off the end of `_start` transfers control to an undefined address and typically triggers a synchronous fatal fault (§1.4).
* **OS-Loaded Programs:** An operating system running in User SRAM is free to define its own exit contract for child programs it loads (such as calling them with a valid `ra` or exposing an OS exit `ecall` at `a7 >= 0x0100`; §4.4), but standalone bootable images own the machine until reboot or reset.

#### Idling Cleanly

Because privileged instructions such as `wfi` are excluded from the Oasis32 ISA (§1.1), a program that has completed its work and wants to keep its output visible on screen should enter an explicit idle or event loop rather than attempting to halt the CPU directly:

* **Wait for User Action:** Block in a BIOS input service such as `BIOS_KEYBOARD_READ` (`0x30`) or `BIOS_SERIAL_READ` (`0x10`)—for example, prompting the user to press a key to restart—or pace a passive screen with `BIOS_VIDEO_WAIT_VSYNC` (`0x21`).
* **Infinite Loop:** A simple branch-to-self loop keeps the current `FRAMEBUF`, `TEXT_BUF`, and sprite state displayed indefinitely; background display refresh and input buffering continue running normally.

#### Software Reboot (`BIOS_SYS_REBOOT`)

To restart the machine cleanly under software control, invoke `BIOS_SYS_REBOOT` (`a7 = 0x01`; see §6.1):

* **Does Not Return:** `BIOS_SYS_REBOOT` performs a full hardware reset of the system and never returns to the caller.
* **Complete State Reset:** Prior User SRAM and Public Video RAM contents are not preserved and must be treated as lost; all internal peripherals and clocks re-initialize from scratch, the System ROM restarts from the beginning, and the normal startup sequence (splash, SD check, and boot menu) runs anew.

#### Hardware Reset Button

Pressing the physical Reset button on the machine performs an equivalent full hardware reset at any time—including when software is unresponsive, caught in an infinite loop, or halted after a synchronous runtime fault (§1.4).

---

## 4. BIOS ABI & Calling Contract

### 4.1 Invoking BIOS Services (`ecall`)

Oasis32 software invokes all resident BIOS services (and registered OS extensions; §4.4) using the standard RISC-V `ecall` instruction rather than calling hardcoded System ROM addresses. This keeps every disk image completely independent of the BIOS's internal layout in Flash.

#### Register Contract (`ILP32`)

Before executing `ecall`, load the service ID into `a7` and any required arguments into `a0–a5`. Upon return, execution resumes at the instruction immediately following `ecall` with the result in `a0` (and `a1–a5` for select multi-return services):

| Register(s) | ABI Role | Across `ecall` |
|:---|:---|:---|
| **`a7`** (`x17`) | **Service ID** (`0x0000`–`0x00FF` BIOS; `0x0100+` OS) | **Caller-saved** (may be clobbered; reload before each `ecall`). |
| **`a0–a5`** (`x10–x15`) | **Arguments** (up to 6 words) & **Return Values** (`a0`, plus `a1–a5` where documented) | **Caller-saved** (any register not listed as an output may be clobbered). |
| **`a6`** (`x16`), **`t0–t6`** (`x5–x7`, `x28–x31`) | Temporary / scratch registers | **Caller-saved** (may be clobbered). |
| **`s0–s11`** (`x8–x9`, `x18–x27`) | Saved registers | **Preserved** (guaranteed unchanged). |
| **`sp`** (`x2`), **`gp`** (`x3`), **`tp`** (`x4`) | Stack, global, and thread pointers | **Preserved** (guaranteed unchanged). |
| **`ra`** (`x1`) | Return address | **Preserved** (unlike `call`/`jal`, `ecall` does not overwrite `ra`). |

#### Stack, Pointer & Concurrency Rules

* **Caller Stack Headroom & Alignment:** While background hardware interrupts never touch the user stack (§1.4), synchronous `ecall` invocations temporarily allocate a small trap frame and service locals on the **caller's stack**. Before executing `ecall`, `sp` must point inside User SRAM, be **16-byte aligned** per `ILP32` (§2.2), and have at least **128 bytes** of free headroom below it (more if invoking nested OS extensions; §4.4).
* **Pointer Arguments:** Every non-null buffer, string, or callback pointer passed to a BIOS service must lie completely within User SRAM (`[USER_RAM_BASE, USER_STACK_TOP)`). Out-of-range pointers are rejected with `ERR_INVALID_ARG` (`-2`).
* **Live Background I/O:** Display refresh and background keyboard/mouse event capture remain continuously active during every BIOS call—including blocking waits (`BIOS_KEYBOARD_READ`, `BIOS_SERIAL_READ`, `BIOS_VIDEO_WAIT_VSYNC`) and longer block operations (`BIOS_SD_READ`, `BIOS_SD_WRITE`). Software will not drop display frames or buffered input events while inside an `ecall`.

### 4.2 Return Values & Standardized Error Codes
*TODO: Document the uniform signed-integer return convention in `a0` (`a0 >= 0` indicates success, `a0 < 0` indicates error, enabling single-instruction `bltz a0, ...` error checks), explicitly noting the infallible unsigned-counter exceptions (`BIOS_TIME_US`, `BIOS_VIDEO_FRAME_COUNT`, `BIOS_VIDEO_WAIT_VSYNC`) and non-returning `BIOS_SYS_REBOOT`. Tabulate all standardized error codes from `include/abi/bios_abi.h`: `ERR_OK (0)`, `ERR_UNSUPPORTED (-1)`, `ERR_INVALID_ARG (-2)`, `ERR_EMPTY (-3)`, `ERR_BUSY (-4)`, `ERR_IO (-5)`, and `ERR_NO_DEVICE (-6)`.*

### 4.3 Service ID Partitioning & Subsystem Blocks
*TODO: Document the split between Resident BIOS services (`0x0000`–`0x00FF`) and OS extensions (`0x0100+`), and provide a compact index of the 16-ID subsystem blocks (`0x00` `BIOS_BLK_SYS` through `0x80` `BIOS_BLK_TEXT`, plus `0x90–0xFF` Reserved) cross-referencing §6.1–§6.9 (avoiding duplication of the capability descriptions in §1.2).*

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
*TODO: Explain tear-free 60 Hz animation pacing using `BIOS_VIDEO_FRAME_COUNT` and `BIOS_VIDEO_WAIT_VSYNC`, and cross-reference §6.3 for exact syscall signatures.*

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
- *Using the project's `oasis32_add_disk_executable()` helper in `cmake/oasis32.cmake` (which automatically enforces the `oasis32_abi` boundary, preprocesses `sd_payload.ld.S`, emits `.elf`, `.dis`, `.map`, and `.oa32`, and patches the IEEE CRC-32 into the 32-byte header).*
- *A standalone manual CLI sequence (`gcc -E -P -x c` to preprocess `sd_payload.ld.S`, `gcc` to assemble/link, `objcopy -Obinary` to emit `.oa32`, and patching the header's `crc32` field at offset `0x10`) for programmers building outside CMake.*
*Briefly cross-reference §2.4 and §3.3 for `_start` entry placement and `.bss` zeroing requirements.*

### 7.3 Sending Disk Images Over Serial
*TODO: Provide step-by-step host-side instructions for streaming a raw binary `.oa32` image to Oasis32 over the 115,200 baud 8N1 USB-C serial port (cross-referencing §3.2 for bootloader menu Options `1` and `2`, cancel/timeout rules, and CRC-32 verification). Include practical examples for common host environments (Tera Term `File → Send file...` with Binary mode enabled on Windows, RealTerm, PowerShell / Python `pyserial`, or macOS / Linux raw serial device writes) and troubleshooting tips (ensuring 115,200 8N1, no flow control / XON-XOFF disabled, raw binary mode with no LF→CRLF translation, and verifying transfer completion).*

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
