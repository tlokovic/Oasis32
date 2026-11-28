/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Bootloader (SD Auto-Boot, SD Boot & Serial Loaders)
 * ============================================================================
 * Implements the Stage-1 boot and disk-writing workflows defined in
 * docs/BootBehavior.md §3.4–§3.5 strictly through the public BIOS ABI:
 *
 *   - boot_auto_sd()      : Post-splash automatic SD boot attempt. Returns
 *                           initial menu disk state (DISK_STATE_NONE or
 *                           DISK_STATE_INVALID) if not booted; does not return
 *                           if a valid disk boots or a fatal SD/CRC error
 *                           occurs.
 *   - boot_probe_sd()     : Initializes SD card and validates LBA 0 "OA32"
 *                           header (used by live menu polling). Returns
 *                           DISK_STATE_NONE (0), DISK_STATE_INVALID (1), or
 *                           DISK_STATE_VALID (2).
 *   - boot_from_sd()      : Boots the currently seated valid "OA32" SD card.
 *                           Does not return (jumps to entry_addr or halts on
 *                           SD/CRC error).
 *   - boot_from_serial()  : Option 1 — receives a raw .oa32 image over UART0
 *                           into User SRAM, verifies CRC-32, and jumps to
 *                           entry_addr. Returns only if cancelled via
 *                           ESC/Ctrl-C before byte 0 arrives.
 *   - boot_write_sd()     : Option 2 — receives a raw .oa32 image over UART0
 *                           into User SRAM staging buffer, validates header &
 *                           CRC-32, and writes raw sectors starting at LBA 0.
 *                           Returns on cancel or after successful write (halts
 *                           on serial/header/CRC/SD error).
 *
 * Disk State Constants (shared with main.S):
 *   0 = DISK_STATE_NONE    (no card inserted)
 *   1 = DISK_STATE_INVALID (card inserted, invalid OA32 header or unreadable)
 *   2 = DISK_STATE_VALID   (card inserted, valid OA32 header)
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/boot_header.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "abi/keycodes.h"

#define DISK_STATE_NONE             0
#define DISK_STATE_INVALID          1
#define DISK_STATE_VALID            2

/* Validation error codes returned by boot_validate_header */
#define HDR_OK                      0
#define HDR_ERR_MAGIC               1
#define HDR_ERR_SIZE                2
#define HDR_ERR_LOAD_RANGE          3
#define HDR_ERR_ENTRY_ADDR          4

/* Mid-transfer serial stall timeout (5 seconds in microseconds) */
#define SERIAL_BYTE_TIMEOUT_US      5000000

/* ASCII control characters for pre-transfer serial cancel */
#define ASCII_CTRL_C                0x03
#define ASCII_ESC                   0x1B

/* IEEE 802.3 CRC-32 reflected polynomial */
#define CRC32_POLY_REFLECTED        0xEDB88320

.section .text, "ax"

/* ============================================================================
 * Public Entry Points
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * boot_auto_sd() -> a0 = DISK_STATE_NONE (0) or DISK_STATE_INVALID (1)
 *   Called immediately after the startup splash screen.
 *   - No card present         -> returns DISK_STATE_NONE (enter menu)
 *   - Card present, valid hdr -> boots immediately (does not return)
 *   - Card present, bad hdr   -> returns DISK_STATE_INVALID (enter menu)
 *   - SD I/O or CRC-32 error  -> prints to UART0 + DVI and halts
 * ---------------------------------------------------------------------------- */
.global boot_auto_sd
.type boot_auto_sd, @function
boot_auto_sd:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    /* 1. Check SD card presence (GP6) */
    li      a7, BIOS_SD_STATUS
    ecall
    andi    t0, a0, SD_STATUS_PRESENT
    beqz    t0, auto_no_disk

    /* 2. Initialize SD card over SPI0 */
    li      a7, BIOS_SD_INIT
    ecall
    li      t0, ERR_NO_DEVICE
    beq     a0, t0, auto_no_disk
    bltz    a0, auto_sd_init_err

    /* 3. Read LBA 0 into USER_RAM_BASE */
    li      a0, 0
    li      a1, USER_RAM_BASE
    li      a7, BIOS_SD_READ
    ecall
    bltz    a0, auto_sd_read_err

    /* 4. Validate packed 32-byte "OA32" header */
    li      a0, USER_RAM_BASE
    call    boot_validate_header
    bnez    a0, auto_invalid_hdr

    /* 5. Verify image fits within reported SD capacity (if non-zero) */
    li      a0, USER_RAM_BASE
    call    boot_check_sd_capacity
    bnez    a0, auto_invalid_hdr

    /* 6. Valid OA32 disk! Immediately load remaining payload and boot */
    j       boot_sd_load_from_lba0

auto_no_disk:
    li      a0, DISK_STATE_NONE
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

auto_invalid_hdr:
    li      a0, DISK_STATE_INVALID
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

auto_sd_init_err:
    la      a0, str_err_sd_init
    j       boot_fatal_error

auto_sd_read_err:
    la      a0, str_err_sd_read
    j       boot_fatal_error
.size boot_auto_sd, . - boot_auto_sd

/* ----------------------------------------------------------------------------
 * boot_probe_sd() -> a0 = DISK_STATE_NONE / DISK_STATE_INVALID / DISK_STATE_VALID
 *   Non-fatal probe used by the interactive boot menu when a card is inserted
 *   or after Option 2 writes a new image.
 * ---------------------------------------------------------------------------- */
.global boot_probe_sd
.type boot_probe_sd, @function
boot_probe_sd:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    li      a7, BIOS_SD_STATUS
    ecall
    andi    t0, a0, SD_STATUS_PRESENT
    beqz    t0, probe_none

    li      a7, BIOS_SD_INIT
    ecall
    li      t0, ERR_NO_DEVICE
    beq     a0, t0, probe_none
    bltz    a0, probe_invalid

    li      a0, 0
    li      a1, USER_RAM_BASE
    li      a7, BIOS_SD_READ
    ecall
    bltz    a0, probe_invalid

    li      a0, USER_RAM_BASE
    call    boot_validate_header
    bnez    a0, probe_invalid

    li      a0, USER_RAM_BASE
    call    boot_check_sd_capacity
    bnez    a0, probe_invalid

    li      a0, DISK_STATE_VALID
    j       probe_ret

probe_invalid:
    li      a0, DISK_STATE_INVALID
    j       probe_ret

probe_none:
    li      a0, DISK_STATE_NONE
probe_ret:
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_probe_sd, . - boot_probe_sd

/* ----------------------------------------------------------------------------
 * boot_from_sd():
 *   Menu Option [ENTER] — Re-reads LBA 0, validates header, loads payload into
 *   User SRAM, verifies IEEE CRC-32, executes clean handoff + fence.i, and
 *   jumps to entry_addr. On any error, prints to UART0 + DVI and halts.
 * ---------------------------------------------------------------------------- */
.global boot_from_sd
.type boot_from_sd, @function
boot_from_sd:
    /* Hide cursor and show status */
    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    la      a0, str_msg_sd_boot
    call    boot_dual_puts

    /* Ensure SD card is initialized */
    li      a7, BIOS_SD_STATUS
    ecall
    andi    t0, a0, SD_STATUS_READY
    bnez    t0, 1f
    li      a7, BIOS_SD_INIT
    ecall
    bltz    a0, 2f
1:
    /* Read LBA 0 into USER_RAM_BASE */
    li      a0, 0
    li      a1, USER_RAM_BASE
    li      a7, BIOS_SD_READ
    ecall
    bltz    a0, 3f

    /* Validate header and media capacity */
    li      a0, USER_RAM_BASE
    call    boot_validate_header
    bnez    a0, 4f

    li      a0, USER_RAM_BASE
    call    boot_check_sd_capacity
    bnez    a0, 5f

    j       boot_sd_load_from_lba0

2:
    la      a0, str_err_sd_init
    j       boot_fatal_error
3:
    la      a0, str_err_sd_read
    j       boot_fatal_error
4:
    j       boot_fatal_header_err
5:
    la      a0, str_err_sd_capacity
    j       boot_fatal_error
.size boot_from_sd, . - boot_from_sd

/* ----------------------------------------------------------------------------
 * boot_sd_load_from_lba0 (internal tail-entry, LBA 0 already at USER_RAM_BASE):
 *   Copies payload bytes from LBA 0 (offset 32..511) and LBA 1..N into
 *   [load_addr, load_addr + payload_size), verifies IEEE CRC-32, and launches.
 *   Never returns.
 *
 *   Register plan:
 *     s0 = load_addr
 *     s1 = entry_addr
 *     s2 = payload_size
 *     s3 = expected_crc32
 *     s4 = remaining bytes to copy
 *     s5 = current destination pointer
 *     s6 = next LBA to read
 * ---------------------------------------------------------------------------- */
.type boot_sd_load_from_lba0, @function
boot_sd_load_from_lba0:
    /* Snapshot validated header fields into saved registers before moving data */
    li      t0, USER_RAM_BASE
    lw      s0, BOOT_HEADER_OFF_LOAD_ADDR(t0)
    lw      s1, BOOT_HEADER_OFF_ENTRY_ADDR(t0)
    lw      s2, BOOT_HEADER_OFF_PAYLOAD_SZ(t0)
    lw      s3, BOOT_HEADER_OFF_CRC32(t0)

    /* Copy first min(480, payload_size) bytes from USER_RAM_BASE+32 -> load_addr */
    li      t1, BOOT_HEADER_LBA0_PAYLOAD_MAX
    mv      t2, s2
    bltu    t2, t1, 1f
    mv      t2, t1                      /* t2 = lba0_copy_len */
1:
    li      a0, USER_RAM_BASE + BOOT_HEADER_SIZE  /* src */
    mv      a1, s0                                /* dst */
    mv      a2, t2                                /* len */
    call    boot_memmove

    sub     s4, s2, t2                  /* s4 = remaining payload bytes */
    add     s5, s0, t2                  /* s5 = next dst pointer */
    li      s6, 1                       /* s6 = next LBA */

sd_load_loop:
    beqz    s4, sd_load_verify

    /* If [s5, s5 + 512) fits within User SRAM, read directly into s5 */
    li      t0, USER_STACK_TOP - SD_SECTOR_SIZE
    bgtu    s5, t0, sd_load_partial_tail

    mv      a0, s6
    mv      a1, s5
    li      a7, BIOS_SD_READ
    ecall
    bltz    a0, sd_load_read_err

    li      t0, SD_SECTOR_SIZE
    bltu    s4, t0, sd_load_done_last
    sub     s4, s4, t0
    add     s5, s5, t0
    addi    s6, s6, 1
    j       sd_load_loop

sd_load_done_last:
    li      s4, 0
    j       sd_load_verify

    /* Edge case: final partial sector sits in the top 511 bytes of User SRAM
     * (s5 + 512 > USER_STACK_TOP). Stage via USER_RAM_BASE, preserving its
     * contents on the Bank 8 BIOS stack if load_addr overlaps USER_RAM_BASE. */
sd_load_partial_tail:
    li      t0, USER_RAM_BASE + SD_SECTOR_SIZE
    bgeu    s0, t0, sd_load_tail_no_save

    /* Save 512 bytes of USER_RAM_BASE on Bank 8 BIOS stack */
    addi    sp, sp, -SD_SECTOR_SIZE
    li      a0, USER_RAM_BASE
    mv      a1, sp
    li      a2, SD_SECTOR_SIZE
    call    boot_memmove

    mv      a0, s6
    li      a1, USER_RAM_BASE
    li      a7, BIOS_SD_READ
    ecall
    bltz    a0, sd_load_read_err

    li      a0, USER_RAM_BASE
    mv      a1, s5
    mv      a2, s4
    call    boot_memmove

    /* Restore 512 bytes back to USER_RAM_BASE */
    mv      a0, sp
    li      a1, USER_RAM_BASE
    li      a2, SD_SECTOR_SIZE
    call    boot_memmove
    addi    sp, sp, SD_SECTOR_SIZE
    j       sd_load_verify

sd_load_tail_no_save:
    mv      a0, s6
    li      a1, USER_RAM_BASE
    li      a7, BIOS_SD_READ
    ecall
    bltz    a0, sd_load_read_err

    li      a0, USER_RAM_BASE
    mv      a1, s5
    mv      a2, s4
    call    boot_memmove

sd_load_verify:
    /* Verify IEEE 802.3 CRC-32 over [load_addr, load_addr + payload_size) */
    mv      a0, s0
    mv      a1, s2
    call    boot_crc32
    bne     a0, s3, sd_load_crc_err

    /* Launch payload at entry_addr (s1) */
    mv      a0, s1
    j       boot_handoff_and_jump

sd_load_read_err:
    la      a0, str_err_sd_read
    j       boot_fatal_error

sd_load_crc_err:
    mv      a1, a0                      /* a1 = computed CRC */
    mv      a0, s3                      /* a0 = expected CRC */
    j       boot_fatal_crc
.size boot_sd_load_from_lba0, . - boot_sd_load_from_lba0

/* ----------------------------------------------------------------------------
 * boot_from_serial():
 *   Menu Option [1] — Raw binary serial-to-SRAM boot over UART0.
 *   Prints exact prompt over UART0 (and status on DVI), waits for byte 0
 *   (ESC/Ctrl-C cancels and returns to menu), validates 32-byte "OA32" header,
 *   streams payload directly to load_addr, verifies CRC-32, and launches.
 * ---------------------------------------------------------------------------- */
.global boot_from_serial
.type boot_from_serial, @function
boot_from_serial:
    addi    sp, sp, -48
    sw      ra, 44(sp)
    sw      s0, 40(sp)
    sw      s1, 36(sp)
    sw      s2, 32(sp)
    /* 0(sp)..31(sp) = 32-byte header buffer on Bank 8 BIOS stack */

    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    /* Print exact UART0 prompt required by docs/BootBehavior.md §3.5 */
    la      a0, str_uart_boot_serial
    call    boot_serial_puts

    /* Mirror clear status on DVI display */
    la      a0, str_dvi_boot_serial
    call    boot_dvi_puts

    /* Drain any stale bytes from UART0 RX FIFO */
    call    boot_serial_drain_rx

    /* Wait for byte 0 (supports ESC / Ctrl-C cancel before transfer begins) */
    call    boot_serial_wait_first_byte
    bltz    a0, serial_boot_cancel
    sb      a0, 0(sp)

    /* Read remaining 31 header bytes with idle timeout */
    addi    a0, sp, 1
    li      a1, BOOT_HEADER_SIZE - 1
    call    boot_serial_read_buf
    bnez    a0, serial_boot_timeout

    /* Validate 32-byte "OA32" header */
    mv      a0, sp
    call    boot_validate_header
    bnez    a0, boot_fatal_header_err

    lw      s0, BOOT_HEADER_OFF_LOAD_ADDR(sp)
    lw      s1, BOOT_HEADER_OFF_ENTRY_ADDR(sp)
    lw      s2, BOOT_HEADER_OFF_PAYLOAD_SZ(sp)
    lw      s3, BOOT_HEADER_OFF_CRC32(sp)

    /* Stream payload_size raw bytes directly into load_addr */
    mv      a0, s0
    mv      a1, s2
    call    boot_serial_read_buf
    bnez    a0, serial_boot_timeout

    /* Verify IEEE CRC-32 */
    mv      a0, s0
    mv      a1, s2
    call    boot_crc32
    bne     a0, s3, serial_boot_crc_err

    /* Clean peripheral handoff + fence.i + jump to entry_addr */
    mv      a0, s1
    j       boot_handoff_and_jump

serial_boot_cancel:
    la      a0, str_msg_cancelled
    call    boot_serial_puts
    lw      s2, 32(sp)
    lw      s1, 36(sp)
    lw      s0, 40(sp)
    lw      ra, 44(sp)
    addi    sp, sp, 48
    ret

serial_boot_timeout:
    la      a0, str_err_serial_timeout
    j       boot_fatal_error

serial_boot_crc_err:
    mv      a1, a0
    mv      a0, s3
    j       boot_fatal_crc
.size boot_from_serial, . - boot_from_serial

/* ----------------------------------------------------------------------------
 * boot_write_sd():
 *   Menu Option [2] — Raw binary serial-to-SD writer over UART0.
 *   Buffers complete .oa32 image (header + payload) in User SRAM starting at
 *   USER_RAM_BASE, validates header & CRC-32, zero-pads final 512-byte sector,
 *   and writes sectors 0..N-1 to the SD card.
 *   Returns to menu on cancel or after successful write; halts on any error.
 * ---------------------------------------------------------------------------- */
.global boot_write_sd
.type boot_write_sd, @function
boot_write_sd:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)

    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    /* Print exact UART0 prompt required by docs/BootBehavior.md §3.5 */
    la      a0, str_uart_write_sd
    call    boot_serial_puts

    /* Mirror clear status on DVI display */
    la      a0, str_dvi_write_sd
    call    boot_dvi_puts

    /* Drain any stale UART0 RX bytes */
    call    boot_serial_drain_rx

    /* Wait for byte 0 (supports ESC / Ctrl-C cancel before transfer begins) */
    call    boot_serial_wait_first_byte
    bltz    a0, write_sd_cancel

    li      s0, USER_RAM_BASE           /* s0 = staging base (header at +0) */
    sb      a0, 0(s0)

    /* Read remaining 31 header bytes into USER_RAM_BASE + 1..31 */
    addi    a0, s0, 1
    li      a1, BOOT_HEADER_SIZE - 1
    call    boot_serial_read_buf
    bnez    a0, write_sd_timeout

    /* Validate 32-byte "OA32" header */
    mv      a0, s0
    call    boot_validate_header
    bnez    a0, boot_fatal_header_err

    lw      s1, BOOT_HEADER_OFF_PAYLOAD_SZ(s0)
    lw      s2, BOOT_HEADER_OFF_CRC32(s0)

    /* Ensure 32 + payload_size fits in User SRAM staging buffer */
    li      t0, USER_RAM_SIZE - BOOT_HEADER_SIZE
    bgtu    s1, t0, write_sd_too_large

    /* Stream payload_size raw bytes into USER_RAM_BASE + 32 */
    addi    a0, s0, BOOT_HEADER_SIZE
    mv      a1, s1
    call    boot_serial_read_buf
    bnez    a0, write_sd_timeout

    /* Verify IEEE CRC-32 over received payload before touching SD card */
    addi    a0, s0, BOOT_HEADER_SIZE
    mv      a1, s1
    call    boot_crc32
    bne     a0, s2, write_sd_crc_err

    /* Notify user that image verified and SD write is starting */
    la      a0, str_msg_sd_writing
    call    boot_dual_puts

    /* Initialize SD card (handles blank/uninitialized cards cleanly) */
    li      a7, BIOS_SD_INIT
    ecall
    bltz    a0, write_sd_init_err

    /* Check SD card capacity */
    mv      a0, s0
    call    boot_check_sd_capacity
    bnez    a0, write_sd_cap_err

    /* Compute sector_count = (32 + payload_size + 511) >> 9 */
    addi    t0, s1, BOOT_HEADER_SIZE
    addi    t1, t0, SD_SECTOR_SIZE - 1
    srli    s2, t1, 9                   /* s2 = total sectors to write */

    /* Zero-pad trailing bytes of the final 512-byte sector */
    slli    t1, s2, 9                   /* t1 = padded byte length */
    add     t2, s0, t0                  /* t2 = first pad byte */
    add     t3, s0, t1                  /* t3 = end of final sector */
1:
    bgeu    t2, t3, 2f
    sb      zero, 0(t2)
    addi    t2, t2, 1
    j       1b
2:
    /* Write sectors LBA 0 .. sector_count - 1 */
    li      s3, 0                       /* s3 = current LBA */
3:
    bgeu    s3, s2, 4f
    mv      a0, s3
    slli    t0, s3, 9
    add     a1, s0, t0
    li      a7, BIOS_SD_WRITE
    ecall
    bltz    a0, write_sd_io_err
    addi    s3, s3, 1
    j       3b
4:
    la      a0, str_msg_sd_write_ok
    call    boot_dual_puts
    j       write_sd_ret

write_sd_cancel:
    la      a0, str_msg_cancelled
    call    boot_serial_puts

write_sd_ret:
    lw      s3, 12(sp)
    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret

write_sd_timeout:
    la      a0, str_err_serial_timeout
    j       boot_fatal_error

write_sd_too_large:
    la      a0, str_err_hdr_load_range
    j       boot_fatal_error

write_sd_crc_err:
    mv      a1, a0
    mv      a0, s2
    j       boot_fatal_crc

write_sd_init_err:
    la      a0, str_err_sd_init
    j       boot_fatal_error

write_sd_cap_err:
    la      a0, str_err_sd_capacity
    j       boot_fatal_error

write_sd_io_err:
    la      a0, str_err_sd_write
    j       boot_fatal_error
.size boot_write_sd, . - boot_write_sd

/* ============================================================================
 * Internal Bootloader Helpers
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * boot_validate_header(a0 = header_ptr) -> a0 = HDR_OK (0) or HDR_ERR_*
 *   Validates magic, non-zero payload_size, User SRAM [load_addr, load_addr +
 *   payload_size) bounds without wrap-around, and 2-byte aligned entry_addr.
 * ---------------------------------------------------------------------------- */
.type boot_validate_header, @function
boot_validate_header:
    /* 1. Magic == BOOT_HEADER_MAGIC ("OA32" = 0x3233414F) */
    lw      t0, BOOT_HEADER_OFF_MAGIC(a0)
    li      t1, BOOT_HEADER_MAGIC
    bne     t0, t1, 1f

    /* 2. payload_size > 0 */
    lw      t2, BOOT_HEADER_OFF_PAYLOAD_SZ(a0)
    beqz    t2, 2f

    /* 3. load_addr in [USER_RAM_BASE, USER_STACK_TOP) and
     *    payload_size <= USER_STACK_TOP - load_addr (overflow-safe) */
    lw      t0, BOOT_HEADER_OFF_LOAD_ADDR(a0)
    li      t1, USER_RAM_BASE
    bltu    t0, t1, 3f
    li      t3, USER_STACK_TOP
    bgeu    t0, t3, 3f
    sub     t4, t3, t0                  /* t4 = max_size from load_addr */
    bgtu    t2, t4, 3f

    /* 4. entry_addr in [USER_RAM_BASE, USER_STACK_TOP) and 2-byte aligned */
    lw      t0, BOOT_HEADER_OFF_ENTRY_ADDR(a0)
    bltu    t0, t1, 4f
    bgeu    t0, t3, 4f
    andi    t4, t0, 1
    bnez    t4, 4f

    li      a0, HDR_OK
    ret
1:
    li      a0, HDR_ERR_MAGIC
    ret
2:
    li      a0, HDR_ERR_SIZE
    ret
3:
    li      a0, HDR_ERR_LOAD_RANGE
    ret
4:
    li      a0, HDR_ERR_ENTRY_ADDR
    ret
.size boot_validate_header, . - boot_validate_header

/* ----------------------------------------------------------------------------
 * boot_check_sd_capacity(a0 = header_ptr) -> a0 = 0 if OK, 1 if exceeds card
 *   Checks ceil((32 + payload_size) / 512) <= BIOS_SD_CAPACITY (when > 0).
 * ---------------------------------------------------------------------------- */
.type boot_check_sd_capacity, @function
boot_check_sd_capacity:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)

    lw      t0, BOOT_HEADER_OFF_PAYLOAD_SZ(a0)
    addi    t0, t0, BOOT_HEADER_SIZE
    addi    t0, t0, SD_SECTOR_SIZE - 1
    srli    s0, t0, 9                   /* s0 = required sectors */

    li      a7, BIOS_SD_CAPACITY
    ecall
    bltz    a0, 1f                      /* Capacity unavailable -> reject */
    beqz    a1, 2f                      /* 0 = unknown CSD -> allow */
    bgtu    s0, a1, 1f
2:
    li      a0, 0
    j       3f
1:
    li      a0, 1
3:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_check_sd_capacity, . - boot_check_sd_capacity

/* ----------------------------------------------------------------------------
 * boot_crc32(a0 = buf_ptr, a1 = byte_len) -> a0 = IEEE 802.3 CRC-32
 *   Polynomial 0xEDB88320 (reflected), init 0xFFFFFFFF, final XOR 0xFFFFFFFF.
 * ---------------------------------------------------------------------------- */
.type boot_crc32, @function
boot_crc32:
    li      t0, -1                      /* crc = 0xFFFFFFFF */
    li      t2, CRC32_POLY_REFLECTED
    beqz    a1, 3f
1:
    lbu     t1, 0(a0)
    xor     t0, t0, t1
    li      t3, 8
2:
    andi    t4, t0, 1
    srli    t0, t0, 1
    neg     t4, t4                      /* 0x00000000 or 0xFFFFFFFF */
    and     t4, t4, t2
    xor     t0, t0, t4
    addi    t3, t3, -1
    bnez    t3, 2b

    addi    a0, a0, 1
    addi    a1, a1, -1
    bnez    a1, 1b
3:
    not     a0, t0                      /* final XOR 0xFFFFFFFF */
    ret
.size boot_crc32, . - boot_crc32

/* ----------------------------------------------------------------------------
 * boot_memmove(a0 = src, a1 = dst, a2 = len)
 *   Overlap-safe byte copy.
 * ---------------------------------------------------------------------------- */
.type boot_memmove, @function
boot_memmove:
    beqz    a2, 3f
    beq     a0, a1, 3f
    bgtu    a1, a0, 2f                  /* dst > src -> copy backward */
1:
    lbu     t0, 0(a0)
    sb      t0, 0(a1)
    addi    a0, a0, 1
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, 1b
    ret
2:
    add     a0, a0, a2
    add     a1, a1, a2
4:
    addi    a0, a0, -1
    addi    a1, a1, -1
    lbu     t0, 0(a0)
    sb      t0, 0(a1)
    addi    a2, a2, -1
    bnez    a2, 4b
3:
    ret
.size boot_memmove, . - boot_memmove

/* ----------------------------------------------------------------------------
 * boot_serial_drain_rx():
 *   Discards any stale bytes sitting in the UART0 RX FIFO.
 * ---------------------------------------------------------------------------- */
.type boot_serial_drain_rx, @function
boot_serial_drain_rx:
1:
    li      a7, BIOS_SERIAL_TRY_READ
    ecall
    bgez    a0, 1b
    ret
.size boot_serial_drain_rx, . - boot_serial_drain_rx

/* ----------------------------------------------------------------------------
 * boot_serial_wait_first_byte() -> a0 = byte (0..255) or -1 if cancelled
 *   Waits indefinitely for byte 0 over UART0. Cancels if ESC (0x1B) or
 *   Ctrl-C (0x03) arrives over UART0, OR if ESC / Ctrl-C is pressed on the
 *   local USB keyboard.
 * ---------------------------------------------------------------------------- */
.type boot_serial_wait_first_byte, @function
boot_serial_wait_first_byte:
1:
    li      a7, BIOS_SERIAL_TRY_READ
    ecall
    bltz    a0, 2f

    li      t0, ASCII_ESC
    beq     a0, t0, 3f
    li      t0, ASCII_CTRL_C
    beq     a0, t0, 3f
    ret                                 /* Got valid byte 0 in a0 */

2:
    li      a7, BIOS_KEYBOARD_TRY_READ
    ecall
    bltz    a0, 1b

    /* Only act on key-down events */
    li      t0, KEY_EVENT_DOWN_BIT
    and     t0, a0, t0
    beqz    t0, 1b

    andi    t1, a0, KEY_EVENT_CODE_MASK
    li      t0, KEY_ESC
    beq     t1, t0, 3f

    li      t0, KEY_C
    bne     t1, t0, 1b
    srli    t2, a0, KEY_EVENT_MOD_SHIFT
    andi    t2, t2, (KEY_MOD_LCTRL | KEY_MOD_RCTRL)
    beqz    t2, 1b
3:
    li      a0, -1
    ret
.size boot_serial_wait_first_byte, . - boot_serial_wait_first_byte

/* ----------------------------------------------------------------------------
 * boot_serial_read_buf(a0 = dst_ptr, a1 = count) -> a0 = 0 on OK, -1 on timeout
 *   Reads `count` bytes from UART0 with SERIAL_BYTE_TIMEOUT_US per-byte idle
 *   timeout.
 * ---------------------------------------------------------------------------- */
.type boot_serial_read_buf, @function
boot_serial_read_buf:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)

    mv      s0, a0                      /* dst */
    mv      s1, a1                      /* remaining */
    li      s3, SERIAL_BYTE_TIMEOUT_US

1:
    beqz    s1, 4f
    li      a7, BIOS_TIME_US
    ecall
    mv      s2, a0                      /* s2 = byte wait start_us */
2:
    li      a7, BIOS_SERIAL_TRY_READ
    ecall
    bgez    a0, 3f

    li      a7, BIOS_TIME_US
    ecall
    sub     t0, a0, s2
    bltu    t0, s3, 2b

    li      a0, -1                      /* Timed out */
    j       5f
3:
    sb      a0, 0(s0)
    addi    s0, s0, 1
    addi    s1, s1, -1
    j       1b
4:
    li      a0, 0
5:
    lw      s3, 12(sp)
    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size boot_serial_read_buf, . - boot_serial_read_buf

/* ----------------------------------------------------------------------------
 * boot_handoff_and_jump(a0 = entry_addr):
 *   Performs the clean peripheral handoff guaranteed by ProgrammersReference
 *   §3.3, executes fence.i, initializes sp = USER_STACK_TOP, and jumps to
 *   entry_addr. Never returns.
 * ---------------------------------------------------------------------------- */
.type boot_handoff_and_jump, @function
boot_handoff_and_jump:
    mv      s0, a0                      /* s0 = entry_addr */

    /* 1. Silence piezo buzzer and turn off all 3 status LEDs */
    li      a0, AUDIO_FREQ_OFF
    li      a7, BIOS_AUDIO_TONE
    ecall

    li      a0, LED_RED
    li      a1, 0
    li      a7, BIOS_LED_WRITE
    ecall
    li      a0, LED_GREEN
    li      a1, 0
    li      a7, BIOS_LED_WRITE
    ecall
    li      a0, LED_BLUE
    li      a1, 0
    li      a7, BIOS_LED_WRITE
    ecall

    /* 2. Reset OS ecall handler hook */
    li      a0, 0
    li      a7, BIOS_SYS_SET_OS_ECALL_HANDLER
    ecall

    /* 3. Flush keyboard & mouse queues, center mouse (320, 240), reset repeat */
    li      a7, BIOS_KEYBOARD_FLUSH
    ecall
    li      a7, BIOS_MOUSE_POS_FLUSH
    ecall
    li      a7, BIOS_MOUSE_BUTTON_FLUSH
    ecall
    li      a0, 320
    li      a1, 240
    li      a7, BIOS_MOUSE_SET_POS
    ecall
    li      a0, 500
    li      a1, 50
    li      a7, BIOS_KEYBOARD_SET_REPEAT
    ecall

    /* 4. Reset Video RAM: hide cursor, reset text attr, clear TEXT_BUF/ATTR,
     *    zero FRAMEBUF/CTRL/OAM/PAT, reload default CP437 font, enable LATCH_OAM */
    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    li      a0, TEXT_ATTR_NORMAL
    li      a7, BIOS_TEXT_SET_ATTR
    ecall

    li      a7, BIOS_TEXT_CLEAR
    ecall

    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + VIDEO_FRAMEBUF_SIZE
1:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b

    li      t0, VIDEO_CTRL_BASE
    li      t1, VIDEO_RAM_BASE + VIDEO_RAM_SIZE
2:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 2b

    li      t0, VIDEO_CTRL_BASE
    li      t1, VIDEO_CTRL_LATCH_OAM_BIT
    sw      t1, VIDEO_CTRL_FLAGS_OFF(t0)

    li      a7, BIOS_VIDEO_RESET_FONT
    ecall

    /* 5. Synchronize instruction stream, set User SRAM stack, and jump */
    fence.i
    li      sp, USER_STACK_TOP
    jr      s0
.size boot_handoff_and_jump, . - boot_handoff_and_jump

/* ============================================================================
 * Dual Output (UART0 + DVI) & Fatal Error / Halt Helpers
 * ============================================================================ */

/* boot_dvi_puts(a0 = Flash/RAM cstr) */
.type boot_dvi_puts, @function
boot_dvi_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0
1:
    lbu     a0, 0(s0)
    beqz    a0, 2f
    li      a7, BIOS_TEXT_PUTC
    ecall
    addi    s0, s0, 1
    j       1b
2:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_dvi_puts, . - boot_dvi_puts

/* boot_serial_puts(a0 = Flash/RAM cstr): translates '\n' -> "\r\n" on UART0 */
.type boot_serial_puts, @function
boot_serial_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0
1:
    lbu     a0, 0(s0)
    beqz    a0, 3f
    li      t0, '\n'
    bne     a0, t0, 2f
    li      a0, '\r'
    li      a7, BIOS_SERIAL_WRITE
    ecall
    li      a0, '\n'
2:
    li      a7, BIOS_SERIAL_WRITE
    ecall
    addi    s0, s0, 1
    j       1b
3:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_serial_puts, . - boot_serial_puts

/* boot_dual_puts(a0 = Flash/RAM cstr): prints to BOTH UART0 and DVI */
.type boot_dual_puts, @function
boot_dual_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0
    call    boot_serial_puts
    mv      a0, s0
    call    boot_dvi_puts
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_dual_puts, . - boot_dual_puts

/* boot_dual_put_hex32(a0 = uint32_t): prints 8 uppercase hex digits to both */
.type boot_dual_put_hex32, @function
boot_dual_put_hex32:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)
    mv      s0, a0
    li      s1, 28
1:
    srl     t0, s0, s1
    andi    t0, t0, 0x0F
    li      t1, 10
    bltu    t0, t1, 2f
    addi    t0, t0, ('A' - 10)
    j       3f
2:
    addi    t0, t0, '0'
3:
    mv      a0, t0
    li      a7, BIOS_SERIAL_WRITE
    ecall
    mv      a0, t0
    li      a7, BIOS_TEXT_PUTC
    ecall
    addi    s1, s1, -4
    bgez    s1, 1b

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size boot_dual_put_hex32, . - boot_dual_put_hex32

/* boot_fatal_header_err(a0 = HDR_ERR_*): selects message and halts */
.type boot_fatal_header_err, @function
boot_fatal_header_err:
    li      t0, HDR_ERR_MAGIC
    beq     a0, t0, 1f
    li      t0, HDR_ERR_SIZE
    beq     a0, t0, 2f
    li      t0, HDR_ERR_LOAD_RANGE
    beq     a0, t0, 3f
    la      a0, str_err_hdr_entry
    j       boot_fatal_error
1:
    la      a0, str_err_hdr_magic
    j       boot_fatal_error
2:
    la      a0, str_err_hdr_size
    j       boot_fatal_error
3:
    la      a0, str_err_hdr_load_range
    j       boot_fatal_error
.size boot_fatal_header_err, . - boot_fatal_header_err

/* boot_fatal_crc(a0 = expected_crc, a1 = actual_crc): prints mismatch & halts */
.type boot_fatal_crc, @function
boot_fatal_crc:
    mv      s0, a0
    mv      s1, a1

    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    la      a0, str_err_prefix
    call    boot_dual_puts
    la      a0, str_err_crc_exp
    call    boot_dual_puts
    mv      a0, s0
    call    boot_dual_put_hex32
    la      a0, str_err_crc_got
    call    boot_dual_puts
    mv      a0, s1
    call    boot_dual_put_hex32
    la      a0, str_err_crc_end
    call    boot_dual_puts
    j       boot_halt_now
.size boot_fatal_crc, . - boot_fatal_crc

/* boot_fatal_error(a0 = msg_ptr): prints error to UART0 + DVI and halts */
.type boot_fatal_error, @function
boot_fatal_error:
    mv      s0, a0

    li      a0, 0
    li      a1, 0
    li      a7, BIOS_TEXT_SET_CURSOR_STATE
    ecall

    la      a0, str_err_prefix
    call    boot_dual_puts
    mv      a0, s0
    call    boot_dual_puts

boot_halt_now:
    la      a0, str_err_halted
    call    boot_dual_puts

    /* Turn on Red status LED as a physical fault indicator */
    li      a0, LED_RED
    li      a1, 1
    li      a7, BIOS_LED_WRITE
    ecall
1:
    j       1b
.size boot_fatal_error, . - boot_fatal_error

/* ============================================================================
 * Read-Only Strings
 * ============================================================================ */
.section .rodata

str_uart_boot_serial:
    .asciz  "\nBoot from serial: Transmit .oa32 file to boot from\n"

str_dvi_boot_serial:
    .asciz  "\n\n  Boot from serial: Transmit .oa32 file over UART0 (ESC/Ctrl-C to cancel)...\n"

str_uart_write_sd:
    .asciz  "\nWrite SD card from serial: Transmit .oa32 file to write\n"

str_dvi_write_sd:
    .asciz  "\n\n  Write SD card from serial: Transmit .oa32 file over UART0 (ESC/Ctrl-C to cancel)...\n"

str_msg_sd_boot:
    .asciz  "\n\n  Booting from SD Card...\n"

str_msg_sd_writing:
    .asciz  "  CRC-32 verified. Writing image to SD Card...\n"

str_msg_sd_write_ok:
    .asciz  "  SD Card write complete.\n"

str_msg_cancelled:
    .asciz  "Cancelled.\n"

str_err_prefix:
    .asciz  "\n\n  [BOOT ERROR] "

str_err_halted:
    .asciz  "\n  System halted. Press Reset to restart.\n"

str_err_sd_init:
    .asciz  "SD card initialization failed."

str_err_sd_read:
    .asciz  "SD card read error."

str_err_sd_write:
    .asciz  "SD card write error."

str_err_sd_capacity:
    .asciz  "Disk image exceeds SD card capacity."

str_err_serial_timeout:
    .asciz  "Serial transfer timed out."

str_err_hdr_magic:
    .asciz  "Invalid OA32 header magic."

str_err_hdr_size:
    .asciz  "Invalid OA32 header: payload_size is zero."

str_err_hdr_load_range:
    .asciz  "Invalid OA32 header: payload exceeds User SRAM."

str_err_hdr_entry:
    .asciz  "Invalid OA32 header: entry_addr out of range or misaligned."

str_err_crc_exp:
    .asciz  "CRC-32 mismatch (expected 0x"

str_err_crc_got:
    .asciz  ", got 0x"

str_err_crc_end:
    .asciz  ")."
