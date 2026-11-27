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
#define BIOS_BLK_TEXT               0x80

/* ----------------------------------------------------------------------------
 * 0x00-0x0F: System Control Services
 * ----------------------------------------------------------------------------
 *   BIOS_SYS_VERSION              ()           -> a0 = (maj<<16)|(min<<8)|pat
 *   BIOS_SYS_REBOOT               ()           -> does not return (full reset)
 *   BIOS_SYS_SET_OS_ECALL_HANDLER (a0=fn_ptr)  -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 *     Registers (or clears with 0) the Stage-2 OS dispatcher for a7 >= 0x0100.
 *     Non-zero fn_ptr must be 2-byte aligned inside User SRAM.
 */
#define BIOS_SYS_VERSION                0x00
#define BIOS_SYS_REBOOT                 0x01
#define BIOS_SYS_SET_OS_ECALL_HANDLER   0x02

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
 * 0x40-0x4F: Storage Services — SD Card Block I/O (512-byte LBA sectors)
 * ----------------------------------------------------------------------------
 *   BIOS_SD_STATUS   ()                   -> a0 = SD_STATUS_* bitmask (>= 0)
 *   BIOS_SD_INIT     ()                   -> a0 = ERR_OK, ERR_NO_DEVICE, or ERR_IO
 *   BIOS_SD_READ     (a0=lba, a1=buf_ptr) -> a0 = ERR_OK, ERR_NO_DEVICE, ERR_INVALID_ARG, or ERR_IO
 *   BIOS_SD_WRITE    (a0=lba, a1=buf_ptr) -> a0 = ERR_OK, ERR_NO_DEVICE, ERR_INVALID_ARG, or ERR_IO
 *   BIOS_SD_CAPACITY ()                   -> a0 = ERR_OK or ERR_NO_DEVICE, a1 = total 512-byte sectors
 */
#define BIOS_SD_STATUS                  0x40
#define BIOS_SD_INIT                    0x41
#define BIOS_SD_READ                    0x42
#define BIOS_SD_WRITE                   0x43
#define BIOS_SD_CAPACITY                0x44

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

/* ----------------------------------------------------------------------------
 * 0x80-0x8F: Text Console Services (80x60 TEXT_BUF + Hardware Blinking Cursor)
 * ----------------------------------------------------------------------------
 *   BIOS_TEXT_CLEAR            ()                  -> a0 = ERR_OK (0)
 *     Zero-fills TEXT_BUF (0x00) and resets cursor to (0, 0).
 *   BIOS_TEXT_PUTC             (a0=ch)             -> a0 = ERR_OK (0)
 *     Writes character at cursor, advancing/wrapping and auto-scrolling up
 *     past row 59. Control chars: '\n' (Unix newline: col=0, row++),
 *     '\r' (col=0), '\b' (left).
 *   BIOS_TEXT_PUTS             (a0=cstr_ptr)       -> a0 = ERR_OK or ERR_INVALID_ARG
 *     Prints NUL-terminated string via PUTC semantics (cstr_ptr in User SRAM).
 *   BIOS_TEXT_SET_CURSOR_POS   (a0=col, a1=row)    -> a0 = ERR_OK or ERR_INVALID_ARG
 *     Sets cursor position (col in 0..79, row in 0..59).
 *   BIOS_TEXT_GET_CURSOR_POS   ()                  -> a0 = col (0..79), a1 = row (0..59)
 *   BIOS_TEXT_SET_CURSOR_STATE (a0=vis, a1=frames) -> a0 = ERR_OK or ERR_INVALID_ARG
 *     vis: 0 = hidden, nonzero = visible (inverts glyph cell non-destructively).
 *     frames: blink half-period in 60 Hz frames (0 = solid, 1..255 = blink;
 *             e.g. 30 = 0.5 s on / 0.5 s off).
 *   BIOS_TEXT_SCROLL_UP        (a0=lines)          -> a0 = ERR_OK (0)
 *     Scrolls TEXT_BUF up by `lines` rows, filling bottom rows with 0x00.
 *   BIOS_TEXT_SCROLL_DOWN      (a0=lines)          -> a0 = ERR_OK (0)
 *     Scrolls TEXT_BUF down by `lines` rows, filling top rows with 0x00.
 */
#define BIOS_TEXT_CLEAR             0x80
#define BIOS_TEXT_PUTC              0x81
#define BIOS_TEXT_PUTS              0x82
#define BIOS_TEXT_SET_CURSOR_POS    0x83
#define BIOS_TEXT_GET_CURSOR_POS    0x84
#define BIOS_TEXT_SET_CURSOR_STATE  0x85
#define BIOS_TEXT_SCROLL_UP         0x86
#define BIOS_TEXT_SCROLL_DOWN       0x87

#endif /* OASIS32_ABI_BIOS_ABI_H */
