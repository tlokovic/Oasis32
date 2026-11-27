# Oasis32 Programmer's Reference

*TODO: Document header/subtitle, target BIOS ABI version (e.g., v0.1.0), and a brief introductory note framing this manual as the single, authoritative, self-contained specification for programming Oasis32.*

---

## Preface

### Purpose, Audience & Scope
*TODO: Explain who this manual is for (assembly programmers, game/demo authors, and OS developers targeting Oasis32). State the strict **Core Boundary Principle**: this manual defines everything an Oasis32 programmer needs—and is allowed—to know. Underlying silicon, board wiring, and peripheral bridge components are treated strictly as hidden implementation details and are intentionally omitted.*

### External References
*TODO: Define the circumscribed two-document external bookshelf that this manual defers to (and nothing else):*
1. *RISC-V Unprivileged ISA Specification, scoped strictly to Oasis32's declared ISA string (`RV32IMAC_Zifencei`).*
2. *RISC-V ELF psABI Specification (`ILP32` calling convention).*

### Document Conventions
*TODO: Define notation used throughout the manual: little-endian byte order, bit numbering (`bit 0` = LSB), hexadecimal prefixes (`0x`), register ABI names (`a0–a7`, `s0–s11`, `sp`, `ra`, etc.), signed error code conventions, and `[inclusive..inclusive]` vs. `[inclusive, exclusive)` address ranges.*

---

## 1. System Architecture & Machine Model

### 1.1 CPU & Instruction Set Architecture
*TODO: Specify the Oasis32 CPU contract: 32-bit little-endian RISC-V processor running at a nominal 126 MHz clock, single-core and single-threaded execution model, and the exact declared unprivileged ISA string **`RV32IMAC_Zifencei`** (`I` base integer, `M` multiply/divide, `A` atomics, `C` compressed 16-bit instructions, and `Zifencei` for `fence.i` instruction-stream synchronization when loading code into SRAM). Explicitly exclude `Zicsr`, privileged instructions/CSRs, and any vendor-specific extensions—noting that the disk toolchain enforces this mechanically at assemble time.*

### 1.2 Hardware Overview (Programmer's View)
*TODO: Include a high-level ASCII block diagram of the Oasis32 machine as seen by software: 32-bit RISC-V CPU, 464 KB contiguous User SRAM, 48 KB Public Video RAM driving a 640×480 @ 60 Hz monochrome display (bitmap + 80×60 text overlay + 16 hardware sprites), and the BIOS-abstracted peripherals (keyboard, mouse, 512-byte block storage, 115,200 baud serial port, 1 µs monotonic timer, piezo buzzer, and 3 status LEDs).*

### 1.3 Execution Rules & Honor-System Boundaries
*TODO: Document what Stage-2 software is permitted to do (execute standard `RV32IMAC_Zifencei` instructions in User SRAM, read/write Public Video RAM, and invoke BIOS services via `ecall`) and what it is strictly prohibited from doing (accessing CSRs, masking interrupts, accessing addresses outside User SRAM and Public Video RAM, or attempting direct hardware MMIO). Include a brief note on why honoring these boundaries keeps software portable across future BIOS revisions or hardware-enforced isolation.*

### 1.4 Interrupt Transparency & Runtime Faults
*TODO: Explain that all background hardware servicing (display refresh, keyboard/mouse buffering, typematic key repeat) is completely transparent to user code: every general-purpose register (`x1–x31`) and the user stack (`sp`) are preserved bit-for-bit across background events. Also document what happens if a program triggers a synchronous CPU fault (illegal instruction, invalid memory access, etc.): the BIOS prints a diagnostic trap report (`mcause`, `mepc`, `mtval`) over the debug serial console and halts until reset.*

---

## 2. Memory Map

### 2.1 Address Space Overview
*TODO: Present an ASCII memory map diagram and summary table of all programmer-visible memory regions (`0x2000_0000`–`0x2007_FFFF`, 512 KB total: 464 KB User SRAM + 48 KB Public Video Memory Block). Explicitly state that all other addresses in the 32-bit space are reserved/off-limits.*

### 2.2 User SRAM (`USER_RAM_BASE`–`USER_RAM_END`)
*TODO: Document the 464 KB (`475,136` bytes, `0x2000_0000`–`0x2007_3FFF`) contiguous User SRAM window: typical placement of `.text`, `.rodata`, `.data`, `.bss`, upward-growing heap, and downward-growing user stack initialized to `USER_STACK_TOP` (`0x2007_4000`, 16-byte aligned per `ILP32`). Warn explicitly about stack overflow/underflow behavior in the absence of hardware guard pages (overflow corrupts `.bss`/heap/code; underflow above `0x2007_4000` corrupts the top of `FRAMEBUF`).*

### 2.3 Public Video Memory Block (`VIDEO_RAM_BASE`–`VIDEO_RAM_END`)
*TODO: Provide a complete address/size/alignment table of the 48 KB (`49,152` bytes, `0x2007_4000`–`0x2007_FFFF`) video region (`FRAMEBUF`, `FONT_RAM`, `TEXT_BUF`, `VIDEO_CTRL`, `SPRITE_OAM`, `SPRITE_PAT`) with their symbolic constants from `include/abi/memory_map.h`, cross-referencing Chapter 5 for detailed bit/struct layouts.*

### 2.4 Linking Against the Memory Map (`memory_map.h` & `sd_payload.ld.S`)
*TODO: Explain how Stage-2 programs consume `include/abi/memory_map.h` and the shared preprocessed linker script `include/ld/sd_payload.ld.S` (including exported linker symbols such as `__payload_start`, `__payload_end`, `__payload_size`, `__bss_start`, `__bss_end`, and `__stack_top`, and the `.text.entry` placement convention).*

---

## 3. Boot Process, Disk Image Format & Startup State

### 3.1 Bootable Disk Image Format (`"OA32"`)
*TODO: Specify the exact binary layout of an Oasis32 disk image (used identically on raw SD cards starting at LBA 0 and over serial in Base64): the packed 16-byte little-endian Boot Image Header (`magic = 0x3233414F` / `"OA32"`, `load_addr`, `entry_addr`, `payload_size`) and raw payload starting at byte offset `0x10` (16), sharing up to 496 bytes of LBA 0 and continuing across LBA 1..N with zero-padding at the end of the final 512-byte sector. Document the bootloader's bounds-validation rules (User SRAM bounds, 32-bit overflow checks) and `include/abi/boot_header.h` constants.*

### 3.2 Startup Boot Menu & Serial Transfer Workflow
*TODO: Document the interactive startup boot menu presented on power-up or reset over the serial console (115,200 baud, 8N1) and its four options: `ENTER` (boot from SD card), `1` (boot Base64-encoded `.oa32` image directly into User SRAM without touching SD), `2` (receive Base64-encoded `.oa32` image into User SRAM staging buffer, validate, and write raw to SD starting at LBA 0), and `3` (built-in hardware diagnostic demo). Cover `"Insert boot disk"` / `"Insert disk to write"` prompts, whitespace-ignoring Base64 decoding, automatic termination after `16 + payload_size` decoded bytes, and error recovery back to the boot menu. (Note: verify final exact prompt wording once Sub-Phase 3c is implemented.)*

### 3.3 Guaranteed Machine State at Entry (`_start`)
*TODO: Specify every guaranteed register, memory, and peripheral invariant when the Stage-1 bootloader transfers control to `entry_addr` (after executing `fence.i`):*
- *CPU & Stack: `sp = USER_STACK_TOP` (`0x2007_4000`, 16-byte aligned); all other GPRs unspecified.*
- *Memory & `.bss`: `[load_addr, load_addr + payload_size)` holds the verified payload bytes; **Stage-2 `_start` is responsible for zeroing `[__bss_start, __bss_end)`** (since `.bss` is not encoded in the 16-byte `"OA32"` header). Unloaded regions of User SRAM are unspecified.*
- *Clean Peripheral Handoff: Before jumping to `entry_addr`, the bootloader resets Video RAM (`FRAMEBUF`, `TEXT_BUF`, `SPRITE_OAM`, `SPRITE_PAT` zeroed; default CP437 font loaded in `FONT_RAM`; `VIDEO_CTRL.LATCH_OAM = 1`), resets the text console cursor to `(0, 0)` hidden (`vis = 0`, `blink = 0`), flushes all keyboard/mouse queues, centers the mouse at `(320, 240)`, restores default keyboard repeat (`500 ms` delay, `50 ms` rate), silences the piezo buzzer, turns all 3 status LEDs off, and leaves `os_ecall_handler = 0`.*
- *SD Card: If booted via `ENTER`, the SD card is already initialized (`SD_STATUS_PRESENT | SD_STATUS_READY`); if booted via serial (`1`), a card may or may not be present/initialized (call `BIOS_SD_STATUS` / `BIOS_SD_INIT` before block I/O).*

### 3.4 Program Termination, Exit & Reboot Semantics
*TODO: Clarify that Stage-2 payloads are booted via a one-way jump (there is no caller to `ret` to). Document how a program should idle cleanly (e.g., event loop) or perform a clean full system restart via `BIOS_SYS_REBOOT` (as well as hardware reset button behavior).*

### 3.5 Building & Deploying Stage-2 Disk Images
*TODO: Provide a concise walkthrough of the host-side build and deployment flow: using `oasis32_add_disk_executable()` in `cmake/oasis32.cmake` (strictly linking only `oasis32_abi` with `-march=rv32imac_zifencei -mabi=ilp32`), how `sd_payload.ld.S` automatically prepends the 16-byte `"OA32"` header into the `.oa32` binary, and how to Base64-encode and transmit the `.oa32` file over the serial port for Menu Options `1` and `2`.*

---

## 4. BIOS ABI & Calling Contract

### 4.1 Invoking BIOS Services (`ecall`)
*TODO: Specify the exact RISC-V `ecall` calling contract: `a7` holds the service ID, `a0–a5` pass up to 6 word-sized arguments, `a0` (and for select calls, `a1–a5`) return results. State `ILP32` register preservation guarantees (`s0–s11`, `sp`, `gp`, `tp`, `ra` preserved; `t0–t6` and unspecified `a0–a7` caller-saved/clobberable), caller stack headroom expectations (~64–128 bytes for the trap frame and service locals), and the fact that background I/O remains live during blocking BIOS calls.*

### 4.2 Return Values & Standardized Error Codes
*TODO: Document the uniform signed-integer return convention in `a0` (`a0 >= 0` indicates success, `a0 < 0` indicates error, enabling single-instruction `bltz a0, ...` error checks) and tabulate all standardized error codes from `include/abi/bios_abi.h`: `ERR_OK (0)`, `ERR_UNSUPPORTED (-1)`, `ERR_INVALID_ARG (-2)`, `ERR_EMPTY (-3)`, `ERR_BUSY (-4)`, `ERR_IO (-5)`, and `ERR_NO_DEVICE (-6)`.*

### 4.3 Service ID Partitioning & Subsystem Blocks
*TODO: Document the split between Resident BIOS services (`0x0000`–`0x00FF`) and Stage-2 OS extensions (`0x0100+`), and summarize the 16-ID subsystem blocks (`0x00` System, `0x10` Serial, `0x20` Video, `0x30` Input, `0x40` Storage, `0x50` Timer, `0x60` Audio, `0x70` LEDs, `0x80` Text Console, `0x90–0xFF` Reserved).*

### 4.4 Extending `ecall` for a Stage-2 Operating System
*TODO: Document how a Stage-2 OS registers its own syscall dispatcher for `a7 >= 0x0100` using `BIOS_SYS_SET_OS_ECALL_HANDLER` (alignment and User SRAM range requirements, clearing with `0`). Explain the exact register state on entry to the OS handler (`a0–a5` arguments, `a7` service ID, standard `ret` return via `ra` with result in `a0`), and highlight **nested `ecall` re-entrancy** (an OS syscall handler may freely invoke BIOS `ecall` services such as `BIOS_SD_READ` or `BIOS_TEXT_PUTS`).*

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

### 6.2 Debug Serial Console (`BIOS_BLK_SERIAL`, `0x10`–`0x1F`)
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

## Appendices

### Appendix A: Keyboard Keycodes & Modifier Reference
*TODO: Provide a compact, self-contained table of all Oasis32 keycodes from `include/abi/keycodes.h` (Letters `0x04–0x1D`, Digits `0x1E–0x27`, Control/Punctuation `0x28–0x39`, Function Keys `0x3A–0x45`, Navigation `0x46–0x53`, Numeric Keypad `0x54–0x63`, Modifiers `0xE0–0xE7`), the `KEY_MOD_*` bitmask table, and the exact Unshifted/Shifted ASCII outputs of `BIOS_KEYBOARD_KEYCODE_TO_ASCII`.*

### Appendix B: ASCII & Default CP437 Character Set Reference
*TODO: Include a compact 7-bit ASCII table (`0x00–0x7F`, highlighting control codes handled by `BIOS_TEXT_PUTC`) plus a quick reference summary of the default IBM Code Page 437 high-byte glyphs (`0x80–0xFF`: box drawing, block shading, accented letters, math symbols) and the empty/transparent `0x00` glyph rule.*

### Appendix C: BIOS `ecall` Quick Reference Card
*TODO: A single consolidated cheat-sheet table listing every BIOS service ID (`0x00`–`0x87`), symbolic name, input registers, output registers, blocking/non-blocking flag, and possible error codes for rapid lookup while coding in assembly.*

### Appendix D: Public ABI Header (`include/abi/*.h`) Symbol Index
*TODO: A compact index grouping all public `#define` constants by header file (`memory_map.h`, `boot_header.h`, `bios_abi.h`, `devices.h`, `keycodes.h`) so programmers know which header to `#include` for any constant.*
