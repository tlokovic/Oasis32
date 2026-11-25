# Oasis32 Development Plan

## Project Overview

The objective of the **Oasis32** project is to construct a self-contained computer powered by the Raspberry Pi Pico 2 that can be programmed completely from bare-metal RISC-V assembly with zero third-party software, drivers, or SDKs.

The roadmap is divided into four sequential phases:
1. **Phase 1: Test Hardware with Pico C++ SDK:** Incrementally assemble, solder, and electrically verify the hardware peripherals using a non-blocking C++ test harness. Once complete, all soldering tools are put away and the physical platform is frozen as known-good.
2. **Phase 2: Port Test Harness to RISC-V Assembly:** Re-implement the full test harness in pure, bare-metal RISC-V assembly with zero linked libraries or SDK code, establishing our hardware-abstraction foundation.
3. **Phase 3: System ROM / BIOS & Bootloader:** Establish the project's representational foundation (layered headers, preprocessed linker scripts, and CMake boundary enforcement) and build the Flash-resident Oasis32 BIOS, stable ROM ABI, and SD-card bootloader.
4. **Phase 4: SD-Card Software & OS Development:** Develop standalone bootable demos, utilities, and the native Oasis32 operating system (interactive console, shell/monitor, custom filesystem, and program loader) as SD-card payloads targeting the published BIOS ABI.

---

## Phase 1: Test Hardware with Pico C++ SDK

The goal of this phase is to confirm that the hardware is functioning and electrically sound. To eliminate ambiguous faults (distinguishing bad solder joints from register or compiler bugs), all hardware bring-up is conducted in C++ using the official Raspberry Pi Pico SDK (but no other libraries).

Peripherals are attached and tested one at a time. If an addition introduces a fault, the issue is isolated immediately to the newly attached component.

### Test Harness Behavior

All development in Phase 1 lives in `test_harness/cpp/`. 

On startup, the test harness enters a **non-blocking cooperative polling loop** on a single RISC-V core (`rp2350-riscv`). Rather than using blocking delays (which would starve UART receive FIFOs or cause visual stutter), the loop continuously checks hardware timestamps alongside peripheral status registers to run the following tasks concurrently:

* **LEDs:** Blink the Red, Green, and Blue LEDs sequentially, advancing once per second.
* **Piezo:** Beep the piezo once every three seconds for a duration of **100 ms at 1 kHz** (started and stopped non-blockingly via timer comparison).
* **Serial Heartbeat:** Print an incrementing timestamp/counter message to the debug serial port (`UART0`) once a second.
* **Serial Echo:** Immediately echo incoming keystrokes from `UART0` back to the host terminal.
* **HDMI Display:** Maintain a **640×480 monochrome (1 bpp) framebuffer** in SRAM (38,400 bytes). Render a static 1-pixel outer border `(0,0)–(639,479)` and a word-aligned **20×15 grid of 32×32-pixel cells** to verify native 640×480 framing and bit order, plus a **32×32 XOR box** that glides at ~60 px/s and bounces off the border on a non-blocking timer.
* **Keyboard/Mouse:** Poll the CH9350 bridge (`UART1`) for framed serial HID packets, decode incoming events, and log a human-readable summary to the debug serial port (`UART0`).
* **SD Card:** Treat the SD card as a raw block device over SPI. Once a second, write a 512-byte test pattern to a rotating block address, read it back, verify data integrity, and log pass/fail status over `UART0`.

### C++ Constraints & Toolchain
* **Target Architecture:** RP2350 Hazard3 RISC-V (`PICO_PLATFORM=rp2350-riscv`, `PICO_BOARD=pico2`).
* **Strictly Non-Blocking Runtime:** The main loop must never use `sleep_ms()` or blocking busy-waits. Short, bounded waits are restricted strictly to one-time boot initialization (e.g., crystal oscillator lock, SD card power-up handshake).
* **Progressive Reduction:** Where helpful, high-level SDK helper routines may be progressively refactored down to direct hardware register operations (`sio_hw`, `uart0_hw`, etc.) to serve as direct blueprints for Phase 2.

### Sub-Phase 1a: Host-Side Tools & Baseline C++ Blink

#### Hardware
Bare, unmodified Raspberry Pi Pico 2 (using the onboard LED on `GPIO25`).

#### Software & Setup
* Install the Raspberry Pi Pico extension in Antigravity IDE / VS Code to configure the Pico SDK, RISC-V toolchain (`riscv32-unknown-elf`), CMake, Ninja, and `picotool`.
* Configure `test_harness/cpp/` with a standalone `CMakeLists.txt` targeting `rp2350-riscv` and `pico2`.
* Implement non-blocking timer-based blink on `GPIO25` and verify flash & execution on hardware.

### Sub-Phase 1b: Solder LEDs, Piezo, and Reset

#### Hardware
Solder the status LEDs (Red, Green, Blue), Piezo buzzer, and momentary reset button to the Pico 2.

#### Software
* Configure a free-running hardware timer or microsecond counter for non-blocking scheduling.
* Add the 1-second cycling Red -> Green -> Blue sequence to the non-blocking loop.
* Add the once-every-3-seconds 100 ms @ 1 kHz piezo beep (driven via PWM or timer-toggled GPIO).
* Verify that pressing the reset button cleanly restarts the sequence (and enters `BOOTSEL` mode when held with `BOOTSEL`).

### Sub-Phase 1c: Solder Serial Port (CP2102N Debug Port)

#### Hardware
Solder the CP2102N USB-to-UART bridge (`UART0`, `GP0` TX, `GP1` RX).

#### Software
* Initialize `UART0` at 115200 baud, 8N1.
* Transmit a boot banner message upon startup.
* Add the once-per-second status/heartbeat message to the main loop.
* Poll `UART0` on every main loop iteration and immediately echo any received characters back to the host terminal. Rather than printing the characters raw, it should print a separate line with "Serial character received:" with decimal, hex, and binary representations of the character.

### Sub-Phase 1d: Solder Display (DVI Sock)

#### Hardware
Solder the Adafruit DVI Sock (`GP12–GP19`).

#### Software
* Allocate the 640×480 1 bpp monochrome framebuffer (38,400 bytes).
* Configure `PLL_SYS` / `CLK_HSTX`, the `HSTX` serializer/crossbar, and DMA channels to stream out 640×480 @ 60 Hz video.
* Render a static 1-pixel outer border `(0,0)–(639,479)` with a word-aligned `20×15` (`32×32` px) grid, and in the non-blocking main loop animate a `32×32` XOR box bouncing off the border (~60 px/s) without interrupting LED or UART tasks.

### Sub-Phase 1e: Solder Keyboard/Mouse Host (CH9350)

#### Hardware
Solder the CH9350 Dual USB Host-to-UART module (`UART1`, `GP20` RX, `GP21` TX) and set hardware DIP switches to Lower Computer Mode, 115200 Baud, State 2.

#### Software
* Initialize `UART1` at 115200 baud, 8N1.
* In the main loop, poll `UART1` to parse incoming `0x57 0xAB`-framed serial HID packets (and transmit handshake replies if required).
* Print decoded keypresses and mouse movement summaries over debug `UART0`.

### Sub-Phase 1f: Solder SD Card Breakout

#### Hardware
Solder the SD card breakout (`SPI0`, `GP2–GP6`).

#### Software
* Initialize `SPI0`, execute the SD SPI initialization sequence (`CMD0`, `CMD8`, `ACMD41`, `CMD58`), and switch to high-speed SPI.
* In the main loop, non-blockingly write a 512-byte test pattern once per second across a rotating block ring, read it back, verify integrity, and log pass/fail status over `UART0`.
* **Hardware Milestone Complete:** The physical hardware is now 100% assembled, tested under full concurrent load, and physically validated. Soldering and wiring tools can be packed away.

---

## Phase 2: Port Test Harness to RISC-V Assembly

With physical hardware integrity proven and frozen, the entire test harness is ported to pure bare-metal RISC-V assembly in `test_harness/asm/`. The assembly version reproduces the exact same concurrent polling behavior as the C++ harness, proving full bare-metal control of all peripherals without any linked libraries or third-party code.

### Key Assembly-Specific Architecture & Details
* **Zero Linked SDK / Runtime:** Pure bare-metal assembly compiled with `riscv32-unknown-elf-gcc`/`as`/`ld` using `-nostdlib -nostartfiles -march=rv32imac_zicsr_zifencei -mabi=ilp32`.
* **Boot Metadata (`PICOBIN`):** Embed a hand-crafted `IMAGE_DEF` block in the first 4 KB of flash declaring the RP2350 Hazard3 architecture, vector table, and execution entry point, converted into a `.uf2` via `picotool`.
* **Custom Linker Script (`memmap.ld`):** Explicitly maps flash (`0x10000000`), SRAM banks (`0x20000000`), stack pointer, and the 1 bpp framebuffer address space.
* **Direct Hardware Initialization:**
  * **Clocks:** Switch from boot `ROSC` to 12 MHz `XOSC`, configure `PLL_SYS` for system execution and HSTX pixel clock generation.
  * **Subsystem Un-gating:** Explicitly clear reset bits in `RESETS->RESET` and poll `RESETS->RESET_DONE` for all active peripherals (`IO_BANK0`, `PADS_BANK0`, `UART0`, `UART1`, `SPI0`, `PWM`, `HSTX`, `DMA`).
  * **Pad Isolation:** Explicitly clear the RP2350 pad isolation latch bit (`ISO`, bit 8) in `PADS_BANK0` across all configured pins.
* **Non-Blocking Architecture:** Replicate the C++ non-blocking state machine using RISC-V CSR/hardware timers and peripheral FIFO/status flags.

---

## Phase 3: System ROM / BIOS & Bootloader

With bare-metal peripheral control proven in Phase 2, Phase 3 builds the permanent, Flash-resident **Stage-1 System ROM (BIOS & Bootloader)** described in `ARCHITECTURE.md`. Rather than modifying `test_harness/asm/` (which remains preserved as a standalone Phase 2 reference), Phase 3 learns from it to establish a clean, modular multi-file architecture and the representational foundation that will support both BIOS and SD-card development.

### Architectural Constraints
* **Zero Linked SDK / Runtime:** Pure bare-metal RISC-V assembly (`-nostdlib -nostartfiles -nodefaultlibs`).
* **Strict ABI Boundary:** Public contracts live in `include/` (`abi/` headers + `ld/sd_payload.ld.S`); all RP2350 register maps, Oasis32 pin wiring (`hw/`), and BIOS-private state live strictly inside `bios/internal/` and are never exposed to `disks/`.
* **Single Source of Truth:** Shared constants use pure `#define` headers (`.h`) consumed by both `.S` sources and preprocessed `.ld.S` linker script templates via a shared `cmake/oasis32.cmake` helper.

### Sub-Phase 3a: Architectural Decisions & Representational Foundation
* Resolve the open System ROM design decisions in `ARCHITECTURE.md §6` (ROM ABI calling mechanism, LBA 0 Boot Image Header binary layout, no-card/invalid-disk fallback behavior, and host-to-SD-card development transfer workflow).
* Create `cmake/oasis32.cmake` with the `oasis32_abi` interface target, `.ld.S` preprocessing helper (using `gcc -E -P -x c` with `DEPFILE` tracking), and bare-metal disk target helper.
* Author the public ABI headers (`include/abi/memory_map.h`, `boot_header.h`, `bios_abi.h`, `devices.h`) and shared `include/ld/sd_payload.ld.S`.
* Author the private BIOS headers (`bios/internal/hw/`, `bios_ram.h`, `bios_flash.h`, `bios_config.h`) and `bios/ld/bios.ld.S`.

### Sub-Phase 3b: Modular Hardware Bring-Up & Resident Drivers
* Organize the validated Phase 2 hardware bring-up and drivers into clean, modular `.S` files under `bios/src/`:
  * Boot entry, `PICOBIN` `IMAGE_DEF`, clock tree (`XOSC` -> `PLL_SYS` @ 126 MHz), `RESETS`, `PADS_BANK0` `ISO` clearing, and `TIMER0` 1 µs timebase.
  * Status LEDs (`SIO`), piezo buzzer (`PWM`), debug serial (`UART0`), DVI/HSTX display + DMA IRQ, CH9350 keyboard/mouse (`UART1`), and SD card block I/O (`SPI0` + `GP6` card detect).
* Confine all BIOS-private buffers, DMA descriptors, and driver state cleanly to the BIOS-reserved SRAM region defined in `memory_map.h` and `bios_ram.h`.

### Sub-Phase 3c: Stable Resident BIOS ABI & Fallback Behavior
* Implement the Stage-1 Resident BIOS ABI dispatcher (`bios/src/abi_dispatch.S`) exposing hardware I/O services (display/framebuffer, serial, keyboard/mouse, SD block read/write, timer, buzzer, LEDs) to SRAM-loaded payloads.
* Implement the chosen no-card / invalid-disk fallback behavior (e.g., boot prompt, minimal ROM monitor, and/or serial loader over `UART0`).

### Sub-Phase 3d: SD Bootloader & End-to-End Boot Verification
* Implement the Stage-1 SD bootloader (`bios/src/bootloader.S`): detect an inserted SD card (`GP6`), initialize the card over `SPI0`, read and validate the LBA 0 Boot Image Header, load payload sectors into User SRAM, execute `fence.i`, and transfer execution to the payload entry point.
* Verify the complete boot chain with a minimal smoke-test boot disk under `disks/` that links strictly against `include/abi/` and `include/ld/sd_payload.ld.S` and exercises resident BIOS services.

### Phase 3 Deliverable: Oasis32 Programmer's Reference (`PROGRAMMERS_REFERENCE.md`)
Drafted and evolved alongside Sub-Phases 3a–3d so it stays in exact lockstep with `include/abi/`, this manual serves as the authoritative, self-contained specification for programming Oasis32 (in the spirit of the *Commodore 64 Programmer's Reference Guide*).

* **Core Boundary Principle:** Defines everything an Oasis32 programmer needs—and is allowed—to know. The underlying RP2350, Pico 2, Hazard3, CH9350, CP2102N, and SD SPI hardware are treated strictly as hidden implementation details. The manual must **never** reference overly permissive vendor hardware datasheets or "slice" the RP2350 datasheet; if a raw RP2350 register ever needs to be mentioned, that signals a missing or leaking BIOS abstraction.
* **Circumscribed Programmer's Bookshelf:** Defers externally **only** to two standard specifications:
  1. **RISC-V Unprivileged ISA Specification** (`riscv-unprivileged.pdf`), scoped strictly by Oasis32's declared standard unprivileged ISA string (e.g., `RV32IMAC_Zifencei`; explicitly excluding `riscv-privileged.pdf` and Hazard3-proprietary `Xh3*` extensions).
  2. **RISC-V ELF psABI Specification** (`ILP32` calling convention).
* **Required Specification Chapters:**
  1. **Machine Model & Execution Rules:** 32-bit little-endian RISC-V, exact declared ISA string, nominal 126 MHz clock, single-core execution model, and explicit prohibition on direct MMIO, privileged CSR, or reserved-memory access.
  2. **Memory Map Contract:** User SRAM window (`USER_RAM_BASE`–`USER_RAM_END`), initial 16-byte-aligned stack top (`USER_STACK_TOP`), reserved/off-limits zones, and usage of `include/abi/memory_map.h` and `include/ld/sd_payload.ld.S`.
  3. **Bootable Disk Format & Startup State:** Exact LBA 0 Boot Image Header binary layout, guaranteed CPU/peripheral state upon jumping to the payload entry point, and clean exit/reboot semantics.
  4. **BIOS ABI & Calling Contract:** Invocation mechanism (Jump Table or `ecall`), `ILP32` register preservation rules, and standard return/error codes.
  5. **Resident BIOS Services Reference:** Complete input/output, blocking/non-blocking, and error specifications for Display/Framebuffer (base, `640×480` 1 bpp geometry, `80`-byte stride, exact bit-to-pixel ordering, VSYNC/frame counter), Keyboard/Mouse polling & report formats, SD 512-byte LBA block read/write & capacity, Debug Serial Console, monotonic µs System Time, Piezo Audio tone control, 3-bit Status LEDs, and System Control (version, reboot).
  6. **Self-Contained Appendices:** Compact 1-page USB HID Keyboard (`Usage Page 0x07`) scan code & modifier table (avoiding the external USB HID Usage Tables PDF), ASCII table, public `include/abi/*.h` quick reference, and built-in ROM fallback/monitor usage (if applicable).

---

## Phase 4: SD-Card Software & OS Development

With the Flash-resident System ROM stabilized and the SD boot chain verified, Phase 4 shifts development to swappable **Stage-2 Bootable Disks** in `disks/`. All software in this phase interacts with the machine strictly through the published BIOS ABI in `include/abi/`.

### Core Objectives
* **Standalone Demos & Utilities:** Build small bootable SD-card programs to validate and stress-test BIOS ABI services (video, input, storage, audio, serial).
* **Interactive Text Console:** Connect keyboard input and display output via the BIOS ABI to implement a text-mode terminal with an integrated font renderer and line-editing capabilities.
* **Command Shell & Monitor:** Provide an interactive REPL with built-in commands for memory inspection/modification, diagnostics, and execution control.
* **Block Storage & Filesystem:** Build a custom filesystem on top of the BIOS SD block I/O services to persist files, configuration, and programs.
* **Program Loading & Execution:** Implement an OS-level loader capable of reading user programs from the filesystem into User SRAM, transferring execution, and returning cleanly to the OS shell.
