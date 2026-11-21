# Pico 2 Desert Island Computer Development Plan

## Phase 1: Test Harness for the Hardware

The goal of this phase is to confirm that the hardware is working and can be driven
entirely without third-party code. This phase does *not* address the true complexity
of developing an OS from scratch. 

To streamline bring-up and separate concerns, this phase is split into two distinct stages:
1. **Stage 1 (Hardware Assembly & C++ Test Harness):** Incrementally solder and electrically verify each peripheral one by one using a progressive, non-blocking C++ test harness built on the Pico SDK. Once all peripherals are verified and operating concurrently, physical soldering and hardware bring-up are complete, allowing the physical tools to be cleared away.
2. **Stage 2 (Pure Bare-Metal RISC-V Assembly Port):** With known-good hardware established, port the complete test harness to pure bare-metal RISC-V assembly with zero linked SDK or runtime code. This creates the golden foundation for Phase 2 (OS development).

### Test Harness Behavior

On startup, the test harness enters a **non-blocking cooperative polling loop** on a single RISC-V core. Rather than using blocking delays (which would starve UART receive FIFOs or cause visual stutter), the loop continuously polls hardware timestamps alongside peripheral status registers to perform the following concurrently:

*  **LEDs:** Blink the Red, Green, and Blue LEDs one after the other, advancing once per second.
*  **Piezo:** Beep the piezo once every five seconds for a duration of **100 ms at 1 kHz** (started and stopped non-blockingly via timer comparison).
*  **Serial Heartbeat:** Print a changing message (such as a timestamp or counter value) to the debug serial port (`UART0`) once a second.
*  **Serial Echo:** Immediately echo incoming keystrokes from the debug serial port (`UART0`) back to the serial port.
*  **HDMI Display:** Maintain a **640×480 monochrome (1 bpp) framebuffer** in SRAM (8 pixels packed per byte = 38,400 bytes). On every main loop cycle, advance one pixel at a time (left-to-right, top-to-bottom, wrapping at the end of the screen), flipping that pixel's bit between off (`0`) and on (`1`).
*  **Keyboard/Mouse:** When keyboard and mouse events appear from the CH9350 (`UART1`), decode the framed packets (and respond to any CH9350 status/polling handshakes if required) and print a summary to the debug serial port (`UART0`).
*  **SD Card:** Treat the SD card as a raw block device (no FAT32 or filesystem assumptions; existing contents on the test card may be overwritten). Once a second, write a 512-byte block containing a changing payload to the SD card, then read it back to confirm that it matches. Cycle sequentially through a large ring of block addresses (e.g., thousands of blocks) to reduce flash wear and thoroughly exercise multi-block addressing.

---

## Stage 1: Hardware Bring-Up & Progressive C++ Test Harness

All C++ development lives in `test_harness/cpp/`.

### Implementation Rules
* **Toolchain & Architecture:** Target the RP2350 Hazard3 RISC-V architecture (`PICO_PLATFORM=rp2350-riscv`, `PICO_BOARD=pico2`) using the official Pico SDK.
* **Strictly Non-Blocking Runtime:** The main loop must be 100% non-blocking. Blocking delays (`sleep_ms`, tight busy-waits on UART/SPI) are prohibited in the main loop to prevent FIFO overruns on the CP2102 and CH9350 and to exercise true multi-peripheral concurrency. (Short, bounded blocking waits are permitted strictly during one-time boot/initialization).
* **Progressive Reduction:** As each subsystem is brought up, code may optionally be reduced from high-level SDK helpers down to raw register operations (`sio_hw`, `uart0_hw`, etc.) to serve as a direct template for Stage 2.

### Sub-Phase 1a: Host-Side Tools & Baseline C++ Blink

#### Hardware
Bare, unmodified Raspberry Pi Pico 2 (using onboard LED on `GPIO25`).

#### Software & Setup
* Install the Raspberry Pi Pico extension in Antigravity IDE / VS Code as described in *Getting Started with Pico* Section 3 to obtain the Pico SDK, RISC-V toolchain (`riscv32-unknown-elf`), CMake, Ninja, and `picotool`.
* Configure `test_harness/cpp/` with a `CMakeLists.txt` targeting `rp2350-riscv` and `pico2`.
* Expose standard VS Code build tasks in `.vscode/tasks.json`:
  * **Build C++ (RISC-V):** `cmake --build build/cpp --target cpp_harness`
  * **Flash C++ (RISC-V):** `picotool load build/cpp/cpp_harness.uf2 -fx`
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

## Stage 2: Pure Bare-Metal RISC-V Assembly Port

With the hardware 100% verified by the C++ golden reference, we transition to pure bare-metal assembly. All code lives in `test_harness/asm/`.

### Implementation Rules
* **Zero Linked SDK / C Runtime:** Standalone assembly only (`-nostdlib`, `-nostartfiles`).
* **Toolchain & Linker:** Standalone `CMakeLists.txt` using `riscv32-unknown-elf-gcc`/`as`/`ld` with `-march=rv32imac_zicsr_zifencei -mabi=ilp32` and a custom bare-metal linker script (`memmap.ld`).
* **Boot Metadata:** Hand-crafted `IMAGE_DEF` block in the first 4 KB of flash declaring the RP2350 Hazard3 architecture and entry point, converted to `.uf2` via `picotool`.
* **VS Code Build Tasks:**
  * **Assemble Bare-Metal (RISC-V):** `cmake --build build/asm --target asm_harness`
  * **Flash Bare-Metal (RISC-V):** `picotool load build/asm/asm_harness.uf2 -fx`

### Progressive Assembly Porting Steps
1. **2a: Bare-Metal Setup & Blink:** Standalone `IMAGE_DEF`, memory map, reset un-gating (`RESETS`), pad isolation clearing (`PADS_BANK0`), and GPIO toggle loop for `GPIO25`.
2. **2b: Clocks, Timers, LEDs & Piezo:** Standalone `XOSC` and `PLL_SYS` configuration, RISC-V CSR/Timer-based non-blocking loop, RGB LED sequence, and PWM/timer piezo beeper.
3. **2c: Serial Port (`UART0`):** Direct register programming of PL011 `UART0` for startup banner, heartbeat, and non-blocking FIFO echo.
4. **2d: Display (`HSTX` + DMA):** Pure bare-metal HSTX register configuration, TMDS crossbar routing, ping-pong DMA setup, and pixel flipping loop.
5. **2e: USB Host (`UART1`):** Direct PL011 `UART1` register polling and packet parser for CH9350 HID frames.
6. **2f: SD Card (`SPI0`):** Direct PL022 `SPI0` register operations for SD command sequence, block write/read, and verification reporting.

At the conclusion of Stage 2, the assembly test harness completely mirrors the C++ test harness, proving total bare-metal control of the hardware and forming the starting point for Phase 2.

---

## Phase 2: OS Foundation

TODO
