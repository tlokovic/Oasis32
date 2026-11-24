# Pico 2 Desert Island Computer Development Plan

## Project Overview

The objective of this project is to construct a self-contained computer powered by the Raspberry Pi Pico 2 that can be programmed completely from bare-metal RISC-V assembly with zero third-party software, drivers, or SDKs.

The roadmap is divided into three sequential phases:
1. **Phase 1: Test Hardware with Pico C++ SDK:** Incrementally assemble, solder, and electrically verify the hardware peripherals using a non-blocking C++ test harness. Once complete, all soldering tools are put away and the physical platform is frozen as known-good.
2. **Phase 2: Port Test Harness to RISC-V Assembly:** Re-implement the full test harness in pure, bare-metal RISC-V assembly with zero linked libraries or SDK code, establishing our hardware-abstraction foundation.
3. **Phase 3: OS Development:** Build the native operating system, interactive shell, filesystem, and programming environment on top of the bare-metal assembly foundation.

---

## Phase 1: Test Hardware with Pico C++ SDK

The goal of this phase is to confirm that the hardware is functioning and electrically sound. To eliminate ambiguous faults (distinguishing bad solder joints from register or compiler bugs), all hardware bring-up is conducted in C++ using the official Raspberry Pi Pico SDK (but no other libraries).

Peripherals are attached and tested one at a time. If an addition introduces a fault, the issue is isolated immediately to the newly attached component.

### Test Harness Behavior

All development in Phase 1 lives in `test_harness/cpp/`. 

On startup, the test harness enters a **non-blocking cooperative polling loop** on a single RISC-V core (`rp2350-riscv`). Rather than using blocking delays (which would starve UART receive FIFOs or cause visual stutter), the loop continuously checks hardware timestamps alongside peripheral status registers to run the following tasks concurrently:

* **LEDs:** Blink the Red, Green, and Blue LEDs sequentially, advancing once per second.
* **Piezo:** Beep the piezo once every five seconds for a duration of **100 ms at 1 kHz** (started and stopped non-blockingly via timer comparison).
* **Serial Heartbeat:** Print an incrementing timestamp/counter message to the debug serial port (`UART0`) once a second.
* **Serial Echo:** Immediately echo incoming keystrokes from `UART0` back to the host terminal.
* **HDMI Display:** Maintain a **640×480 monochrome (1 bpp) framebuffer** in SRAM (38,400 bytes). On every loop iteration, advance one pixel at a time (left-to-right, top-to-bottom) and flip that pixel's bit between off (`0`) and on (`1`) to generate continuous video activity.
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
* Add the once-every-5-seconds 100 ms @ 1 kHz piezo beep (driven via PWM or timer-toggled GPIO).
* Verify that pressing the reset button cleanly restarts the sequence (and enters `BOOTSEL` mode when held with `BOOTSEL`).

### Sub-Phase 1c: Solder Serial Port (CP2102N Debug Port)

#### Hardware
Solder the CP2102N USB-to-UART bridge (`UART0`, `GP0` TX, `GP1` RX).

#### Software
* Initialize `UART0` at 115200 baud, 8N1.
* Transmit a boot banner message upon startup.
* Add the once-per-second status/heartbeat message to the main loop.
* Poll `UART0` on every main loop iteration and immediately echo any received characters back to the host terminal.

### Sub-Phase 1d: Solder Display (DVI Sock)

#### Hardware
Solder the Adafruit DVI Sock (`GP12–GP19`).

#### Software
* Allocate the 640×480 1 bpp monochrome framebuffer (38,400 bytes).
* Configure `PLL_SYS` / `CLK_HSTX`, the `HSTX` serializer/crossbar, and DMA channels to stream out 640×480 @ 60 Hz video.
* In the non-blocking main loop, advance and toggle one pixel per loop iteration to produce a continuous visual pattern on the HDMI display without interrupting LED or UART tasks.

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

## Phase 3: OS Development

With the bare-metal assembly drivers and execution harness established, Phase 3 builds the native "desert-island" operating system in bare-metal assembly.

### Core Objectives
* **Interactive Text Console:** Connect keyboard input from the CH9350 and display output via the DVI Sock to implement a text-mode terminal with an integrated font renderer and line-editing capabilities.
* **Command Shell & Monitor:** Provide an interactive REPL with built-in commands for memory inspection/modification, hardware diagnostics, register dumping, and execution control.
* **Block Storage & Filesystem:** Expand the raw SPI SD card driver with a filesystem driver (e.g., standard FAT32 or a lightweight custom filesystem) to persist files, configuration, and scripts.
* **Program Loading & Execution:** Implement an execution loader capable of reading binary programs from storage into RAM, transferring execution, and returning cleanly to the OS shell.
