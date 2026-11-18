# Authoritative Reference Manuals ("The Desert Island Bookshelf")

## 1. Philosophy & Approach

A core goal of the **Pico 2 Desert Island Computer** project is complete personal understanding and ownership of how the machine works—down to the bare-metal hardware registers, instruction encodings, and wire protocols—without treating either vendor SDKs or AI assistants as opaque black boxes.

To achieve that, all technical discussions, hardware bring-up steps, and register-level code in this project are anchored in a fixed set of **authoritative primary reference manuals**:

1. **Single Source of Truth:** Whenever we configure a peripheral, inspect a register bitfield, or implement a hardware protocol, we cite the specific manual, section (`§`), and register/table name from this list.
2. **Local Copies Without Repo Bloat or Copyright Risk:** Some vendor specifications (such as Raspberry Pi and RISC-V manuals) are released under Creative Commons licenses, while others (such as SD Card Association and WCH/Silicon Labs datasheets) carry standard *"All Rights Reserved"* restrictions on redistribution. To respect all licenses and keep the Git repository lightweight:
   * The `downloaded_references/` directory is listed in [`.gitignore`](.gitignore) and is not committed to GitHub.
   * Running [`download_references.ps1`](download_references.ps1) parses **this file (`REFERENCES.md`)** directly, downloads every manual from its official web source into `downloaded_references/`, and makes all of the **Local File** links below clickable on your machine (and readable directly by AI assistants in your workspace).

### Syncing Local References

From PowerShell or Command Prompt in the repository root, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\download_references.ps1
```

Because `download_references.ps1` parses the `**Web Source:**` and `**Local File:**` lines in each section below, adding or updating a reference in `REFERENCES.md` automatically updates what the script downloads.

---

## 2. Core Microcontroller & Board Manuals

### RP2350 Datasheet
The primary architectural and register-level reference for the Raspberry Pi RP2350 microcontroller. Every memory-mapped register address, bitfield definition, peripheral state machine, and boot sequence used in our bare-metal C++ and RISC-V assembly code comes from this document.

* **Web Source:** [https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
* **Local File:** [downloaded_references/rp2350-datasheet.pdf](downloaded_references/rp2350-datasheet.pdf)
* **Used In:** All phases (Phase 1a–1e and Phase 2 OS)
* **Key Sections for This Project:**
  * **Chapter 2 (`§2`):** System Bus & Address Map (base addresses and atomic `+0x1000`/`+0x2000`/`+0x3000` XOR/SET/CLR register aliases).
  * **Chapter 3 (`§3.1` & `§3.8`):** Single-cycle IO block (`SIO` for GPIO) and **Hazard3 RISC-V Processor** architecture, CSRs, and interrupt controller (`Xh3irq`).
  * **Chapter 5 (`§5.1`–`§5.9`):** Boot ROM concepts and `PICOBIN` `IMAGE_DEF` block format required to boot bare-metal RISC-V binaries.
  * **Chapter 6 (`§6.4`):** Power Manager (`POWMAN`) and reset-cause registers (`CHIP_RESET`).
  * **Chapter 7 (`§7.5`):** Subsystem Resets (`RESETS->RESET` and `RESETS->RESET_DONE`).
  * **Chapter 8 (`§8.1`–`§8.6`):** Clocks (`CLOCKS`), Crystal Oscillator (`XOSC`), and System PLL (`PLL_SYS`).
  * **Chapter 9 (`§9.11`):** GPIO Function Select (`IO_BANK0`) and Pad Control (`PADS_BANK0`, including the `ISO` pad isolation bit).
  * **Chapter 12 (`§12.1`, `§12.2`, `§12.5`, `§12.6`, `§12.8`, `§12.11`):** Peripherals — `UART`, `SPI`, `PWM`, `DMA`, `TIMER`, and `HSTX` (High-Speed Serial Transmit with hardware TMDS encoding).
* **License:** Creative Commons Attribution-NoDerivatives 4.0 International (`CC BY-ND 4.0`), Raspberry Pi Ltd.

---

### Raspberry Pi Pico 2 Datasheet
Board-level specification for the Raspberry Pi Pico 2 development board. Documents how the RP2350 chip is wired to the 40 physical castellated pins, the onboard power supply chain, the `BOOTSEL` button, and the `RUN` reset pin.

* **Web Source:** [https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf)
* **Local File:** [downloaded_references/pico-2-datasheet.pdf](downloaded_references/pico-2-datasheet.pdf)
* **Used In:** Hardware wiring verification and Phase 1a–1e board bring-up
* **Key Sections for This Project:**
  * **Section 2.1:** Pico 2 Pinout Diagram and pin function table.
  * **Section 3.3–3.5:** Power chain (`VBUS`, `VSYS` Schottky diode, and `3V3` SMPS current limits).
  * **Appendix B:** Full Pico 2 board schematic (showing onboard pull-ups on `RUN`, LED/USB boot circuitry, and flash wiring).
* **License:** Creative Commons Attribution-NoDerivatives 4.0 International (`CC BY-ND 4.0`), Raspberry Pi Ltd.

---

### Raspberry Pi Pico-series C/C++ SDK Manual
Official reference manual for the Raspberry Pi Pico C/C++ SDK. Used during the initial C++ step of each Phase 1 sub-phase (`test_harness/cpp/`) and when performing an "SDK autopsy" to see which low-level registers each `hardware_*` SDK function modifies before writing our pure RISC-V assembly version.

* **Web Source:** [https://datasheets.raspberrypi.com/pico/raspberry-pi-pico-c-sdk.pdf](https://datasheets.raspberrypi.com/pico/raspberry-pi-pico-c-sdk.pdf)
* **Local File:** [downloaded_references/raspberry-pi-pico-c-sdk.pdf](downloaded_references/raspberry-pi-pico-c-sdk.pdf)
* **Used In:** Phase 1a–1e C++ Test Harness (`test_harness/cpp/`)
* **Key Sections for This Project:**
  * **Section 4.1 (`hardware_*` libraries):** Low-level hardware APIs (`hardware_gpio`, `hardware_pwm`, `hardware_timer`, `hardware_uart`, `hardware_spi`, `hardware_dma`, `hardware_clocks`, `hardware_pll`, `hardware_resets`).
* **License:** Creative Commons Attribution-NoDerivatives 4.0 International (`CC BY-ND 4.0`), Raspberry Pi Ltd.

---

## 3. RISC-V Processor Architecture Manuals

### The RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture
The official specification for the unprivileged RISC-V instruction set implemented by the RP2350's dual Hazard3 cores (`RV32IMAC` plus `Zicsr`, `Zifencei`, `Zba`, `Zbb`, `Zbs`, `Zbkb`, `Zcb`, `Zcmp`).

* **Web Source:** [https://github.com/riscv/riscv-isa-manual/releases/download/20240411/unpriv-isa-asciidoc.pdf](https://github.com/riscv/riscv-isa-manual/releases/download/20240411/unpriv-isa-asciidoc.pdf)
* **Local File:** [downloaded_references/riscv-unprivileged.pdf](downloaded_references/riscv-unprivileged.pdf)
* **Used In:** Phase 1a–1e Assembly Test Harness (`test_harness/asm/`) and Phase 2 OS
* **Key Sections for This Project:**
  * **Chapter 2:** `RV32I` Base Integer Instruction Set (register conventions, loads/stores, branches, jumps).
  * **Chapter 6:** `"Zicsr"` Extension for Control and Status Register (`CSR`) instructions (`csrrw`, `csrrs`, `csrrc`).
  * **Chapter 12 & 13:** `"M"` Integer Multiplication/Division and `"A"` Atomic Instructions.
  * **Chapter 26 & 28:** `"C"` / `"Zcb"` / `"Zcmp"` Compressed Instructions (including push/pop stack frame instructions) and Bit-Manipulation Extensions (`Zba`, `Zbb`, `Zbs`).
  * **Chapter 34:** RV32/64G Instruction Set Listings (opcode map and instruction bit formats).
* **License:** Creative Commons Attribution 4.0 International (`CC BY 4.0`), RISC-V International.

---

### The RISC-V Instruction Set Manual, Volume II: Privileged Architecture
The official specification for RISC-V Machine Mode (`M-mode`), User Mode (`U-mode`), trap/interrupt handling, physical memory protection (`PMP`), and machine timers.

* **Web Source:** [https://github.com/riscv/riscv-isa-manual/releases/download/20240411/priv-isa-asciidoc.pdf](https://github.com/riscv/riscv-isa-manual/releases/download/20240411/priv-isa-asciidoc.pdf)
* **Local File:** [downloaded_references/riscv-privileged.pdf](downloaded_references/riscv-privileged.pdf)
* **Used In:** Phase 1a–1e Assembly Test Harness (`test_harness/asm/`) and Phase 2 OS
* **Key Sections for This Project:**
  * **Chapter 3:** Machine-Level ISA (`misa`, `mstatus`, `mtvec`, `mip`, `mie`, `mtime`/`mtimecmp`, `mscratch`, `mepc`, `mcause`, `mtval`, and `mret`).
  * **Chapter 3.7:** Physical Memory Protection (`PMP`) for isolating OS vs. user tasks in Phase 2.
* **License:** Creative Commons Attribution 4.0 International (`CC BY 4.0`), RISC-V International.

---

### Hazard3 CPU Technical Reference Manual
Authoritative documentation by Luke Wren for the 3-stage pipeline **Hazard3** RISC-V processor core integrated into the RP2350. Explains Hazard3-specific custom CSRs, interrupt vectoring (`Xh3irq`), power-management instructions (`Xh3power`), and cycle timings.

* **Web Source:** [https://github.com/Wren6991/Hazard3/releases/download/v1.1/hazard3.pdf](https://github.com/Wren6991/Hazard3/releases/download/v1.1/hazard3.pdf)
* **Local File:** [downloaded_references/hazard3-manual.pdf](downloaded_references/hazard3-manual.pdf)
* **Used In:** Phase 1a–1e Assembly Test Harness (`test_harness/asm/`) and Phase 2 OS
* **Key Sections for This Project:**
  * Supported standard and custom ISA extensions (`Xh3irq` external interrupt controller CSRs `meiea`, `meipa`, `meinext`, `meicontext`).
  * Pipeline organization and instruction cycle latencies.
* **License:** Creative Commons Attribution 4.0 International (`CC BY 4.0`), Luke Wren.

---

## 4. Peripheral & Protocol Specifications

### Silicon Labs CP2102N USB-to-UART Bridge Datasheet
Datasheet for the CP2102N USB-to-UART bridge IC used on the Adafruit CP2102N Friend breakout board. Covers logic levels, baud rate tolerances, pin behavior, and power states.

* **Web Source:** [https://www.silabs.com/documents/public/data-sheets/cp2102n-datasheet.pdf](https://www.silabs.com/documents/public/data-sheets/cp2102n-datasheet.pdf)
* **Local File:** [downloaded_references/cp2102n-datasheet.pdf](downloaded_references/cp2102n-datasheet.pdf)
* **Used In:** Phase 1b (Serial Debugging over `UART0`)
* **License:** Proprietary vendor datasheet (© Silicon Laboratories Inc., downloaded for local reference only).

---

### WCH CH9350L USB Keyboard & Mouse to UART Control Chip Datasheet
Official datasheet from Nanjing Qinheng Microelectronics (WCH) for the CH9350L Dual USB Host-to-UART HID controller IC. Documents the pin configurations for Upper vs. Lower Computer Mode, baud rate selection straps, and the `0x57 0xAB` framed serial datagram protocol.

* **Web Source:** [https://www.wch-ic.com/downloads/CH9350DS_PDF.html](https://www.wch-ic.com/downloads/CH9350DS_PDF.html)
* **Local File:** [downloaded_references/CH9350DS.PDF](downloaded_references/CH9350DS.PDF)
* **Used In:** Phase 1d (Keyboard/Mouse over `UART1`)
* **Key Details:**
  * Lower Computer Mode hardware configuration and UART settings (`115200` baud, `8N1`).
  * Serial communication frame formats (`0x57 0xAB` sync header, command/opcode byte, HID report payload bytes, and status/handshake frames).
* **License:** Proprietary vendor datasheet (© Nanjing Qinheng Microelectronics Co., Ltd., downloaded for local reference only).

---

### SD Specifications Part 1: Physical Layer Simplified Specification (v2.00)
The Physical Layer Simplified Specification from the SD Card Association. Specifically, **Section 7 (SPI Mode)** is the definitive reference for driving SD, SDHC, and SDXC cards over a 4-wire SPI bus (`CS`, `CLK`, `MOSI`/`DI`, `MISO`/`DO`).

* **Web Source:** [https://academy.cba.mit.edu/classes/networking_communications/SD/SD.pdf](https://academy.cba.mit.edu/classes/networking_communications/SD/SD.pdf)
* **Local File:** [downloaded_references/sd-physical-layer-simplified-spec.pdf](downloaded_references/sd-physical-layer-simplified-spec.pdf)
* **Used In:** Phase 1e (SD Card Block Storage over `SPI0`) and Phase 2 OS Block Driver
* **Key Sections for This Project:**
  * **Section 7.2.1:** Mode Selection and SPI Mode Initialization Flow (`CMD0`, `CMD8`, `CMD55` + `ACMD41`, `CMD58` OCR/CCS bit check).
  * **Section 7.2.3 & 7.2.4:** Data Read (`CMD17` Single Block Read and `0xFE` start-block token) and Data Write (`CMD24` Single Block Write, data-response token, and busy polling).
  * **Section 7.3:** SPI Command and Response Formats (`R1`, `R3`, `R7`, and 6-byte command framing).
* **License:** © SD Group and SD Card Association (Simplified Specification, downloaded for local reference only).
