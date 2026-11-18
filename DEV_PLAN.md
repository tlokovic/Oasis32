# Pico 2 Desert Island Computer Development Plan

## Phase 1: Test Harness for the hardware

The goal of this phase is to confirm that the hardware is working and can be driven
entirely without third-party code. This phase does *not* address the true complexity
of developing an OS from scratch. At the end of this phase, we will have two implementations
of the same test harness, one written in C++ and one in RISC-V assembly. The assembly
one will become the foundation of the OS development in Phase 2. The C++ one is there to
aid us in development, testing, and debugging the hardware, and will mostly be
ignored after that.

To avoid confounding factors in case any component is faulty or wired incorrectly, we
will attach and test one component at a time, building up progressively until we have
a working system. This way, if the addition of one component introduces faults, we will
know which component is the problem.

For each sub-phase below (`1a` through `1e`), we will:
1. Implement and verify the sub-phase in C++ (`test_harness/cpp/`).
2. Optionally "reduce" the C++ code from high-level Pico SDK calls down to direct hardware register operations to serve as a reference for the assembly port.
3. Implement and verify the sub-phase in pure bare-metal RISC-V assembly (`test_harness/asm/`) before moving on to the next sub-phase.

### Test Harness Behavior

On startup, the test harness enters a **non-blocking polling loop** on a single RISC-V core. Rather than using blocking delays (which would stall UART receive FIFOs or visual updates), the loop continuously polls a free-running hardware timer alongside peripheral status registers to perform the following:

*  **LEDs:** Blink the Red, Green, and Blue LEDs one after the other, advancing once per second.
*  **Piezo:** Beep the piezo once every five seconds for a duration of **100 ms at 1 kHz** (started and stopped non-blockingly via the hardware timer).
*  **Serial Heartbeat:** Print a changing message (such as a timestamp or counter value) to the debug serial port (`UART0`) once a second.
*  **Serial Echo:** Immediately echo incoming keystrokes from the debug serial port (`UART0`) back to the serial port.
*  **HDMI Display:** Maintain a **640×480 monochrome (1 bpp) framebuffer** in SRAM (8 pixels packed per byte = 38,400 bytes). On every main loop cycle, advance one pixel at a time (left-to-right, top-to-bottom, wrapping at the end of the screen), flipping that pixel's bit between off (`0`) and on (`1`).
*  **Keyboard/Mouse:** When keyboard and mouse events appear from the CH9350 (`UART1`), decode the framed packets (and respond to any CH9350 status/polling handshakes if required) and print a summary to the debug serial port (`UART0`).
*  **SD Card:** Treat the SD card as a raw block device (no FAT32 or filesystem assumptions; existing contents on the test card may be overwritten). Once a second, write a 512-byte block containing a changing payload to the SD card, then read it back to confirm that it matches. Cycle sequentially through a large ring of block addresses (e.g., thousands of blocks) to reduce flash wear and thoroughly exercise multi-block addressing.

### C++ Implementation Constraints

The C++ implementation will be located in `test_harness/cpp/`. It will use *only* the Pico
2 SDK, and no other third-party libraries. This will help "keep us honest" to the actual
goal of owning all of the code and driving the hardware without third-party code.

*  **Target Architecture:** Targets the RP2350 Hazard3 RISC-V cores (`rp2350-riscv`) so its behavior and memory map match the assembly implementation.
*  **Progressive Reduction:** Each sub-phase may initially use high-level Pico SDK routines (e.g., `gpio_*`, `uart_*`, `spi_*`, `pwm_*`) to quickly confirm the hardware works. Once working, we may optionally refactor those calls down to raw register reads/writes (and inspect the compiler's generated RISC-V assembly via `objdump`) to prepare for writing the hand-written assembly version.

### Assembly Implementation Constraints & Tooling

The assembly implementation will be located in `test_harness/asm/`. It will perform the
minimal initialization to put the RISC-V core in M-mode, configure clocks and pads, and
initialize the hardware for the behaviors described above with **zero linked SDK or standard library code**.

To keep host-side tooling minimal and consistent with the C++ build, both implementations will use the same standard toolchain:
*  **Build System:** **CMake** (with Ninja/Make), using a standalone `CMakeLists.txt` in `test_harness/asm/` that does *not* link the Pico SDK.
*  **Assembler & Linker:** Standard GNU RISC-V embedded toolchain (`riscv32-unknown-elf-gcc` / `as` / `ld` / `objdump`) invoked with `-march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles` and a custom bare-metal linker script (`memmap.ld`).
*  **Boot Metadata & Flashing:** The assembly source will embed the required RP2350 `IMAGE_DEF` metadata block directly in a `.S` section in the first 4 KB of flash, and the CMake build will invoke `picotool` as a post-build step to convert the linked `.elf` into a `.uf2` file for USB drag-and-drop flashing.

### Phase 1a: LEDs, Piezo, and Reset

In this phase, only the LEDs, Piezo, and reset button are wired up:
*  Configure system clocks and a free-running hardware timer for non-blocking timekeeping.
*  Implement the non-blocking main loop driving the 1-second R -> G -> B LED sequence and the once-every-5-seconds 100 ms @ 1 kHz piezo beep.
*  Verify that pressing the reset button cleanly restarts the sequence (and enters `BOOTSEL` mode when held with `BOOTSEL`).
*  Complete in `test_harness/cpp/`, then in `test_harness/asm/`.

### Phase 1b: Serial port

In this phase, the serial port (CP2102N on `UART0`, `GP0`/`GP1`) is wired up:
*  Update startup code to initialize `UART0` at 115200 baud, 8N1 (using Pico SDK `stdio`/UART in C++ initially, and direct bytewise `UART0` register access in assembly).
*  Print a startup banner message on boot.
*  Add the once-a-second changing status message to the non-blocking main loop.
*  Poll `UART0` on every loop iteration and immediately echo any received characters back to the serial port.
*  Complete in `test_harness/cpp/`, then in `test_harness/asm/`.

### Phase 1c: Display

In this phase, the DVI Sock (`GP12–GP19`) is wired up:
*  Allocate the 640×480 1 bpp monochrome framebuffer (38,400 bytes, 8 pixels packed per byte).
*  Configure `PLL_SYS` / `CLK_HSTX`, the `HSTX` 1-bit-per-pixel TMDS expander/crossbar, and DMA channels to continuously scan out the 1 bpp framebuffer at 640×480 @ 60 Hz.
*  In the main loop, advance one pixel per loop iteration (left-to-right, top-to-bottom), flipping the pixel between off and on to produce a constantly changing pattern on the HDMI display.
*  Complete in `test_harness/cpp/`, then in `test_harness/asm/`.

### Phase 1d: Keyboard/Mouse

In this phase, the CH9350 (`UART1`, `GP20`/`GP21`) is wired up:
*  Initialize `UART1` at 115200 baud, 8N1.
*  In the non-blocking main loop, poll `UART1` to parse incoming `0x57 0xAB`-framed CH9350 serial HID datagrams (and transmit any required Lower Computer mode polling/handshake replies over `UART1 TX`).
*  When keyboard or mouse events arrive, print a human-readable summary to the debug serial port (`UART0`).
*  Complete in `test_harness/cpp/`, then in `test_harness/asm/`.

### Phase 1e: SD Card

In this phase, the SD card breakout (`SPI0`, `GP2–GP6`) is wired up:
*  Initialize `SPI0` at low speed (100–400 kHz) with software-controlled `CS` (`GP5`) and Card Detect (`GP6`), run the SD SPI initialization sequence (`CMD0`, `CMD8`, `ACMD41`, `CMD58`), and switch `SPI0` to high speed.
*  Once per second, write a 512-byte block with a changing test pattern to the current LBA block address, read it back, verify all 512 bytes match, and report pass/fail (and block number) over `UART0`.
*  Advance the target LBA across a large ring of block addresses on each write to distribute flash wear and test block addressing.
*  Complete in `test_harness/cpp/`, then in `test_harness/asm/`.

## Phase 2: OS Foundation

TODO
