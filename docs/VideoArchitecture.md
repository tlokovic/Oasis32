# Oasis32 — Video Architecture (Core 1 Video Coprocessor)

## 1. Philosophy: A Dedicated "Video Chip" with No Mode Switching

Classic 8-bit microcomputers (like the Commodore 64's VIC-II or the Atari 800's ANTIC) paired the main CPU with a dedicated video processor that scanned RAM and generated the display signal autonomously. **Oasis32** recreates this architecture in silicon by dedicating **RP2350 Core 1** (`rp2350-datasheet.pdf §3.8, p. 227`) exclusively to the Stage-1 System ROM as a permanent, Flash-resident **Video Coprocessor (PPU / CRTC)**.

* **Invisible to Oasis32 Software:** To software running on Core 0 (and in `docs/ProgrammersReference.md`), Oasis32 remains a strictly **single-core** computer. Core 1 is treated as hidden display hardware—never exposed as a second general-purpose CPU.
* **Zero Core 0 Overhead:** Because Core 1 owns `HSTX` (`rp2350-datasheet.pdf §12.11, pp. 1114–1122`) and its DMA scanline interrupts, Core 0 spends **0% of its cycles** on display refresh and never takes 31.75 µs scanline interrupts.
* **Single Unified Video Mode:** Rather than switching between separate text and graphics modes, the Video Coprocessor continuously composites a **text overlay** directly onto the **monochrome graphics framebuffer** using a bitwise `OR` on every scanline.

---

## 2. Video Memory Regions

The BIOS exposes one contiguous **56 KB** public video memory block at the top of Main SRAM (`0x2007_2000`–`0x2007_FFFF`; exact symbolic constants defined in `include/abi/memory_map.h`):

| Region | Address Range | Geometry | Size | Layout & Role |
|:---|:---|:---|---:|:---|
| **`FRAMEBUF`** | `0x2007_2000`–`0x2007_B5FF` | `640×480` @ 1 bpp | 38,400 B | Monochrome pixel framebuffer (`80` bytes per scanline × `480` scanlines). |
| **`FONT_RAM`** | `0x2007_B600`–`0x2007_BDFF` | `256` glyphs × `8` B | 2,048 B | Programmable `8×8` character set in **glyph-major layout** (`FONT_RAM[char * 8 + row]`, row `0` = top, row `7` = bottom). |
| **`TEXT_BUF`** | `0x2007_BE00`–`0x2007_D0BF` | `80×60` cells | 4,800 B | Character grid: 1 byte per `8×8`-pixel cell (`row * 80 + col`), indexing glyphs `0x00`–`0xFF` in `FONT_RAM`. |
| **`TEXT_ATTR`** | `0x2007_D0C0`–`0x2007_E37F` | `80×60` cells | 4,800 B | Per-cell text attributes: 1 byte per cell (`row * 80 + col`); bit `0` = reverse (`^ 0xFF`), bits `7:1` reserved (`0`). |
| **`VIDEO_CTRL`** | `0x2007_E380`–`0x2007_E3BF` | Control/status block | 64 B | Public video control registers (e.g., `LATCH_OAM` mode bit, future display flags). |
| **`SPRITE_OAM`** | `0x2007_E3C0`–`0x2007_E43F` | `16` slots × `8` B | 128 B | Active on-screen sprite descriptor table (Sprite 0 conventionally used as the mouse cursor). |
| **`SPRITE_PAT`** | `0x2007_E440`–`0x2007_FFFF` | `111` patterns × `64` B | 7,104 B | Masked `16×16` 2-plane sprite pattern bank (supports multiple animation frames and shared patterns). |

* **Total Video Footprint:** `38,400 + 2,048 + 4,800 + 4,800 + 64 + 128 + 7,104 = 57,344` bytes (**exactly 56 KB**, leaving 456 KB of contiguous User SRAM).
* **Default Boot Font & Custom Tiles:** On power-up, the BIOS initializes `FONT_RAM` from a default 8×8 font stored in Flash, with **glyph `0x00` defined as all zeros (empty/transparent)**, and zeroes `TEXT_BUF`, `TEXT_ATTR`, and `SPRITE_OAM` so all text cells start empty/normal and all sprites start disabled. Because `FONT_RAM` lives in SRAM, Stage-2 software can overwrite any glyph at runtime to create custom symbols, box-drawing characters, or 8×8 graphic tiles.

---

## 3. Unified OR-Compositing & Per-Cell Reverse Attribute Rule

For every active scanline `y` (`0..479`) and byte column `col` (`0..79`), Core 1 fetches the `8`-pixel glyph slice from `FONT_RAM`, applies `TEXT_ATTR` reverse inversion and hardware cursor inversion to the **glyph** via XOR (`^ 0xFF`), and then bitwise `OR`-composites the resulting text slice onto the scanline byte (`FRAMEBUF` + behind-text sprites):

```text
cell_idx   = (y >> 3) * 80 + col
glyph_idx  = TEXT_BUF[cell_idx]
text_byte  = FONT_RAM[(glyph_idx << 3) + (y & 7)]
if (TEXT_ATTR[cell_idx] & 1) text_byte ^= 0xFF
if (cursor_visible_on_cell)  text_byte ^= 0xFF
out_byte   = line_byte | text_byte
```

Because both inversions happen **before** the bitwise `OR`, `TEXT_ATTR` reverse and the hardware cursor apply strictly to the text layer and never invert underlying `FRAMEBUF` or behind-text sprite pixels.

This single rule naturally covers every display use case without any mode-switching registers:

* **Pure Graphics Mode:** Zero-fill `TEXT_BUF` and `TEXT_ATTR`. Because glyph `0x00` is empty (`0x00`) and reverse bit `0` is clear, `FRAMEBUF | 0x00 == FRAMEBUF`.
* **Pure 80×60 Text Mode:** Zero-fill `FRAMEBUF`. Only glyphs from `TEXT_BUF` (and any reversed cells in `TEXT_ATTR`) appear (`0x00 | text_byte == text_byte`).
* **Non-Destructive Text Overlay & Per-Cell Reverse Highlighting:** Write graphics to `FRAMEBUF` and HUD/console text to `TEXT_BUF` / `TEXT_ATTR` independently. Setting bit `0` (`TEXT_ATTR_REVERSE`) in `TEXT_ATTR[row * 80 + col]` inverts that cell's `8×8` glyph (`^ 0xFF`)—even for blank (`0x00`) cells—before OR-compositing onto the scanline, enabling highlighted status bars, menu selections, and inverse video without modifying `FONT_RAM` or inverting underlying graphics. Erasing or scrolling text (`BIOS_TEXT_CLEAR`, `BIOS_TEXT_SCROLL_UP`/`DOWN`) updates `TEXT_BUF` and `TEXT_ATTR` in lockstep without disturbing `FRAMEBUF`.
* **Non-Destructive Hardware Text Cursor (XOR-Composed):** Cursor position (`col` `0..79`, `row` `0..59`), visibility, and blink half-period (in 60 Hz frames; `0` = solid) live in BIOS-private USB DPRAM and are updated strictly via the `BIOS_BLK_TEXT` (`0x80`–`0x8F`) `ecall` services (never directly memory-mapped). When enabled, Core 1 drives the blink phase from its 60 Hz VBLANK counter and inverts (`^ 0xFF`) the active `8×8` glyph slice before OR-compositing during Layer 3—incurring zero Core 0 overhead and never mutating `TEXT_BUF`, `TEXT_ATTR`, or `FONT_RAM`. Because both `TEXT_ATTR` reverse and the cursor compose via XOR (`^ 0xFF`), when the cursor is visible on a reversed cell the two inversions cancel out and the cell temporarily renders in normal polarity—keeping the cursor clearly visible over highlighted text.

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
   • TEXT_BUF / TEXT_ATTR (2 × 4,800 B)     • 2 × 80-byte ping-pong line buffers
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

---

## 5. Hardware Sprite Engine (`SPRITE_OAM` & `SPRITE_PAT`)

Core 1's scanline compositor includes a **16-sprite masked `16×16` hardware sprite engine** backed by **111 reusable sprite patterns**—enabling smooth animation cycling, game sprites, and a floating hardware mouse cursor (by convention, **Sprite 0**) with zero per-scanline drop-out or flicker.

### 5.1 Sprite Pattern Format (`SPRITE_PAT`: `0x2007_E440`–`0x2007_FFFF`)
Each of the **111** `16×16` patterns occupies **64 bytes** in a **split-plane 2-plane monochrome** layout:
* **Bytes `0..31` (Pixel Plane):** `16` rows × `uint16_t` (row `0` = top, row `15` = bottom; bit order matches `FRAMEBUF`/`FONT_RAM`).
* **Bytes `32..63` (Mask Plane):** `16` rows × `uint16_t` (`1` = opaque, `0` = transparent).

This gives every pixel **3 states**—**Transparent** (`mask = 0`), **Opaque Black** (`mask = 1, pixel = 0`), or **Opaque White** (`mask = 1, pixel = 1`)—so a white mouse arrow can carry a crisp 1-pixel black outline over both black and white backgrounds.

### 5.2 OAM Slot Format (`SPRITE_OAM`: `0x2007_E3C0`–`0x2007_E43F`)
Each of the **16** simultaneous on-screen sprite slots occupies **8 bytes** (little-endian):

| Offset | Size | Field | Description |
|:---:|:---:|:---|:---|
| `+0` | 2 B | `x` (`int16_t`) | Signed horizontal position (`-15`..`639`) for smooth off-screen clipping on left/right edges. |
| `+2` | 2 B | `y` (`int16_t`) | Signed vertical position (`-15`..`479`) for smooth off-screen clipping on top/bottom edges. *(`x` and `y` share one 32-bit word `[y:16 \| x:16]`, enabling atomic position updates with a single `sw`.)* |
| `+4` | 1 B | `pattern` (`uint8_t`) | Pattern index (`0`–`110`) into `SPRITE_PAT` (out-of-range indices are skipped; multiple slots may share one pattern). |
| `+5` | 1 B | `flags` (`uint8_t`) | Bit `0`: `ENABLE` (`1` = visible)<br>Bit `1`: `HFLIP` (horizontal mirror)<br>Bit `2`: `VFLIP` (vertical mirror)<br>Bit `3`: `BEHIND_TEXT` (`0` = above `TEXT_BUF`, `1` = between `FRAMEBUF` and `TEXT_BUF`)<br>Bits `5:4`: `BLEND` (`00` = Masked Opaque `(bg & ~mask) \| pixels`, `01` = OR `bg \| pixels`, `10` = XOR `bg ^ pixels`, `11` = reserved)<br>Bits `7:6`: reserved (`0`) |
| `+6` | 2 B | `reserved` | Reserved (`0`). |

### 5.3 Compositing Priority & Mouse Cursor Convention
Core 1 composites each active scanline into the Bank 9 line buffer in four deterministic layers:
1. **`FRAMEBUF`** (bottom layer)
2. **Behind-text sprites** (`BEHIND_TEXT = 1`), drawn **Slot 15 → Slot 0**
3. **`TEXT_BUF` / `FONT_RAM` + `TEXT_ATTR` + Hardware Cursor** (each glyph is optionally XOR-inverted by `TEXT_ATTR` bit `0` and/or the active hardware cursor, then bitwise `OR`-composited onto the scanline)
4. **In-front sprites** (`BEHIND_TEXT = 0`), drawn **Slot 15 → Slot 0**

Because **lower OAM index = higher visual priority**, **Sprite 0** (used by convention as the mouse cursor, with `BEHIND_TEXT = 0`) automatically floats above all graphics, all text, and all other sprites with zero special-case logic.

### 5.4 `VIDEO_CTRL` Latching & Scanline Timing Budget
* **`VIDEO_CTRL` (`0x2007_E380`) `LATCH_OAM` flag:**
  * **`1` (default — Frame-Latched):** During VBLANK (~`180,000` idle cycles across 45 blanking lines), Core 1 copies `SPRITE_OAM` (128 B) into its private Bank 9 scratchpad and builds compact enabled-slot lists per layer, guaranteeing tear-free frames and zero AHB contention during active scanlines.
  * **`0` (Dynamic / Beam-Racing):** Core 1 reads `SPRITE_OAM` live per scanline, unlocking classic raster sprite-multiplexing tricks while preserving atomic `(x, y)` updates via a single 32-bit store.
* **Scanline Timing Budget (full 80-column reversed text + 16 simultaneous sprites):**
  1. `FRAMEBUF` 20-word copy + word-wise 4-column `TEXT_BUF` OR-compositing & SWAR `TEXT_ATTR` XOR inversion (`(attr & 0x01010101) * 0xFF`): **~`960` cycles** (+100 cycles over unattributed text).
  2. Per-active-sprite word-wise compositing (including 32-bit SWAR `HFLIP` when enabled): **~`65–100` cycles**.
  3. **Worst Case (all 80 columns non-zero & reversed + all 16 sprites overlapping on one scanline, half `HFLIP`'d):**
     $$960 + (8 \times 65) + (8 \times 100) \approx 2{,}280\text{ cycles out of }\sim 2{,}720\text{ active-window cycles}$$
     Over `400` cycles of spare margin per scanline—zero per-scanline sprite limit or flicker at `126 MHz`.
