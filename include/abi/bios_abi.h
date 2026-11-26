/*
 * ============================================================================
 * Oasis32 Public ABI — Resident BIOS ecall Service IDs & Error Codes
 * ============================================================================
 * Calling Convention (RISC-V ILP32):
 *   - Invoke via `ecall`
 *   - a7 (x17)      : Service ID (0x0000-0x00FF = BIOS, 0x0100+ = OS extension)
 *   - a0-a5 (x10-15): Arguments (up to 6 word-sized inputs)
 *   - a0 (x10)      : Return value (>= 0 on success, < 0 on error)
 *   - Preserved     : s0-s11, sp, gp, tp, ra
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Reference: docs/ExecutionModel.md §5
 * ============================================================================
 */

#ifndef OASIS32_ABI_BIOS_ABI_H
#define OASIS32_ABI_BIOS_ABI_H

/* ----------------------------------------------------------------------------
 * Service ID Partitions
 * ---------------------------------------------------------------------------- */
#define BIOS_SVC_MIN                0x0000
#define BIOS_SVC_MAX                0x00FF
#define OS_SVC_BASE                 0x0100

/* ----------------------------------------------------------------------------
 * Standardized Signed Error Codes (returned in a0 when a0 < 0)
 * ---------------------------------------------------------------------------- */
#define ERR_OK                      0
#define ERR_UNSUPPORTED             (-1)
#define ERR_INVALID_ARG             (-2)
#define ERR_EMPTY                   (-3)
#define ERR_BUSY                    (-4)
#define ERR_IO                      (-5)
#define ERR_NO_DEVICE               (-6)

/* ----------------------------------------------------------------------------
 * Subsystem Service ID Blocks (16 IDs per subsystem, high nibble = subsystem)
 * ---------------------------------------------------------------------------- */
#define BIOS_BLK_SYS                0x00
#define BIOS_BLK_SERIAL             0x10
#define BIOS_BLK_VIDEO              0x20
#define BIOS_BLK_INPUT              0x30
#define BIOS_BLK_SD                 0x40
#define BIOS_BLK_TIME               0x50
#define BIOS_BLK_AUDIO              0x60
#define BIOS_BLK_LED                0x70

/* ----------------------------------------------------------------------------
 * 0x00-0x0F: System Services (placeholder — to be designed incrementally)
 * ----------------------------------------------------------------------------
 * Planned: SYS_VERSION, SYS_REBOOT, SYS_SET_OS_ECALL_HANDLER
 */

/* ----------------------------------------------------------------------------
 * 0x10-0x1F: Serial Console Services (UART0, fixed 115200 8N1)
 * ----------------------------------------------------------------------------
 *   BIOS_SERIAL_READ      ()         -> a0 = byte (0..255) [blocking]
 *   BIOS_SERIAL_TRY_READ  ()         -> a0 = byte (0..255) or ERR_EMPTY (-3)
 *   BIOS_SERIAL_WRITE     (a0=byte)  -> a0 = ERR_OK (0)    [blocking]
 *   BIOS_SERIAL_TRY_WRITE (a0=byte)  -> a0 = ERR_OK (0)    or ERR_BUSY (-4)
 */
#define BIOS_SERIAL_READ            0x10
#define BIOS_SERIAL_TRY_READ        0x11
#define BIOS_SERIAL_WRITE           0x12
#define BIOS_SERIAL_TRY_WRITE       0x13

/* ----------------------------------------------------------------------------
 * 0x20-0x2F: Video / VSYNC Services (placeholder)
 * ---------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
 * 0x30-0x3F: Input Services — Keyboard & Mouse (placeholder)
 * ---------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
 * 0x40-0x4F: Storage Services — SD Card Block I/O (placeholder)
 * ---------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
 * 0x50-0x5F: Timer Services (1 MHz / 1 us monotonic clock)
 * ----------------------------------------------------------------------------
 *   BIOS_TIME_US          ()         -> a0 = us_lo, a1 = us_hi (64-bit)
 */
#define BIOS_TIME_US                0x50

/* ----------------------------------------------------------------------------
 * 0x60-0x6F: Audio Services — Piezo Buzzer (placeholder)
 * ---------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
 * 0x70-0x7F: Status LED Services (LED_RED=0, LED_GREEN=1, LED_BLUE=2)
 * ----------------------------------------------------------------------------
 *   BIOS_LED_WRITE        (a0=idx, a1=state) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 *   BIOS_LED_READ         (a0=idx)           -> a0 = 0|1        or ERR_INVALID_ARG (-2)
 */
#define BIOS_LED_WRITE              0x70
#define BIOS_LED_READ               0x71

#endif /* OASIS32_ABI_BIOS_ABI_H */
