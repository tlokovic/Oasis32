# Oasis32 — Video Architecture (Core 1 Video Coprocessor)

## 1. Philosophy: A Dedicated "Video Chip" with No Mode Switching

Classic 8-bit microcomputers (like the Commodore 64's VIC-II or the Atari 800's ANTIC) paired the main CPU with a dedicated video processor that scanned RAM and generated the display signal autonomously. **Oasis32** recreates this architecture in silicon by dedicating **RP2350 Core 1** (`rp2350-datasheet.pdf §3.8, p. 227`) exclusively to the Stage-1 System ROM as a permanent, Flash-resident **Video Coprocessor (PPU / CRTC)**.

* **Invisible to Oasis32 Software:** To software running on Core 0 (and in `docs/ProgrammersReference.md`), Oasis32 remains a strictly **single-core** computer. Core 1 is treated as hidden display hardware—never exposed as a second general-purpose CPU.
* **Zero Core 0 Overhead:** Because Core 1 owns `HSTX` (`rp2350-datasheet.pdf §12.11, pp. 1114–1122`) and its DMA scanline interrupts, Core 0 spends **0% of its cycles** on display refresh and never takes 31.75 µs scanline interrupts.
* **Single Unified Video Mode:** Rather than switching between separate text and graphics modes, the Video Coprocessor continuously composites a **text overlay** directly onto the **monochrome graphics framebuffer** using a bitwise `OR` on every scanline.

---

## 2. Video Memory Regions

The BIOS exposes three contiguous memory regions in SRAM (exact base addresses defined in `include/abi/memory_map.h`):

| Region | Geometry | Size | Layout & Role |
|:---|:---|:---:|:---|
| **`FRAMEBUF`** | `640×480` @ 1 bpp | 38,400 bytes | Monochrome pixel framebuffer (`80` bytes per scanline × `480` scanlines). |
| **`TEXT_BUF`** | `80×60` cells | 4,800 bytes | Character grid: 1 byte per `8×8`-pixel cell (`row * 80 + col`), indexing glyphs `0x00`–`0xFF` in `FONT_RAM`. |
| **`FONT_RAM`** | `256` glyphs × `8` bytes | 2,048 bytes | Programmable `8×8` character set in **glyph-major layout**: `FONT_RAM[char * 8 + row]`, where `row` `0` is the top pixel row and `7` is the bottom pixel row. |

* **Total Video Footprint:** `38,400 + 4,800 + 2,048 = 45,248` bytes (~44.2 KB out of 512 KB Main SRAM).
* **Default Boot Font & Custom Tiles:** On power-up, the BIOS initializes `FONT_RAM` from a default 8×8 font stored in Flash, with **glyph `0x00` defined as all zeros (empty/transparent)**. Because `FONT_RAM` lives in SRAM, Stage-2 software can overwrite any glyph at runtime to create custom symbols, box-drawing characters, or 8×8 graphic tiles.

---

## 3. Unified OR-Compositing Rule

For every active scanline `y` (`0..479`) and byte column `col` (`0..79`), Core 1 computes each 8-pixel output byte by bitwise `OR`-ing the framebuffer byte with the corresponding glyph slice:

```text
glyph_idx  = TEXT_BUF[(y >> 3) * 80 + col]
glyph_byte = FONT_RAM[(glyph_idx << 3) + (y & 7)]
out_byte   = FRAMEBUF[y * 80 + col] | glyph_byte
```

This single rule naturally covers every display use case without any mode-switching registers:

* **Pure Graphics Mode:** Zero-fill `TEXT_BUF`. Because glyph `0x00` is empty (`0x00`), `FRAMEBUF | 0x00 == FRAMEBUF`.
* **Pure 80×60 Text Mode:** Zero-fill `FRAMEBUF`. Only glyphs from `TEXT_BUF` appear (`0x00 | glyph_byte == glyph_byte`).
* **Non-Destructive Text Overlay:** Write graphics to `FRAMEBUF` and HUD/console text to `TEXT_BUF` independently. Erasing or scrolling text never clobbers the underlying graphics pixels.

---

## 4. Core 1 Scanline Pipeline & Timing Budget

### Timing Derivation (`640×480 @ 60 Hz`)
* **Pixel Clock:** `25.2 MHz` (`126 MHz` `CLK_HSTX` DDR shifting 2 TMDS bits/cycle, `rp2350-datasheet.pdf §12.11, p. 1114`).
* **Scanline Period:** `800` total pixels/line (`640` active + `160` horizontal blanking):
  $$T_{\text{line}} = \frac{800}{25.2\text{ MHz}} \approx 31.75\text{ }\mu\text{s}$$
* **Core 1 Cycle Budget:** At `f_clk_sys = 126 MHz`:
  $$126\text{ MHz} \times 31.75\text{ }\mu\text{s} = 4{,}000\text{ cycles per scanline}$$
* **Compositing Cost:** Rendering 80 columns in tight RISC-V assembly (~6–8 cycles/column) takes **~480–640 cycles/line**—roughly **15% of Core 1**, leaving huge timing margin and zero risk of HSTX FIFO underrun.

### Ping-Pong Scanline Architecture

```text
  Core 0 (User / BIOS)                     Core 1 (Hidden Video Coprocessor)
  ────────────────────                     ─────────────────────────────────
  Writes freely to:                        Owns:
   • FRAMEBUF (38,400 B)                    • Private stack (Scratchpad Bank 9)
   • TEXT_BUF (4,800 B)                     • 2 × 80-byte ping-pong line buffers
   • FONT_RAM (2,048 B)                     • HSTX + HSTX DMA channels
          │                                         │
          └────── shared SRAM (AHB5 crossbar) ──────┘
                                                    │
                    ┌───────────────────────────────┴───────────────────────────────┐
                    ▼                                                               ▼
        Core 1 composes line (y + 1)                                   DMA streams line (y)
        into inactive 80 B buffer                                      from active 80 B buffer
        (FRAMEBUF | FONT_RAM[TEXT_BUF])                                into HSTX FIFO ──▶ DVI
```

* **Core 1 Launch:** During Stage-1 hardware bring-up, Core 0 wakes Core 1 via the SIO inter-core FIFO mailbox handshake (`rp2350-datasheet.pdf §3.1.4, p. 46`; `§5.3, p. 331`), giving it its own private stack in non-striped Scratchpad SRAM Bank 9 (`0x2008_1000`–`0x2008_1FFF`, `rp2350-datasheet.pdf §4.2, p. 312`).
* **Bus Contention:** The RP2350 AHB5 crossbar (`rp2350-datasheet.pdf §2.1, p. 23`) allows up to 6 simultaneous 32-bit transfers across the 4-way striped SRAM banks (`0x2000_0000`–`0x2007_FFFF`), and `BUSCTRL_BUS_PRIORITY` (`§2.1.1, p. 23`) can prioritize DMA/Core 1 if needed so Core 0 never stalls video output.
* **VSYNC Synchronization:** Once per frame at the start of vertical blanking, Core 1 increments a shared monotonic 32-bit `vsync_count` word in BIOS SRAM. Core 0 reads this counter (via BIOS ABI `WAIT_VSYNC` / frame-counter service) for tear-free animation and 60 Hz pacing.
