# Oasis32 — Pico 2 Desert Island Computer

![Assembled Left Side](images/assembled_left_side.jpg)
![Assembled Left Side](images/assembled_right_side.jpg)

## 1. Overview

**Oasis32** is a "desert-island" computer powered by the Raspberry Pi Pico 2 that can be programmed entirely in baremetal
C++ or assembly without relying on any third-party code: no reliance on libraries, drivers, or SDKs.
The hardware design ensures that all peripherals use simple DMA, UART, SPI, or GPIO.

## 2. Hardware Summary

The main system components are as follows:

* **CPU: Raspberry Pi Pico 2:** Can be programmed in C++, ARM assembly, or RISC-V assembly.  [Source from Digikey](https://www.digikey.com/short/9jjv5q9v)
* **Display: Adafruit DVI Sock:** Provides an HDMI port and can expose a simple framebuffer
to C++ or assembly as a DMA region.  [Source from Adafruit](https://www.adafruit.com/product/5957)
* **Keyboard/Mouse: CH9350 Dual USB Host-to-UART ASIC:** USB HID controller that supports a keyboard and mouse, handles USB negotiation, and translates incoming HID packets into framed serial datagrams over UART. This provides access to modern keyboard/mouse without a full USB software stack. [Source from Amazon](https://www.amazon.com/dp/B0FR94RZ82?ref=ppx_yo2ov_dt_b_fed_asin_title)
* **Storage: SD Card Breakout Board:** This uses full-sized SD cards which can be accessed as block devices directly with SPI. [Source from Digikey](https://www.digikey.com/short/t37tp9rr)
* **Serial Debugging: Adafruit CP2102N:** Provides a USB-C port which presents to a host machine as a terminal device, while
presenting to the Pico as simple UART. [Source on Adafruit](https://www.adafruit.com/product/5335)
* **Audio: Piezo Buzzer:** Provides simple beeps, driven by PWM pins on the Pico. [Source on Adafruit](https://www.adafruit.com/product/160)
* **Status: LEDs:** Three programmable LEDs, driven by GPIO pins.
* **Reset: Momentary Button:** A button that resets the Pico.

## 3. Hardware/wiring details

### CPU: Raspberry Pi Pico 2

For now, power is provided to the Pico over the same built-in Micro USB port that is used to program the device. This
provides for no built-in power switch, so for now the computer is powered on by plugging in, and powered off by unplugging
it.

A later iteration will provide a power switch (over VSYS).

#### Programming notes (From AI, unverified)

* **Boot Metadata (`IMAGE_DEF`):** Unlike the RP2040 (which used a 256-byte CRC-checked `boot2` stage), the RP2350 Boot ROM scans the first 4 KB of flash for a valid `PICOBIN` `IMAGE_DEF` block. Bare-metal linker scripts and startup binaries must embed this metadata block to declare the target architecture (Arm Cortex-M33 Secure or Hazard3 RISC-V) and initial vector table / entry point.
* **Clocks & PLLs:** Out of reset, the CPU runs from the inaccurate internal Ring Oscillator (`ROSC`). Startup code must enable the 12 MHz external crystal oscillator (`XOSC`), wait for it to stabilize, configure the System PLL (`PLL_SYS`—for example, 150 MHz general operation or 126/252 MHz to cleanly derive a 25.2 MHz DVI pixel clock), and switch the `CLK_REF`, `CLK_SYS`, and `CLK_PERI` glitchless clock multiplexers.
* **Subsystem Resets (`RESETS`):** Almost all hardware blocks (`IO_BANK0`, `PADS_BANK0`, `UART0`, `UART1`, `SPI0`, `PWM`, `HSTX`, `PIO`, `DMA`) are held in reset at boot. Before touching a peripheral's registers, its bit must be cleared in the `RESETS->RESET` register and polled until `1` in `RESETS->RESET_DONE`.
* **Pad Isolation (`PADS_BANK0` `ISO` bit):** New on the RP2350, every GPIO pad wakes up with its pad isolation latch bit (`ISO`, bit 8) set to `1` in `PADS_BANK0`. Even after setting `IO_BANK0` function select (`FUNCSEL`), a pin will not pass signals in or out until its `ISO` bit is explicitly cleared to `0` in `PADS_BANK0`.

### Display: Adafruit DVI Sock

This sock is built specifically around the Pico, and uses the following connections:

| Pico  | DVI Sock |
| ------------- | ------------- |
| Pin 16 / GP12 | D0+ |
| Pin 17 / GP13 | D0- |
| Pin 18 / GND | GND |
| Pin 19 / GP14 | CK+ |
| Pin 20 / GP15 | CK- |
| Pin 21 / GP16 | D2+ |
| Pin 22 / GP17 | D2- |
| Pin 23 / GND | GND |
| Pin 24 / GP18 | D1+ |
| Pin 25 / GP19 | D1- |

See [this Adafruit tutorial](https://learn.adafruit.com/adafruit-dvi-sock-for-pico) for details on how to drive the display
from software. This can be driven with PIO or, on the Pico 2, with HSTX (High-Speed Serial Transmit).

#### Programming notes (From AI, unverified)

* **GPIO Multiplexing & Pad Settings:** Configure `GP12–GP19` `FUNCSEL` in `IO_BANK0` to `HSTX` (Function 0) if using the dedicated hardware serializer, or `PIO0`/`PIO1` if using PIO. In `PADS_BANK0`, clear `ISO`, set fast slew rate, disable schmitt/input receivers if output-only, and set drive strength to 4 mA or 8 mA across all eight pins.
* **Pixel & Bit Clocking:** Standard 640×480 @ 60 Hz DVI uses a 25.175 MHz pixel clock (typically run at 25.2 MHz) and a 10× serialized TMDS bit rate of 252 Mbps per lane. With the RP2350's DDR-capable `HSTX` block, `CLK_HSTX` only needs to run at 126 MHz (shifting out 2 bits per clock cycle).
* **HSTX Crossbar & TMDS Encoding:** The `HSTX` peripheral natively handles 8b/10b TMDS encoding and command-stream expansion (separating blanking/sync periods from active pixel data). Its output crossbar (`BIT0–BIT7` CSRs) must be programmed to route the three TMDS data lanes and clock lane to the exact pin order of the DVI Sock (`GP12/13` = `D0+/D0-`, `GP14/15` = `CK+/CK-`, `GP16/17` = `D2+/D2-`, `GP18/19` = `D1+/D1-`), setting the hardware invert bit on each `-` pin to form pseudo-differential pairs.
* **DMA Pacing:** Configure one or two ping-pong/chained DMA channels paced by `DREQ_HSTX` to continuously stream scanline control words (HSYNC, VSYNC, back/front porch durations) and framebuffer pixel data into the HSTX FIFO without blocking the CPU.

### Keyboard/Mouse: CH9350 Dual USB Host-to-UART ASIC

The CH9350 acts as a hardware bridge between standard USB HID peripherals (keyboards, mice) and an asynchronous serial UART interface (`CH9350DS.PDF §5, pp. 4–13`). It handles USB enumeration and protocol negotiation entirely in silicon, translating HID reports into framed serial datagrams over UART.

#### Hardware DIP Switch Configuration

The module features a 5-position DIP switch that directly sets the strapping configuration pins of the CH9350 (`CH9350DS.PDF §5, pp. 3–4`).

##### Switch Orientation & Logic Levels
* **Left Position (marked `1` on PCB, away from `ON`):** Switch OPEN / OFF. The CH9350 internal pull-ups pull the pin to **3.3V Logic High (`1`)**.
* **Right Position (marked `0` on PCB, towards `ON`):** Switch CLOSED / ON. Shorts the strapping pin to **GND Logic Low (`0`)**.

##### Required Switch Settings: Lower Computer Mode, 115200 Baud, State 2

To operate as a standalone USB host streaming clean HID events to the Pico 2, configure the 5 switches as follows:

| Switch # | Strapping Pin | Target Level | Physical Position | Configuration Function & Datasheet Citation |
|:---:|:---:|:---:|:---:|:---|
| **1** | `SEL` | **`1`** | **LEFT** | **Lower Computer (Host) Mode** (`CH9350DS.PDF §5, Pin 45, p. 4`). Configures the chip as a USB Host to manage keyboard and mouse devices. (`0` = Upper Computer / USB Device mode). |
| **2** | `BA1` | **`1`** | **LEFT** | **Baud Rate Bit 1 = High** (`CH9350DS.PDF §7.1.7, Table 7-2, p. 6`). |
| **3** | `BA0` | **`1`** | **LEFT** | **Baud Rate Bit 0 = High** (`BA1:BA0 = 11` selects **115,200 baud**). |
| **4** | `S1` | **`1`** | **LEFT** | **Working State Bit 1 = High** (`CH9350DS.PDF §7.1.6, Table 7-1, p. 6`). |
| **5** | `S0` | **`0`** | **RIGHT** | **Working State Bit 0 = Low** (`S1:S0 = 10` selects **State 2**). |

```text
       [ 1 ]       [ 0 ]
         │           │
     ┌───┴───────────┴───┐
  1  │ [███]             │  SEL  = 1 (Host Mode)
  2  │ [███]             │  BA1  = 1 \_ 115,200 Baud
  3  │ [███]             │  BA0  = 1 /
  4  │ [███]             │  S1   = 1 \_ State 2 (Fixed HID Datagrams)
  5  │             [███] │  S0   = 0 /
     └───────────────────┘
```
*(Summary: **Push levers 1, 2, 3, and 4 to the LEFT; leave lever 5 to the RIGHT**).*

##### Why State 2 (`S1=1, S0=0`)?
* **Default State 0/1 (`S1=1, S0=1`):** Designed for paired CH9350 extension cables. In State 0/1, the lower computer continuously transmits status request ping packets (`0x57 0xAB 0x82 0xA*`) every 66 ms to 1 s and expects a handshake reply frame from the host, with variable-length `0x88` key frames requiring checksum verification (`CH9350DS.PDF §7.2.3.1, p. 9`).
* **State 2 (`S1=1, S0=0`):** Designed for direct microcontroller integration (`CH9350DS.PDF §7.2.3.3, pp. 9–11`). It operates strictly **one-way** from CH9350 to Pico without any handshaking, polling frames, or keep-alive replies:
  * **Keyboard Datagram (Fixed 11 bytes):**
    ```text
    0x57 0xAB 0x01 [Mod] 0x00 [Key1] [Key2] [Key3] [Key4] [Key5] [Key6]
    ```
    Where `Mod` is the standard 8-bit USB modifier bitmap (Ctrl, Shift, Alt, GUI) followed by up to 6 pressed USB HID keycodes.
  * **Relative Mouse Datagram (Fixed 7 bytes):**
    ```text
    0x57 0xAB 0x02 [Buttons] [dX] [dY] [Wheel]
    ```

#### Connections to Pico 2

| CH9350 Module Pin | Pico 2 Pin | Electrical Function |
|:---|:---|:---|
| **`5V`** | **Pin 39 (`VSYS`)** | Supplies 5V VBUS power to the connected USB keyboard and mouse. |
| **`GND`** | **Pin 38 or Pin 8 (`GND`)** | Common system ground. |
| **`TX`** | **Pin 27 (`GP21` / `UART1 RX`)** | Asynchronous serial datagram stream from CH9350 into Pico. |
| **`RX`** | **Pin 26 (`GP20` / `UART1 TX`)** | Pico transmit line back to CH9350 (optional in State 2, but wired for completeness). |
| **`485控制`** | *Leave unconnected* | `TNOW` transmit status pin used for half-duplex RS-485 direction switching. |

#### Programming Notes

* **GPIO & Pad Configuration:** Set `GP20` and `GP21` `FUNCSEL` to `UART` (Function 2) in `IO_BANK0` (`rp2350-datasheet.pdf §9.4, Table 677`). In `PADS_BANK0`, clear `ISO` on both pins, enable input (`IE`) on `GP21`, and enable the internal pull-up resistor (`PUE`) on `GP21` (`UART1 RX`) so the receive line idles cleanly at logic high (`1`) even while the CH9350 is booting or disconnected (`rp2350-datasheet.pdf §9.11.3, Table 708`).
* **UART1 Setup:** Ensure `CLK_PERI` is running and deassert `UART1` in `RESETS` (`rp2350-datasheet.pdf §7.5.3, Table 567`). Compute the integer (`UARTIBRD`) and fractional (`UARTFBRD`) baud rate divisors from `CLK_PERI` for `115200` baud:
  $$\text{Baud Rate Divisor} = \frac{f_{\text{clk\_peri}}}{16 \times 115200}$$
  Configure `UARTLCR_H` for 8-bit words (`WLEN = 0b11`), no parity, 1 stop bit, and enable the 32-byte hardware FIFOs (`FEN = 1`) before enabling `UARTEN`, `TXE`, and `RXE` in `UARTCR`.
* **Datagram Parsing:** In State 2, poll `UART1` or service its RX interrupt by scanning for the two sync bytes (`0x57`, `0xAB`). When detected, read the type byte:
  * If `0x01`: Read the remaining 8 bytes of standard USB BIOS keyboard scan codes.
  * If `0x02`: Read the remaining 4 bytes of relative mouse movement (buttons, $\Delta X$, $\Delta Y$, wheel).

### Storage: SD Card Breakout Board

This is accessed via SPI, and uses the following connections:

| Pico  | SD Breakout |
| ------------- | ------------- |
| Pin 36 / 3V3 Out | VD |
| GND | GD |
| Pin 4 / GP2 / SPI0 SCK | CK |
| Pin 5 / GP3 / SPI0 TX | CMD |
| Pin 6 / GP4 / SPI0 RX | D0 |
| Pin 7 / GP5 / SPI0 CSn | D3 |
| Pin 9 / GP6 | CD |
| GND | Shield / Mounting Hole *(jumpered to GD on BRK-SD v2.0)* |

#### Programming notes (From AI, unverified)

* **GPIO Multiplexing (Manual `CS` Control):** Set `GP2` (`SCK`), `GP3` (`TX`/MOSI), and `GP4` (`RX`/MISO) `FUNCSEL` to `SPI` (Function 1) in `IO_BANK0`. **Configure `GP5` (`CSn`) as a software-controlled GPIO (`SIO`, Function 5) rather than hardware `SPI0 CSn`:** the RP2350's PL022 SPI controller automatically pulses hardware `CSn` high between every 8-bit byte in Motorola SPI mode, which breaks multi-byte SD card commands and 512-byte block transfers, and prevents sending the mandatory initial dummy clocks with `CS` held high.
* **Pull-ups & Card Detect (`GP6`):** Clear `ISO` on `GP2–GP6` in `PADS_BANK0`. Enable input (`IE`) and the internal pull-up (`PUE`) on `GP4` (`D0`/MISO) so the line does not float while the SD card's output stage is tri-stated prior to entering SPI mode. On the Saiko Systems **BRK-SD v2.0** breakout, the `CD` switch closes to the connector shield (accessible via the plated mounting holes, which are not internally tied to `GD`), so jumper a mounting hole to `GD` (`GND`) and configure `GP6` (`CD`) as an `SIO` input with an internal **pull-up (`PUE = 1, PDE = 0`)**—active-LOW (`0` when a card is seated, `1` when empty), which also avoids `RP2350-E9` pull-down latching. Allow a brief settle delay (~100 µs) after enabling `PUE` before sampling `GP6` at boot.
* **SPI0 Frame Format:** Deassert `SPI0` in `RESETS`. Configure the PL022 registers (`SSPCR0`, `SSPCR1`) for Motorola SPI format (`FRF = 0`), SPI Mode 0 (`SPO = 0`, `SPH = 0`: clock idles low, data sampled on rising edge), 8-bit frame width (`DSS = 0b0111`), and master mode (`MS = 0`).
* **Two-Speed Clocking & Initialization Sequence:** SD specifications require the SPI clock (`SSPCLKOUT`, set via `SSPCPSR` and `SSPCR0.SCR`) to stay between **100 kHz and 400 kHz** during initialization. Software must:
  1. Hold `GP5` (`CS`) high and transmit at least 74 clock pulses (send 10+ bytes of `0xFF`) while keeping `MOSI` high.
  2. Drive `GP5` (`CS`) low and send `CMD0` (`0x40 00 00 00 00 95`) to enter SPI idle state (`R1 = 0x01`).
  3. Send `CMD8` (`0x48 00 00 01 AA 87`) to verify SD v2.0 voltage range, then poll `CMD55` + `ACMD41` (with `HCS` bit 30 set) until the card exits idle (`R1 = 0x00`).
  4. Send `CMD58` to read the OCR register and inspect the Card Capacity Status (`CCS`) bit: SDHC/SDXC cards (`CCS = 1`) use 512-byte **LBA block addresses** in `CMD17`/`CMD24`, whereas standard-capacity cards (`CCS = 0`) use byte addresses.
  5. Once initialized, reprogram the `SPI0` clock prescaler for high-speed block transfers (e.g., 12–25 MHz).

### Serial Debugging: Adafruit CP2102N

This is accessed via UART, and uses the following connections:

| Pico  | CP2102N |
| ------------- | ------------- |
| GND | GND |
| Pin 1 / GP0 / UART0 TX | RXD |
| Pin 2 / GP1 / UART0 RX | TXD |

#### Programming notes (From AI, unverified)

* **GPIO & Pad Configuration:** Set `GP0` and `GP1` `FUNCSEL` to `UART` (Function 2) in `IO_BANK0`. Clear `ISO` on both pads in `PADS_BANK0`, and enable input (`IE`) and the internal pull-up (`PUE`) on `GP1` (`UART0 RX`).
* **UART0 Setup:** Deassert `UART0` in `RESETS`. Configure `UARTIBRD` and `UARTFBRD` from `CLK_PERI` for your host terminal baud rate (typically `115200`), set `UARTLCR_H` for `8N1` with hardware FIFOs enabled (`FEN = 1`, `WLEN = 0b11`), leave hardware flow control (`CTSEN`/`RTSEN`) disabled since `CTS`/`RTS` are not wired, and set `UARTEN`, `TXE`, and `RXE` in `UARTCR`.
* **Polled I/O:** For minimal bare-metal logging and monitor commands without interrupts, poll the Flag Register (`UARTFR`): wait while `TXFF` (Transmit FIFO Full, bit 5) is `1` before writing an outgoing character to `UARTDR`, and wait while `RXFE` (Receive FIFO Empty, bit 4) is `1` before reading an incoming character from `UARTDR`.

### Audio: Piezo Buzzer

This is driven by one of the Pico's PWMs, and uses the following connections:

| Pico  | Piezo |
| ------------- | ------------- |
| GND | - |
| Pin 29 / GP22 / PWM3 A | + |

#### Programming notes (From AI, unverified)

* **GPIO & Slice Mapping:** Set `GP22` `FUNCSEL` to `PWM` (Function 4) in `IO_BANK0` and clear `ISO` in `PADS_BANK0`. On the RP2350, `GP22` routes to **PWM Slice 3, Channel A** (`PWM3 A`).
* **Frequency Generation:** Deassert `PWM` in `RESETS`. Ensure phase-correct mode (`CSR.PH_CORRECT`) is `0` and clock mode (`CSR.DIVMODE`) is free-running (`0`). Program Slice 3's 8.4 fixed-point clock divider (`CH3_DIV`) and 16-bit wrap value (`CH3_TOP`) to produce the desired note frequency:
  $$f_{\text{tone}} = \frac{f_{\text{clk\_sys}}}{\text{DIV} \times (\text{TOP} + 1)}$$
* **Duty Cycle & Silencing:** Because a passive piezo element responds to voltage transitions rather than steady DC, set the Channel A compare field (`CH3_CC` bits `15:0`) to `(TOP + 1) / 2` (50% duty cycle) for maximum volume and enable the slice (`CH3_CSR.EN = 1`). To silence the buzzer between notes, set the `CH3_CC` compare value to `0` so the output pin is driven continuously low (`0V`), preventing idle current draw.

### Status: LEDs

These provide simple feedback for debugging. Each LED must have an appropriate current-limiting resistor (220Ω to 1kΩ) inline with its + or - side.

The red LED uses the following connections:

| Pico  | Red LED |
| ------------- | ------------- |
| GND | - |
| Pin 31 / GP26 A0 | + |

The green LED uses the following connections:

| Pico  | Green LED |
| ------------- | ------------- |
| GND | - |
| Pin 32 / GP27 A1 | + |

The blue LED uses the following connections:

| Pico  | Blue LED |
| ------------- | ------------- |
| GND | - |
| Pin 34 / GP28 A2 | + |

#### Programming notes (From AI, unverified)

* **GPIO & ADC-Pad Configuration:** Set `GP26`, `GP27`, and `GP28` `FUNCSEL` to `SIO` (Function 5, single-cycle software GPIO) in `IO_BANK0`. Because these three pins share pads with analog inputs `ADC0–ADC2`, configure `PADS_BANK0` for `GP26–GP28` by clearing `ISO` (`0`), ensuring output disable (`OD`) is `0`, and setting drive strength (e.g., 4 mA).
* **Atomic `SIO` Register Access:** Enable outputs for bits 26, 27, and 28 by writing `(1 << 26) | (1 << 27) | (1 << 28)` to the single-cycle `SIO` `GPIO_OE_SET` register. Turn individual LEDs on, off, or toggle them using the atomic `GPIO_OUT_SET`, `GPIO_OUT_CLR`, and `GPIO_OUT_XOR` registers rather than read-modify-writing `GPIO_OUT`, allowing both main code and interrupt handlers (such as fault or timer ISRs) to update LEDs safely without race conditions.

### Reset: Momentary Button

When pressed, thus pull the Pico's RUN line low which triggers a reset.

It uses the following connections:

| Pico  | Reset Button |
| ------------- | ------------- |
| GND | - |
| Pin 30 / RUN | + |

#### Programming notes (From AI, unverified)

* **Hardware Reset Line:** The `RUN` pin is a dedicated hardware reset input with an onboard pull-up resistor on the Pico 2; it requires no GPIO multiplexing or software initialization to function.
* **Reset Cause & Persistent State:** If bare-metal startup code needs to distinguish a cold power-on from a button reset, it can inspect the `CHIP_RESET` register in the `POWMAN` (Power Manager) block (`HAD_POR` vs. `HAD_RUN_LOW`). SRAM contents and `POWMAN` scratch registers survive a `RUN` pin reset, which is useful for preserving post-mortem crash state or warm-boot flags. Holding the Pico's onboard `BOOTSEL` button while pressing and releasing the reset button forces the Boot ROM into USB Mass Storage (`UF2`) flashing mode.
