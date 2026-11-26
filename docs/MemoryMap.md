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
| `0x2007_4000`–`0x2007_FFFF` | 48 KB | Main SRAM (Bank 7) | **Public** | **Video Memory** (`FRAMEBUF`, `FONT_RAM`, `TEXT_BUF`, `VIDEO_CTRL`, `SPRITE_OAM`, `SPRITE_PAT`). | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x2008_0000`–`0x2008_0FFF` | 4 KB | Scratchpad Bank 8 | Private | **Core 0 BIOS IRQ stack** (`mscratch`) & boot stack. | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x2008_1000`–`0x2008_1FFF` | 4 KB | Scratchpad Bank 9 | Private | **Core 1 Video Coprocessor** ping-pong lines & stack. | `rp2350-datasheet.pdf §4.2, p. 312` |
| `0x4000_0000`–`0x4016_FFFF` | 1.5 MB | APB Peripherals | Private | `CLOCKS`, `RESETS`, `IO`/`PADS`, `UART0/1`, `SPI0`, `PWM`, `TIMER0`. | `rp2350-datasheet.pdf §2.2.4, p. 28` |
| `0x5010_0000`–`0x5010_0FFF` | 4 KB | USB DPRAM (AHB) | Private | **BIOS Private State** & driver buffers (data-only, USB disabled). | `rp2350-datasheet.pdf §12.7.1.1.3, p. 1058` |
| `0x5000_0000`–`0x507F_FFFF` | 8 MB | AHB Peripherals | Private | `DMA`, `HSTX`, `PIO0–2`, `USB` (DPRAM above), `QMI`. | `rp2350-datasheet.pdf §2.2.5, p. 29` |
| `0xD000_0000`–`0xD001_FFFF` | 128 KB | SIO (Per-Core) | Private | Single-cycle GPIO, inter-core FIFOs, spinlocks. | `rp2350-datasheet.pdf §3.1, p. 34` |

*\*The XIP cached window spans 64 MB (`0x1000_0000`–`0x13FF_FFFF`); the Pico 2 populates 4 MB of external QSPI flash.*

---

## 2. Detailed 520 KB SRAM Map (`0x2000_0000`–`0x2008_1FFF`)

```text
0x2008_2000 ┌──────────────────────────────────────────────────────────────┐
            │ Scratchpad Bank 9 (4 KB, non-striped) — BIOS PRIVATE         │
            │   0x2008_1280–0x2008_1FFF  Core 1 Stack (sp = 0x2008_2000 ↓) │
            │   0x2008_1200–0x2008_127F  Latched OAM copy (128 B)          │
            │   0x2008_10A0–0x2008_11FF  HSTX DMA cmd lists & Core 1 state │
            │   0x2008_1000–0x2008_109F  Ping-Pong Scanlines (2 × 80 B)    │
0x2008_1000 ├──────────────────────────────────────────────────────────────┤
            │ Scratchpad Bank 8 (4 KB, non-striped) — BIOS PRIVATE         │
            │   0x2008_0000–0x2008_0FFF  Core 0 IRQ Stack (mscratch ↓)     │
0x2008_0000 ╞══════════════════════════════════════════════════════════════╡
            │ Public Video Memory Block (48 KB = 49,152 B) — PUBLIC ABI    │
            │   0x2007_F180–0x2007_FFFF  SPRITE_PAT (58×64 B = 3,712 B)    │
            │   0x2007_F100–0x2007_F17F  SPRITE_OAM (16×8 B = 128 B)       │
            │   0x2007_F0C0–0x2007_F0FF  VIDEO_CTRL (64 B)                 │
            │   0x2007_DE00–0x2007_F0BF  TEXT_BUF   (80×60 = 4,800 B)      │
            │   0x2007_D600–0x2007_DDFF  FONT_RAM   (256×8 = 2,048 B)      │
            │   0x2007_4000–0x2007_D5FF  FRAMEBUF   (640×480 = 38,400 B)   │
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
| `VIDEO_CTRL_BASE` | `0x2007_F0C0` | `0x2007_F0FF` | `64` | `0x0000_0040` | 64 B | Public video control/status block (`LATCH_OAM`, future scroll/cursor fields). |
| `VIDEO_SPRITE_OAM_BASE` | `0x2007_F100` | `0x2007_F17F` | `128` | `0x0000_0080` | 256 B | `16` simultaneous on-screen sprite slots (`8` B each; Sprite 0 conventionally mouse cursor). |
| `VIDEO_SPRITE_PAT_BASE` | `0x2007_F180` | `0x2007_FFFF` | `3,712` | `0x0000_0E80` | 128 B | `58` masked `16×16` 2-plane sprite patterns (`64` B each: 32 B pixels + 32 B mask). |

* **Why `FONT_RAM` precedes `TEXT_BUF`:** Placing `FONT_RAM` (`0x0800`) immediately after `FRAMEBUF` (`0x9600`) keeps all three public video buffers aligned on clean **512-byte** (or 4 KB) boundaries with zero interior padding.
* **Bootloader Bounds Check:** Both SD boot (`ENTER`) and serial boot (`1`) validate that `load_addr >= USER_RAM_BASE`, `entry_addr >= USER_RAM_BASE`, `entry_addr < USER_RAM_END`, and `load_addr + payload_size <= USER_RAM_END` (checking for 32-bit wrap-around) before copying any payload bytes.

---

### 2.2 BIOS-Private State in USB DPRAM (`0x5010_0000`–`0x5010_0FFF`, `bios/internal/bios_ram.h`)

Because Oasis32 uses the CH9350 ASIC for keyboard/mouse and CP2102N for serial, the RP2350's on-chip USB controller remains disabled and its **4,096-byte dual-port SRAM (`USBCTRL_DPRAM_BASE = 0x5010_0000`)** is available as general-purpose data RAM (`rp2350-datasheet.pdf §12.7.1.1.3, pp. 1058–1059`).

* **Hardware properties:** Accessible by Core 0, Core 1, and DMA over AHB5 with zero Main SRAM bank contention; supports 8/16/32-bit reads (2 cycles) and writes (1 cycle); strictly **non-executable** (data-only, `§4.2.1, p. 312`).
* **Startup requirement:** Deassert `USBCTRL` in `RESETS->RESET` and poll `RESETS->RESET_DONE` before accessing `0x5010_0000` (the USB controller stays disabled; `PLL_USB`/`clk_usb` are not needed).
* **Architectural payoff:** Moving all BIOS-private driver state into USB DPRAM physically isolates BIOS variables from User SRAM/Video RAM and leaves **100% of the 512 KB Main SRAM** user-facing (464 KB User SRAM + 48 KB Video & Future Sprite Reserve).

| Sub-Region | Address Range | Size | Purpose |
|:---|:---|---:|:---|
| SD Sector Staging Buffer | `0x5010_0000`–`0x5010_01FF` | 512 B | Single-sector buffer for reading LBA 0 (`"OA32"` header + first 496 payload bytes) and BIOS SD helpers. |
| CH9350 HID State (`UART1`) | `0x5010_0200`–`0x5010_03FF` | 512 B | 11-byte State-2 packet assembler, active 8-byte keyboard report, key-event ring buffer, and accumulated mouse deltas (`dX`, `dY`, `wheel`, buttons). |
| Debug Serial State (`UART0`) | `0x5010_0400`–`0x5010_04FF` | 256 B | Optional interrupt-driven RX ring buffer & state (backing the PL011's 32-byte hardware FIFOs). |
| Video Control / Sync Block | `0x5010_0500`–`0x5010_053F` | 64 B | Shared Core 1 → Core 0 status (`vsync_count`, plus room for future cursor/scroll/OAM flags). |
| Misc Driver State | `0x5010_0540`–`0x5010_05FF` | 192 B | SD `CCS`/capacity flags, LED shadow bits, piezo state, boot flags, BIOS runtime scratch. |
| BIOS Growth Headroom | `0x5010_0600`–`0x5010_0FFF` | 2,560 B | Unallocated private reserve (2.5 KB) for future BIOS features without touching Main SRAM. |

---

### 2.3 Scratchpad SRAM — Banks 8 & 9 (`bios/internal/bios_ram.h`)

Unlike Main SRAM Banks 0–7 (which are 4-way word-striped across AHB masters), **Banks 8 and 9 are non-striped 4 KB SRAM blocks** (`rp2350-datasheet.pdf §4.2, p. 312`), giving each core contention-free private access:

| Bank | Address Range | Size | Owner & Contents |
|:---|:---|---:|:---|
| **Bank 8** | `0x2008_0000`–`0x2008_0FFF` | 4,096 B | **Core 0 BIOS IRQ Stack (`mscratch` = `0x2008_1000` ↓).** Also serves as Core 0's boot/menu stack prior to transferring control to a Stage-2 payload. |
| **Bank 9** | `0x2008_1000`–`0x2008_109F` | 160 B | **Core 1 Ping-Pong Scanline Buffers:** Buffer A (`0x2008_1000`–`0x2008_104F`, 80 B) and Buffer B (`0x2008_1050`–`0x2008_109F`, 80 B). |
| **Bank 9** | `0x2008_10A0`–`0x2008_11FF` | 352 B | **Core 1 HSTX DMA Command Lists** (vertical/horizontal blanking & sync command words) and Core 1 local driver state. |
| **Bank 9** | `0x2008_1200`–`0x2008_127F` | 128 B | **Core 1 Latched OAM Copy:** Frame-latched mirror of `SPRITE_OAM` copied during VBLANK when `VIDEO_CTRL.LATCH_OAM = 1`. |
| **Bank 9** | `0x2008_1280`–`0x2008_1FFF` | 3,456 B | **Core 1 Video Coprocessor Stack (`sp` = `0x2008_2000` ↓).** |

---

## 3. Three-Stack Architecture & Overflow Behavior

Unlike a 6502 (where hardware forces IRQs onto the single `$0100–$01FF` stack), RISC-V hardware never touches `sp` on a trap—it saves `PC` in `mepc` (`riscv-privileged.pdf §3.1.11, p. 52`) and status in `mstatus` (`§3.1.6, p. 38`), allowing Oasis32 to isolate each execution context onto its own downward-growing, 16-byte-aligned stack:

| Stack | Initial `sp` (Top) | Floor | Size | Typical Usage | Overflow Behavior (↓) | Underflow Behavior (↑) |
|:---|:---|:---|---:|:---|:---|:---|
| **Core 0 User Stack** *(also used by `ecall`)* | `0x2007_4000` | Dynamic (above payload `.bss`/heap) | Up to **464 KB** (shared with program) | A few KB–tens of KB (plus ~64–128 B during `ecall`) | **Silent corruption** of user `.bss`/heap/code (bus fault only if wrapping below `0x2000_0000`). | **Silent corruption** of `FRAMEBUF` (`0x2007_4000`+), visible as stray pixels at top-left of screen. |
| **Core 0 BIOS IRQ & Boot Stack** *(held in `mscratch`)* | `0x2008_1000` | `0x2008_0000` | **4,096 B** (4 KB) | < 128 B in non-nested IRQs; ~256–512 B during boot menu | **Silent corruption** into the top of `SPRITE_PAT` (`0x2007_FFFF` ↓, never touching BIOS state in USB DPRAM). | **Silent corruption** into Bank 9 (`0x2008_1000`+), clobbering Core 1's ping-pong scanline buffers. |
| **Core 1 Video Coprocessor Stack** | `0x2008_2000` | `0x2008_1280` | **3,456 B** (3.38 KB) | < 128 B (flat, non-recursive scanline loop) | **Silent corruption** into Core 1's latched OAM copy (`0x2008_1200`–`0x2008_127F`), HSTX command lists, and ping-pong buffers, glitching video. | **Hardware bus fault!** `0x2008_2000` is unmapped AHB space above SRAM → Load/Store Access Fault (`mcause = 5/7`, `riscv-privileged.pdf §3.1.12, p. 53`). |

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

* **Total On-Chip RAM Used:** `524 KB` (`536,576` B) = `512 KB` Main SRAM + `8 KB` Scratchpad SRAM + `4 KB` USB DPRAM.
* **Main SRAM (512 KB — 100% Public / User-Facing):** `464 KB` contiguous User SRAM + `48 KB` Public Video Memory (`FRAMEBUF`, `FONT_RAM`, `TEXT_BUF`, `VIDEO_CTRL`, `SPRITE_OAM`, `SPRITE_PAT`). Zero BIOS-private data lives in Main SRAM.
* **Strictly BIOS-Private (`12 KB` total):** `8 KB` Scratchpad SRAM (Banks 8–9 stacks & Core 1 scanline buffers) + `4 KB` USB DPRAM (`0x5010_0000`–`0x5010_0FFF`, all BIOS driver state & buffers).
* **Single Source of Truth:** All public constants live in `include/abi/memory_map.h` (consumed by both `bios/` and `disks/` via preprocessed `.ld.S` scripts); all private offsets live in `bios/internal/bios_ram.h` and `bios/internal/bios_flash.h`.
