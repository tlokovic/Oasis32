# Oasis32 — Execution, Concurrency & ABI Model

## 1. Philosophy: A "Big 6502" on Modern RISC-V

**Oasis32** combines the direct, transparent runtime model of classic 8-bit microcomputers with clean, idiomatic RISC-V architecture:

* **Single-Core, Single-Threaded Foreground:** All foreground execution runs on **Core 0** (Hazard3 RISC-V). Core 1 remains parked in reset/sleep.
* **Interrupt-Driven Concurrency:** All concurrency is driven by hardware interrupts (plus autonomous DMA for DVI scanline streaming)—there is no preemptive multithreading, virtual memory, or address remapping in the System ROM.
* **Unified Machine Mode (M-Mode):** Both the Flash-resident **Stage-1 System ROM (BIOS)** and SRAM-loaded **Stage-2 payloads** (demos, utilities, or an OS) execute in RISC-V **Machine Mode** (`hazard3-manual.pdf §3.1, p. 24`; `riscv-privileged.pdf §2.2, p. 15`). Memory and hardware isolation are enforced by **architectural convention** (documented in `docs/ProgrammersReference.md`) rather than MMU or PMP hardware traps.

---

## 2. Privilege Mode & Honor-System Boundaries

Because Stage-2 software executes in M-mode with the same hardware privilege as the BIOS, programs are trusted to respect the Oasis32 machine contract:

* **What Stage-2 Software Should Do:**
  * Execute standard unprivileged RISC-V instructions (`RV32IMAC_Zifencei`, `riscv-unprivileged.pdf`) within User SRAM (`USER_RAM_BASE`–`USER_RAM_END`) and render directly to the shared `640×480` 1 bpp framebuffer.
  * Interact with all machine peripherals exclusively through the resident BIOS `ecall` ABI.
* **What Stage-2 Software Must Not Do:**
  * Modify privileged CSRs (`mtvec`, `mstatus`, `mie`, `mscratch`, or Hazard3 `Xh3irq` CSRs `0xBE0`–`0xBE5`).
  * Disable global interrupts (`mstatus.MIE`), which would starve the real-time DVI scanline DMA interrupt.
  * Overwrite BIOS-reserved SRAM (driver state, DMA descriptors, or the BIOS IRQ stack) or access raw RP2350 MMIO registers directly.

> [!NOTE]
> **Future-Proof Upgrade Path:** Because Stage-2 software invokes BIOS services strictly via `ecall` and never embeds RP2350 Flash or MMIO addresses, Oasis32 retains a zero-ABI-break path to run user code in RISC-V **User Mode (U-mode)** with **Physical Memory Protection (PMP)** (`riscv-privileged.pdf §3.7, p. 74`) in the future if hardware-enforced isolation is ever desired. *(Note: enabling PMP on RP2350 A2 silicon requires accounting for `RP2350-E6`, which swaps the `R` and `X` permission bits in `pmpcfg`—`rp2350-datasheet.pdf Appendix D, p. 1357`.)*

---

## 3. Trap Vector Architecture (`mtvec` Vectored Mode)

The System ROM exclusively owns the Machine Trap-Vector Base-Address Register (`mtvec`) and configures it in **Vectored Mode (`MODE = 1`)** (`riscv-privileged.pdf §3.1.7, p. 45`). In Vectored Mode, hardware automatically routes synchronous exceptions and external interrupts to separate entry points with zero software branching on the hot IRQ path:

```text
mtvec (MODE = 1, Vectored)
  │
  ├── BASE + 0x00  (Synchronous Exceptions)
  │     ├── mcause == 11 (M-mode ecall) ──▶ Resident BIOS ABI Dispatcher
  │     │     • Runs on caller's stack (caller explicitly invoked ecall)
  │     │     • Saves mepc, mstatus, and working registers; advances mepc += 4
  │     │     • Re-enables mstatus.MIE so DVI IRQs stay live during slow BIOS calls
  │     │     • Bounds-checks service ID (a7) -> dispatches BIOS service
  │     │     • Restores context -> mret
  │     │
  │     └── Other mcause (faults) ────────▶ BIOS Fault Handler
  │           • Reports diagnostic info (mcause, mepc, mtval) over UART0 / reboot
  │
  └── BASE + 0x2C  (Cause 11: Machine External Interrupt / Xh3irq)
        └── Hardware IRQ Dispatcher (DVI HSTX DMA, etc.)
              • Swaps sp <-> mscratch (switches to private BIOS IRQ stack)
              • Runs with mstatus.MIE = 0 (non-nested, deterministic latency)
              • Services RP2350 Xh3irq peripheral (including APB write-flush reads)
              • Restores all touched GPRs -> swaps sp <-> mscratch -> mret
```

---

## 4. Hardware Interrupt Ownership & Stack Isolation

### 4.1 Why the BIOS Owns All Interrupts
* **Real-Time DVI Video:** The `640×480 @ 60 Hz` HSTX DVI output relies on a continuous DMA scanline interrupt firing every ~31.7 µs. Keeping `mtvec` under BIOS control guarantees uninterrupted display sync regardless of what Stage-2 software is doing.
* **Hardware Abstraction:** RP2350 routes 52 system IRQs through Hazard3's custom `Xh3irq` controller (`meie`, `meip`, `meicontext`, `meiprio`; `hazard3-manual.pdf §4.1, pp. 38–43`) and requires a dummy peripheral read before exiting APB ISRs to flush the 2-cycle AHB-to-APB write buffer (`rp2350-datasheet.pdf §2.1.2, p. 28`). Owning interrupts in the BIOS keeps these silicon details completely hidden from Oasis32 software.

### 4.2 Private BIOS IRQ Stack (`mscratch`) & User-Code Transparency
Stage-2 code does **not** need any special interrupt-safety boilerplate—it simply runs as normal RISC-V code:

1. **Full Register Preservation:** BIOS ISRs save and restore every general-purpose register they touch before executing `mret`. An interrupt may occur between any two user instructions and return with every user register (`x1–x31`) and PC bit-for-bit intact.
2. **Isolated IRQ Stack via `mscratch`:** The BIOS permanently stores the top of its dedicated IRQ stack in `mscratch` (`riscv-privileged.pdf §3.1.10, p. 52`), backed by non-striped Scratchpad SRAM (`0x2008_0000`–`0x2008_1FFF`, `rp2350-datasheet.pdf §4.2, p. 312`). On IRQ entry, the handler executes `csrrw sp, mscratch, sp` to switch onto its private stack, and swaps back before `mret`. Because hardware interrupts never touch the user's `sp`, user code never has to reserve extra stack headroom for BIOS ISRs.

### 4.3 Event Delivery to User Code
* **Phase 3 (Primary Model — BIOS-Buffered Polling):** BIOS ISRs service real-time hardware (DVI DMA scanlines, VSYNC frame counter, and any interrupt-buffered I/O), while user software polls events cleanly through BIOS `ecall` services (e.g., `WAIT_VSYNC`, `KEY_POLL`, `MOUSE_POLL`, `TIME_US`, `SERIAL_GETC`).
* **Phase 4+ (Optional Extension — BIOS-Managed Hooks):** If future OS or game software needs asynchronous notification (such as a VSYNC or timer tick callback), the BIOS can expose registration calls (e.g., `SET_VSYNC_HOOK`) where the BIOS retains ownership of `mtvec`, services hardware first, and invokes the registered user callback safely.

---

## 5. Resident BIOS Calling Convention (`ecall` ROM ABI)

Stage-2 payloads invoke resident BIOS services using the standard RISC-V `ecall` instruction (`riscv-unprivileged.pdf §2.8, p. 25`), following the `ILP32` register convention:

| Register(s) | Role in BIOS `ecall` | Preservation |
|:---|:---|:---|
| `a7` (`x17`) | **Service ID** (selects BIOS function) | Preserved or clobbered per ABI spec (caller-loaded before `ecall`) |
| `a0–a5` (`x10–x15`) | **Arguments** (up to 6 word-sized inputs) | `a0` (and optionally `a1`) hold return value / error code |
| `s0–s11`, `sp`, `gp`, `tp`, `ra` | Callee-saved & link registers | **Preserved** across `ecall` |

### Key Architectural Properties
* **100% Flash-Address Independent:** Payloads never hardcode a Flash address (`0x1000_xxxx`). The BIOS can be rebuilt, resized, or reorganized in XIP Flash without breaking any existing SD boot disk.
* **Safe Service Dispatch:** The dispatcher bounds-checks `a7` against the service table and returns a standardized error code (e.g., `ERR_UNSUPPORTED`) for unknown or unimplemented service IDs.
* **Preemptible BIOS Calls Without Stack Contention:**
  * On `ecall` entry (`mcause = 11`, `riscv-privileged.pdf §3.1.12, p. 53`), hardware clears `mstatus.MIE` and records the `ecall` PC in `mepc` (`§3.1.11, p. 52`).
  * Because the caller explicitly invoked `ecall` like a function call, its `sp` is valid. The dispatcher saves `mepc`, `mstatus`, and working registers on the caller's stack, advances `mepc += 4` (past the 4-byte `ecall` instruction), and **re-enables `mstatus.MIE`** (`§3.1.6, p. 38`) before calling the BIOS service implementation.
  * Because `mscratch` is reserved exclusively for hardware IRQs, if a DVI HSTX DMA interrupt fires *in the middle of a slow BIOS call* (such as an SD card block read or write), the IRQ handler cleanly swaps onto the private `mscratch` IRQ stack, services the scanline with `MIE = 0`, and returns directly back into the in-progress BIOS call—with zero nested-stack ambiguity and zero DVI flicker.
