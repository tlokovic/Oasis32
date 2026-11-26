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
 * 0x20-0x2F: Video / VSYNC Services (Core 1 Video Coprocessor)
 * ----------------------------------------------------------------------------
 *   BIOS_VIDEO_FRAME_COUNT () -> a0 = uint32_t monotonic VSYNC frame counter
 *   BIOS_VIDEO_WAIT_VSYNC  () -> a0 = uint32_t new VSYNC frame counter [blocking]
 *   BIOS_VIDEO_RESET_FONT  () -> a0 = ERR_OK (0) (reloads default CP437 8x8 font)
 */
#define BIOS_VIDEO_FRAME_COUNT      0x20
#define BIOS_VIDEO_WAIT_VSYNC       0x21
#define BIOS_VIDEO_RESET_FONT       0x22

/* ----------------------------------------------------------------------------
 * 0x30-0x3F: Input Services — Keyboard & Mouse
 * ----------------------------------------------------------------------------
 * Keyboard:
 *   BIOS_KEYBOARD_READ         ()           -> a0 = key_event [blocking]
 *   BIOS_KEYBOARD_TRY_READ     ()           -> a0 = key_event or ERR_EMPTY (-3)
 *   BIOS_KEYBOARD_FLUSH        ()           -> a0 = ERR_OK (0)
 *   BIOS_KEYBOARD_STATE        (a0=dst_ptr) -> a0 = count (0..6) or ERR_INVALID_ARG,
 *                                              a1 = modifiers (KEY_MOD_* mask)
 *     Writes count active keycodes to dst_ptr[0..count-1], zero-padded to 8 B.
 *
 * Mouse (screen-space 0..639 x 0..479, boot default 320x240):
 *   BIOS_MOUSE_POS_READ        ()           -> a0 = 0, a1 = x, a2 = y,
 *                                              a3 = dx, a4 = dy, a5 = dwheel [blocking]
 *   BIOS_MOUSE_POS_TRY_READ    ()           -> same, or a0 = ERR_EMPTY (-3)
 *   BIOS_MOUSE_POS_FLUSH       ()           -> a0 = ERR_OK (0)
 *   BIOS_MOUSE_BUTTON_READ     ()           -> a0 = btn_event, a1 = x, a2 = y [blocking]
 *   BIOS_MOUSE_BUTTON_TRY_READ ()           -> same, or a0 = ERR_EMPTY (-3)
 *   BIOS_MOUSE_BUTTON_FLUSH    ()           -> a0 = ERR_OK (0)
 *   BIOS_MOUSE_STATE           ()           -> a0 = buttons, a1 = x, a2 = y
 *   BIOS_MOUSE_SET_POS         (a0=x, a1=y) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 */
#define BIOS_KEYBOARD_READ          0x30
#define BIOS_KEYBOARD_TRY_READ      0x31
#define BIOS_KEYBOARD_FLUSH         0x32
#define BIOS_KEYBOARD_STATE         0x33

#define BIOS_MOUSE_POS_READ         0x38
#define BIOS_MOUSE_POS_TRY_READ     0x39
#define BIOS_MOUSE_POS_FLUSH        0x3A
#define BIOS_MOUSE_BUTTON_READ      0x3B
#define BIOS_MOUSE_BUTTON_TRY_READ  0x3C
#define BIOS_MOUSE_BUTTON_FLUSH     0x3D
#define BIOS_MOUSE_STATE            0x3E
#define BIOS_MOUSE_SET_POS          0x3F

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
 * 0x60-0x6F: Audio Services — Piezo Buzzer
 * ----------------------------------------------------------------------------
 *   BIOS_AUDIO_TONE       (a0=freq_hz) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 *     freq_hz = 0 silences the buzzer; 16..20000 Hz plays a 50% square wave.
 */
#define BIOS_AUDIO_TONE             0x60

/* ----------------------------------------------------------------------------
 * 0x70-0x7F: Status LED Services (LED_RED=0, LED_GREEN=1, LED_BLUE=2)
 * ----------------------------------------------------------------------------
 *   BIOS_LED_WRITE        (a0=idx, a1=state) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 *   BIOS_LED_READ         (a0=idx)           -> a0 = 0|1        or ERR_INVALID_ARG (-2)
 */
#define BIOS_LED_WRITE              0x70
#define BIOS_LED_READ               0x71

#endif /* OASIS32_ABI_BIOS_ABI_H */
