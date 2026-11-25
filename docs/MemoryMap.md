# Oasis32 — Internal System Memory Map

> [!NOTE]
> This is an **inward-facing architectural reference** covering both the public Oasis32 ABI regions (`include/abi/memory_map.h`) and BIOS-private RP2350 silicon internals (`bios/internal/bios_ram.h`, `bios/internal/bios_flash.h`). The user-facing `docs/ProgrammersReference.md` will expose only the public User SRAM and Video Buffer contracts.

---

## 1. Top-Level RP2350 Physical Address Space

The RP2350 decodes top-level bus destinations on `addr[31:28]` across its AHB5 crossbar (`rp2350-datasheet.pdf §2.2, pp. 25–31`; `§4.2, p. 312`):

| Physical Range | Size | Subsystem | Visibility | Role in Oasis32 | Datasheet Citation |
|:---|:---:|:---|:---:|:---|:---|
| `0x0000_0000`–`0x0000_7FFF` | 32 KB | Silicon Boot ROM | Private | Stage-0 mask ROM (`BOOTSEL` / `PICOBIN` loader). | `rp2350-datasheet.pdf §2.2.1, p. 26` |
| `0x1000_0000`–`0x103F_FFFF` | 4 MB* | XIP Cached Flash | Private | Stage-1 System ROM / BIOS (Execute-In-Place). | `rp2350-datasheet.pdf §2.2.2, p. 26` |
| `0x2000_0000`–`0x2007_3FFF` | 464 KB | Main SRAM (Banks 0–7) | **Public** | Contiguous **User SRAM** (Stage-2 code, data, stack). | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x2007_4000`–`0x2007_F0BF` | ~44.2 KB | Main SRAM (Bank 7) | **Public** | Shared **Video Buffers** (`FRAMEBUF`, `FONT_RAM`, `TEXT_BUF`). | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x2007_F0C0`–`0x2007_FFFF` | ~3.8 KB | Main SRAM (Bank 7) | Private | **BIOS Private State** & driver buffers. | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x2008_0000`–`0x2008_0FFF` | 4 KB | Scratchpad Bank 8 | Private | **Core 0 BIOS IRQ stack** (`mscratch`) & boot stack. | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x2008_1000`–`0x2008_1FFF` | 4 KB | Scratchpad Bank 9 | Private | **Core 1 Video Coprocessor** ping-pong lines & stack. | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x4000_0000`–`0x4016_FFFF` | 1.5 MB | APB Peripherals | Private | `CLOCKS`, `RESETS`, `IO`/`PADS`, `UART0/1`, `SPI0`, `PWM`, `TIMER0`. | `rp2350-datasheet.pdf §2.2.4, p. 28` |
| `0x5000_0000`–`0x507F_FFFF` | 8 MB | AHB Peripherals | Private | `DMA`, `HSTX`, `PIO0–2`, `USB`, `QMI`. | `rp2350-datasheet.pdf §2.2.5, p. 29` |
| `0xD000_0000`–`0xD001_FFFF` | 128 KB | SIO (Per-Core) | Private | Single-cycle GPIO, inter-core FIFOs, spinlocks. | `rp2350-datasheet.pdf §3.1, p. 34` |

*\*The XIP cached window spans 64 MB (`0x1000_0000`–`0x13FF_FFFF`); the Pico 2 populates 4 MB of external QSPI flash.*

---

## 2. Detailed 520 KB SRAM Map (`0x2000_0000`–`0x2008_1FFF`)

```text
0x2008_2000 ┌──────────────────────────────────────────────────────────────┐
            │ Scratchpad Bank 9 (4 KB, non-striped) — BIOS PRIVATE         │
            │   0x2008_1200–0x2008_1FFF  Core 1 Stack (sp = 0x2008_2000 ↓) │
            │   0x2008_10A0–0x2008_11FF  HSTX DMA cmd lists & Core 1 state │
            │   0x2008_1000–0x2008_109F  Ping-Pong Scanlines (2 × 80 B)    │
0x2008_1000 ├──────────────────────────────────────────────────────────────┤
            │ Scratchpad Bank 8 (4 KB, non-striped) — BIOS PRIVATE         │
            │   0x2008_0000–0x2008_0FFF  Core 0 IRQ Stack (mscratch ↓)     │
0x2008_0000 ╞══════════════════════════════════════════════════════════════╡
            │ BIOS Private State (3,840 B + 64 B pad) — BIOS PRIVATE       │
            │   0x2007_F700–0x2007_FFFF  BIOS growth headroom (2,304 B)    │
            │   0x2007_F640–0x2007_F6FF  Misc driver state (192 B)         │
            │   0x2007_F600–0x2007_F63F  Video control / vsync_count (64 B)│
            │   0x2007_F500–0x2007_F5FF  UART0 state / RX ring (256 B)     │
            │   0x2007_F300–0x2007_F4FF  CH9350 HID / key ring (512 B)     │
            │   0x2007_F100–0x2007_F2FF  SD 1-sector staging buffer (512 B)│
            │   0x2007_F0C0–0x2007_F0FF  Alignment padding (64 B)          │
0x2007_F0C0 ├──────────────────────────────────────────────────────────────┤
            │ Shared Video Buffers (45,248 B) — PUBLIC ABI                 │
            │   0x2007_DE00–0x2007_F0BF  TEXT_BUF  (80×60 = 4,800 B)       │
            │   0x2007_D600–0x2007_DDFF  FONT_RAM  (256×8 = 2,048 B)       │
            │   0x2007_4000–0x2007_D5FF  FRAMEBUF  (640×480 1bpp = 38,400 B│
0x2007_4000 ╞══════════════════════════════════════════════════════════════╡ ◀ USER_STACK_TOP
            │                                                              │
            │  User SRAM — PUBLIC ABI (464 KB = 475,136 bytes = 0x74000)   │
            │  Contiguous, 4-way word-striped Main SRAM (Banks 0–7)        │
            │                                                              │
            │   • Stage-2 payload .text / .rodata / .data / .bss           │
            │   • Dynamic heap (grows upward)                              │
            │   • User stack (starts at 0x2007_4000, grows downward)       │
            │   • (Temporarily used by BIOS Option 2 serial-to-SD buffer)  │
            │                                                              │
0x2000_0000 └──────────────────────────────────────────────────────────────┘ ◀ USER_RAM_BASE
```

### 2.1 Public ABI Regions (`include/abi/memory_map.h`)

| Symbolic Constant | Start Address | End Address (Incl.) | Size (Bytes) | Size (Hex) | Alignment | Notes |
|:---|:---|:---|---:|---:|:---:|:---|
| `USER_RAM_BASE` .. `USER_RAM_END` | `0x2000_0000` | `0x2007_3FFF` | `475,136` | `0x0007_4000` | 4 KB | 464 KB contiguous User SRAM. `USER_STACK_TOP = 0x2007_4000` (16-byte aligned per `ILP32` psABI). |
| `VIDEO_FRAMEBUF_BASE` | `0x2007_4000` | `0x2007_D5FF` | `38,400` | `0x0000_9600` | 4 KB | `640×480` 1 bpp monochrome framebuffer (`80` bytes/scanline). |
| `VIDEO_FONT_RAM_BASE` | `0x2007_D600` | `0x2007_DDFF` | `2,048` | `0x0000_0800` | 512 B | `256` glyphs × `8` bytes, glyph-major (`FONT_RAM[ch * 8 + row]`), glyph `0x00` empty. |
| `VIDEO_TEXT_BUF_BASE` | `0x2007_DE00` | `0x2007_F0BF` | `4,800` | `0x0000_12C0` | 512 B | `80×60` character overlay grid (`row * 80 + col`), OR-composited onto `FRAMEBUF`. |

* **Why `FONT_RAM` precedes `TEXT_BUF`:** Placing `FONT_RAM` (`0x0800`) immediately after `FRAMEBUF` (`0x9600`) keeps all three public video buffers aligned on clean **512-byte** (or 4 KB) boundaries with zero interior padding.
* **Bootloader Bounds Check:** Both SD boot (`ENTER`) and serial boot (`1`) validate that `load_addr >= USER_RAM_BASE`, `entry_addr >= USER_RAM_BASE`, `entry_addr < USER_RAM_END`, and `load_addr + payload_size <= USER_RAM_END` (checking for 32-bit wrap-around) before copying any payload bytes.

---

### 2.2 BIOS-Private Main SRAM (`bios/internal/bios_ram.h`)

Reserved at the top of Main SRAM (`0x2007_F0C0`–`0x2007_FFFF`, `3,904` bytes total = `64` B pad + `3,840` B state):

| Sub-Region | Address Range | Size | Purpose |
|:---|:---|---:|:---|
| Alignment Pad | `0x2007_F0C0`–`0x2007_F0FF` | 64 B | Aligns BIOS private block to 256-byte boundary. |
| SD Sector Staging Buffer | `0x2007_F100`–`0x2007_F2FF` | 512 B | Single-sector buffer for reading LBA 0 (`"OA32"` header + first 496 payload bytes) and BIOS SD helpers. |
| CH9350 HID State (`UART1`) | `0x2007_F300`–`0x2007_F4FF` | 512 B | 11-byte State-2 packet assembler, active 8-byte keyboard report, key-event ring buffer, and accumulated mouse deltas (`dX`, `dY`, `wheel`, buttons). |
| Debug Serial State (`UART0`) | `0x2007_F500`–`0x2007_F5FF` | 256 B | Optional interrupt-driven RX ring buffer & state (backing the PL011's 32-byte hardware FIFOs). |
| Video Control / Sync Block | `0x2007_F600`–`0x2007_F63F` | 64 B | Shared Core 1 → Core 0 status (`vsync_count`, plus room for future cursor/scroll fields). |
| Misc Driver State | `0x2007_F640`–`0x2007_F6FF` | 192 B | SD `CCS`/capacity flags, LED shadow bits, piezo state, boot flags, BIOS runtime scratch. |
| BIOS Growth Headroom | `0x2007_F700`–`0x2007_FFFF` | 2,304 B | Unallocated reserve so future BIOS updates never shift `USER_RAM_END` or break existing boot disks. |

---

### 2.3 Scratchpad SRAM — Banks 8 & 9 (`bios/internal/bios_ram.h`)

Unlike Main SRAM Banks 0–7 (which are 4-way word-striped across AHB masters), **Banks 8 and 9 are non-striped 4 KB SRAM blocks** (`rp2350-datasheet.pdf §4.2, p. 312`), giving each core contention-free private access:

| Bank | Address Range | Size | Owner & Contents |
|:---|:---|---:|:---|
| **Bank 8** | `0x2008_0000`–`0x2008_0FFF` | 4,096 B | **Core 0 BIOS IRQ Stack (`mscratch` = `0x2008_1000` ↓).** Also serves as Core 0's boot/menu stack prior to transferring control to a Stage-2 payload. |
| **Bank 9** | `0x2008_1000`–`0x2008_109F` | 160 B | **Core 1 Ping-Pong Scanline Buffers:** Buffer A (`0x2008_1000`–`0x2008_104F`, 80 B) and Buffer B (`0x2008_1050`–`0x2008_109F`, 80 B). |
| **Bank 9** | `0x2008_10A0`–`0x2008_11FF` | 352 B | **Core 1 HSTX DMA Command Lists** (vertical/horizontal blanking & sync command words) and Core 1 local driver state. |
| **Bank 9** | `0x2008_1200`–`0x2008_1FFF` | 3,584 B | **Core 1 Video Coprocessor Stack (`sp` = `0x2008_2000` ↓).** |

---

## 3. Three-Stack Architecture & Overflow Behavior

Unlike a 6502 (where hardware forces IRQs onto the single `$0100–$01FF` stack), RISC-V hardware never touches `sp` on a trap—it saves `PC` in `mepc` (`riscv-privileged.pdf §3.1.11, p. 52`) and status in `mstatus` (`§3.1.6, p. 38`), allowing Oasis32 to isolate each execution context onto its own downward-growing, 16-byte-aligned stack:

| Stack | Initial `sp` (Top) | Floor | Size | Typical Usage | Overflow Behavior (↓) | Underflow Behavior (↑) |
|:---|:---|:---|---:|:---|:---|:---|
| **Core 0 User Stack** *(also used by `ecall`)* | `0x2007_4000` | Dynamic (above payload `.bss`/heap) | Up to **464 KB** (shared with program) | A few KB–tens of KB (plus ~64–128 B during `ecall`) | **Silent corruption** of user `.bss`/heap/code (bus fault only if wrapping below `0x2000_0000`). | **Silent corruption** of `FRAMEBUF` (`0x2007_4000`+), visible as stray pixels at top-left of screen. |
| **Core 0 BIOS IRQ & Boot Stack** *(held in `mscratch`)* | `0x2008_1000` | `0x2008_0000` | **4,096 B** (4 KB) | < 128 B in non-nested IRQs; ~256–512 B during boot menu | **Silent corruption** into top of BIOS Private State (`0x2007_FFFF` ↓, hitting growth headroom first). | **Silent corruption** into Bank 9 (`0x2008_1000`+), clobbering Core 1's ping-pong scanline buffers. |
| **Core 1 Video Coprocessor Stack** | `0x2008_2000` | `0x2008_1200` | **3,584 B** (3.5 KB) | < 128 B (flat, non-recursive scanline loop) | **Silent corruption** into Core 1 HSTX DMA command lists (`0x2008_10A0`–`0x2008_11FF`) and ping-pong line buffers, glitching video. | **Hardware bus fault!** `0x2008_2000` is unmapped AHB space above SRAM → Load/Store Access Fault (`mcause = 5/7`, `riscv-privileged.pdf §3.1.12, p. 53`). |

### Design Rationale & Fault Detection
* **Why three stacks?**
  1. **Core 1 Stack** is physically mandatory because Core 1 executes concurrently with Core 0.
  2. **Core 0 BIOS IRQ Stack (`mscratch`)** swaps in via `csrrw sp, mscratch, sp` (1 cycle on entry/exit, `riscv-privileged.pdf §3.1.10, p. 52`), keeping the ~72-byte RISC-V IRQ save frame off the user's stack, protecting BIOS from user stack bugs, and doubling as the Core 0 boot stack so Boot Menu Option 2 can freely stage incoming images across all 464 KB of User SRAM.
* **Adequacy:** Both BIOS stacks (4 KB and 3.5 KB) provide **~8×–30× headroom** over worst-case call depth; the User Stack shares up to 464 KB with the Stage-2 payload.
* **No Hardware Guard Pages in M-Mode:** Because Oasis32 runs in M-mode without an MMU or active PMP guard regions, stack overflows and most underflows **silently corrupt adjacent memory** rather than raising a hardware fault (just as on classic 8-bit machines). During BIOS bring-up/debugging, optional software **stack canaries** (pre-filling Banks 8–9 with a sentinel word like `0xDEADBEEF`) can be used to verify high-water marks.

---

## 4. XIP Flash Layout (`0x1000_0000`–`0x103F_FFFF`, 4 MB)

The Stage-1 System ROM executes directly from external QSPI Flash via the 16 KB 2-way XIP cache (`rp2350-datasheet.pdf §2.2.2, p. 26`), controlled by `bios/ld/bios.ld.S` and `bios/internal/bios_flash.h`:

| Offset from `0x1000_0000` | Contents | Architectural Constraint |
|:---|:---|:---|
| `0x0000`–`0x0FFF` (first 4 KB) | Reset entry (`_start`), `PICOBIN` `IMAGE_DEF` metadata block, and **Vectored `mtvec` table** | RP2350 Silicon Boot ROM scans the first 4 KB of Flash for a valid `IMAGE_DEF` (`rp2350-datasheet.pdf §5.9.5, p. 363`). Vectored `mtvec` base must be 256-byte aligned (`riscv-privileged.pdf §3.1.7, p. 45`). |
| Following `.text` | Core 0 BIOS bring-up, `ecall` ABI dispatcher, peripheral drivers, interactive boot menu / Base64 serial loader, SD bootloader, and Core 1 Video Coprocessor code | Pure XIP code; never referenced by hardcoded address from Stage-2 payloads (all calls go through `ecall`). |
| Following `.rodata` | Boot splash / menu strings, `ecall` dispatch jump table, and default 2 KB `8×8` boot font (copied to `FONT_RAM` at startup) | Immutable read-only data in Flash. |

---

## 5. Memory Ownership & Striping Summary

* **Total Physical SRAM:** `520 KB` (`532,480` B) = `512 KB` Main + `8 KB` Scratchpad.
* **Total Publicly Usable by Stage-2 Software:** `464 KB` User SRAM + `44.19 KB` Video Buffers = **`508.19 KB` (~97.7% of total SRAM)**.
* **Total Strictly BIOS-Private:** `3.81 KB` (Main SRAM top) + `8 KB` (Scratchpad Banks 8–9) = **`11.81 KB` (~2.3% of total SRAM)**.
* **Single Source of Truth:** All public constants live in `include/abi/memory_map.h` (consumed by both `bios/` and `disks/` via preprocessed `.ld.S` scripts); all private offsets live in `bios/internal/bios_ram.h` and `bios/internal/bios_flash.h`.
