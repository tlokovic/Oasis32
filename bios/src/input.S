/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Keyboard & Mouse Driver (CH9350 over UART1, State 2)
 * ============================================================================
 * Interrupt-driven driver (Core 0 Xh3irq IRQ 34 / UART1_IRQ) that parses
 * CH9350 State 2 0x57 0xAB frames (CH9350DS.PDF §7.2.3.3, pp. 9-11), strips
 * USB Boot Protocol state snapshots into clean press/release events and
 * screen-space mouse coordinates, and buffers them in BIOS_HID_STATE_BASE
 * (0x50100200, 512 B in USB DPRAM).
 *
 * Exposes BIOS_BLK_INPUT (0x30-0x3F):
 *   - input_init()
 *   - input_uart1_irq_handler()
 *   - input_kbd_read()         / input_kbd_try_read()
 *   - input_kbd_flush()        / input_kbd_state(a0=dst_ptr)
 *   - input_mouse_pos_read()   / input_mouse_pos_try_read()
 *   - input_mouse_pos_flush()
 *   - input_mouse_btn_read()   / input_mouse_btn_try_read()
 *   - input_mouse_btn_flush()
 *   - input_mouse_state()      / input_mouse_set_pos(a0=x, a1=y)
 *
 * References:
 *   - CH9350DS.PDF §7.2.3.3 (State 2 fixed HID datagrams, pp. 9-11)
 *   - rp2350-datasheet.pdf §12.1.8 (PL011 UART1, pp. 883-895), §3.2 (IRQ 34)
 *   - hazard3-manual.pdf §4.8.1 (h3.meiea, pp. 53-54)
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "abi/keycodes.h"
#include "hw/rp2350_regs.h"
#include "hw/oasis32_pins.h"
#include "bios_config.h"
#include "bios_ram.h"

/* CH9350 State 2 framing constants */
#define CH9350_SYNC1                0x57
#define CH9350_SYNC2                0xAB
#define CH9350_ST_SYNC1             0
#define CH9350_ST_SYNC2             1
#define CH9350_ST_CMD               2
#define CH9350_ST_PAYLOAD           3

#define CH9350_CMD_KBD              0x01
#define CH9350_CMD_MOUSE_REL        0x02
#define CH9350_CMD_MOUSE_ABS        0x04
#define CH9350_KBD_ROLLOVER         0x01
#define KBD_MOD_KEYCODE_BASE        0xE0

/* BIOS_HID_STATE_BASE (0x50100200, 512 B) field offsets */
#define HID_OFF_PARSER_ST           0x00    /* uint8_t */
#define HID_OFF_PARSER_CMD          0x01    /* uint8_t */
#define HID_OFF_PARSER_LEN          0x02    /* uint8_t */
#define HID_OFF_PARSER_IDX          0x03    /* uint8_t */
#define HID_OFF_PAYLOAD             0x04    /* uint8_t[8] (0x04..0x0B) */
#define HID_OFF_KBD_MODS            0x0C    /* uint8_t */
#define HID_OFF_KBD_COUNT           0x0D    /* uint8_t (0..6) */
#define HID_OFF_KBD_KEYS            0x0E    /* uint8_t[6] (0x0E..0x13) */
#define HID_OFF_MOUSE_BTNS          0x14    /* uint8_t */
#define HID_OFF_MOUSE_X             0x16    /* uint16_t (0..639) */
#define HID_OFF_MOUSE_Y             0x18    /* uint16_t (0..479) */
#define HID_OFF_KBD_HEAD            0x1C    /* uint8_t (0..31) */
#define HID_OFF_KBD_TAIL            0x1D    /* uint8_t (0..31) */
#define HID_OFF_MPOS_HEAD           0x1E    /* uint8_t (0..15) */
#define HID_OFF_MPOS_TAIL           0x1F    /* uint8_t (0..15) */
#define HID_OFF_MBTN_HEAD           0x20    /* uint8_t (0..15) */
#define HID_OFF_MBTN_TAIL           0x21    /* uint8_t (0..15) */
#define HID_OFF_RPT_KEY             0x22    /* uint8_t active repeating keycode (0=none) */
#define HID_OFF_RPT_DELAY_MS        0x24    /* uint16_t initial repeat delay (ms) */
#define HID_OFF_RPT_RATE_MS         0x26    /* uint16_t repeat interval (ms) */

#define KBD_REPEAT_DEFAULT_DELAY_MS 500
#define KBD_REPEAT_DEFAULT_RATE_MS  50
#define KBD_REPEAT_MAX_MS           65535

/* Ring buffers inside BIOS_HID_STATE_BASE (0x040..0x1BF = 448 B total) */
#define HID_OFF_KBD_RING            0x040   /* 32 x 4 B = 128 B */
#define HID_KBD_RING_MASK           31
#define HID_OFF_MPOS_RING           0x0C0   /* 16 x 8 B = 128 B */
#define HID_MPOS_RING_MASK          15
#define HID_OFF_MBTN_RING           0x140   /* 16 x 8 B = 128 B */
#define HID_MBTN_RING_MASK          15

#define MOUSE_INIT_X                (VIDEO_WIDTH / 2)   /* 320 */
#define MOUSE_INIT_Y                (VIDEO_HEIGHT / 2)  /* 240 */

.section .text, "ax"

/* ============================================================================
 * input_init(): Initialize HID state, UART1 (115200 8N1), GP20/GP21, and
 *               enable UART1_IRQ (IRQ 34) in Hazard3 Xh3irq (h3.meiea).
 * ============================================================================ */
.global input_init
.type input_init, @function
input_init:
    /* 1. Initialize default screen-space mouse cursor to center (320, 240) and
     *    default keyboard typematic repeat (500 ms delay, 50 ms rate).
     *    (All other bytes in BIOS_HID_STATE_BASE are already zeroed by boot.S.) */
    li      t0, BIOS_HID_STATE_BASE
    li      t1, MOUSE_INIT_X
    sh      t1, HID_OFF_MOUSE_X(t0)
    li      t1, MOUSE_INIT_Y
    sh      t1, HID_OFF_MOUSE_Y(t0)
    li      t1, KBD_REPEAT_DEFAULT_DELAY_MS
    sh      t1, HID_OFF_RPT_DELAY_MS(t0)
    li      t1, KBD_REPEAT_DEFAULT_RATE_MS
    sh      t1, HID_OFF_RPT_RATE_MS(t0)

    /* 2. Configure PL011 UART1 for 115200 8N1 with 32-byte FIFOs */
    li      t0, UART1_BASE
    sw      zero, UART_CR_OFF(t0)           /* Disable UART1 while configuring */

    li      t1, CFG_UART_IBRD_115200
    sw      t1, UART_IBRD_OFF(t0)
    li      t1, CFG_UART_FBRD_115200
    sw      t1, UART_FBRD_OFF(t0)
    li      t1, UART_LCR_8N1_FIFO
    sw      t1, UART_LCR_H_OFF(t0)          /* 8N1 + FIFOs (latches BRD) */

    /* Trigger RX IRQ at >= 1/8 FIFO (4 B) + RX timeout for tail bytes */
    li      t1, UART_IFLS_RX_1_8
    sw      t1, UART_IFLS_OFF(t0)
    li      t1, 0x7FF
    sw      t1, UART_ICR_OFF(t0)            /* Clear any stale IRQ flags */
    li      t1, (UART_IMSC_RXIM_BIT | UART_IMSC_RTIM_BIT)
    sw      t1, UART_IMSC_OFF(t0)

    li      t1, UART_CR_EN_TX_RX
    sw      t1, UART_CR_OFF(t0)             /* UARTEN | TXE | RXE */

    /* 3. Route GP20 -> UART1 TX, GP21 -> UART1 RX (Function 2) */
    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_UART
    sw      t1, IO_UART1_TX_CTRL_OFF(t0)
    sw      t1, IO_UART1_RX_CTRL_OFF(t0)

    /* Clear RP2350 pad isolation (ISO) on GP20/GP21; enable IE & PUE on GP21 */
    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, (PADS_ISO_BIT | PADS_OD_BIT)
    sw      t1, PADS_UART1_TX_OFF(t0)
    li      t1, (PADS_ISO_BIT | PADS_PDE_BIT)
    sw      t1, PADS_UART1_RX_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_SET
    li      t1, (PADS_IE_BIT | PADS_PUE_BIT)
    sw      t1, PADS_UART1_RX_OFF(t0)

    /* 4. Enable TIMER0 Alarm 0 IRQ (IRQ 0) for typematic key repeat */
    li      t0, TIMER0_BASE
    li      t1, TIMER_ALARM0_BIT
    sw      t1, TIMER_ARMED_OFF(t0)         /* Ensure Alarm 0 starts disarmed */
    sw      t1, TIMER_INTR_OFF(t0)          /* Clear any stale raw IRQ */
    li      t0, TIMER0_BASE + ATOMIC_SET
    sw      t1, TIMER_INTE_OFF(t0)          /* Enable TIMER0_IRQ_0 */

    /* 5. Enable IRQ 0 (TIMER0_IRQ_0) & IRQ 34 (UART1_IRQ) in h3.meiea and mie.MEIE */
    li      t0, H3_IRQ_TIMER0_0_MEIEA
    csrs    CSR_MEIEA, t0
    li      t0, H3_IRQ_UART1_MEIEA
    csrs    CSR_MEIEA, t0
    li      t0, MIE_MEIE_BIT
    csrs    mie, t0
    ret
.size input_init, . - input_init

/* ============================================================================
 * input_uart1_irq_handler(): Called from trap_meip_entry (MIE=0, Bank 8 IRQ
 *   stack). Drains UART1 RX FIFO, parses CH9350 State 2 frames, and enqueues
 *   decoded keyboard/mouse events into BIOS_HID_STATE_BASE.
 * ============================================================================ */
.global input_uart1_irq_handler
.type input_uart1_irq_handler, @function
input_uart1_irq_handler:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)

    li      s0, UART1_BASE
    li      s1, BIOS_HID_STATE_BASE

uart1_drain_loop:
    lw      t0, UART_FR_OFF(s0)
    andi    t0, t0, UART_FR_RXFE_BIT
    bnez    t0, uart1_drain_done

    lw      s2, UART_DR_OFF(s0)
    andi    s2, s2, 0xFF                    /* s2 = received byte */

    lbu     t0, HID_OFF_PARSER_ST(s1)
    beqz    t0, st_sync1
    li      t1, CH9350_ST_SYNC2
    beq     t0, t1, st_sync2
    li      t1, CH9350_ST_CMD
    beq     t0, t1, st_cmd
    j       st_payload

st_sync1:
    li      t1, CH9350_SYNC1
    bne     s2, t1, uart1_drain_loop
    li      t1, CH9350_ST_SYNC2
    sb      t1, HID_OFF_PARSER_ST(s1)
    j       uart1_drain_loop

st_sync2:
    li      t1, CH9350_SYNC2
    beq     s2, t1, 1f
    li      t1, CH9350_SYNC1
    beq     s2, t1, uart1_drain_loop        /* Stay in ST_SYNC2 on 0x57 0x57 */
    sb      zero, HID_OFF_PARSER_ST(s1)
    j       uart1_drain_loop
1:
    li      t1, CH9350_ST_CMD
    sb      t1, HID_OFF_PARSER_ST(s1)
    j       uart1_drain_loop

st_cmd:
    sb      s2, HID_OFF_PARSER_CMD(s1)
    sb      zero, HID_OFF_PARSER_IDX(s1)

    li      t2, 8
    li      t1, CH9350_CMD_KBD
    beq     s2, t1, st_set_len
    li      t2, 4
    li      t1, CH9350_CMD_MOUSE_REL
    beq     s2, t1, st_set_len
    li      t2, 7
    li      t1, CH9350_CMD_MOUSE_ABS
    beq     s2, t1, st_set_len
    li      t2, 1
    li      t1, 0x80
    beq     s2, t1, st_set_len
    li      t1, 0x82
    beq     s2, t1, st_set_len
    li      t1, 0x85
    beq     s2, t1, st_set_len

    /* 0-byte frames (0x84, 0x86, 0x87) or unknown: reset to ST_SYNC1 */
    sb      zero, HID_OFF_PARSER_ST(s1)
    j       uart1_drain_loop

st_set_len:
    sb      t2, HID_OFF_PARSER_LEN(s1)
    li      t1, CH9350_ST_PAYLOAD
    sb      t1, HID_OFF_PARSER_ST(s1)
    j       uart1_drain_loop

st_payload:
    lbu     t0, HID_OFF_PARSER_IDX(s1)
    addi    t1, s1, HID_OFF_PAYLOAD
    add     t1, t1, t0
    sb      s2, 0(t1)
    addi    t0, t0, 1
    sb      t0, HID_OFF_PARSER_IDX(s1)

    lbu     t2, HID_OFF_PARSER_LEN(s1)
    bltu    t0, t2, uart1_drain_loop

    /* Complete frame received -> reset parser and dispatch */
    sb      zero, HID_OFF_PARSER_ST(s1)
    lbu     t0, HID_OFF_PARSER_CMD(s1)
    li      t1, CH9350_CMD_KBD
    beq     t0, t1, 2f
    li      t1, CH9350_CMD_MOUSE_REL
    beq     t0, t1, 3f
    j       uart1_drain_loop
2:
    call    hid_process_kbd
    j       uart1_drain_loop
3:
    call    hid_process_mouse
    j       uart1_drain_loop

uart1_drain_done:
    /* Clear RX/RT interrupt flags and perform APB write-flush read
     * (rp2350-datasheet.pdf §2.1.2, p. 28) */
    li      t0, (UART_ICR_RXIC_BIT | UART_ICR_RTIC_BIT)
    sw      t0, UART_ICR_OFF(s0)
    lw      zero, UART_FR_OFF(s0)

    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size input_uart1_irq_handler, . - input_uart1_irq_handler

/* ----------------------------------------------------------------------------
 * Internal (ISR): hid_push_kbd_event(a0 = event_word)
 *   Expects s1 = BIOS_HID_STATE_BASE. Drops newest if ring is full.
 * ---------------------------------------------------------------------------- */
.type hid_push_kbd_event, @function
hid_push_kbd_event:
    lbu     t0, HID_OFF_KBD_HEAD(s1)
    lbu     t1, HID_OFF_KBD_TAIL(s1)
    addi    t2, t0, 1
    andi    t2, t2, HID_KBD_RING_MASK
    beq     t2, t1, 1f                      /* Full -> drop */
    slli    t0, t0, 2
    addi    t3, s1, HID_OFF_KBD_RING
    add     t3, t3, t0
    sw      a0, 0(t3)
    sb      t2, HID_OFF_KBD_HEAD(s1)
1:
    ret
.size hid_push_kbd_event, . - hid_push_kbd_event

/* ----------------------------------------------------------------------------
 * Internal (ISR): hid_process_kbd()
 *   Expects s1 = BIOS_HID_STATE_BASE.
 *   Payload[0] = new_mod, Payload[1] = reserved, Payload[2..7] = 6 key slots.
 *   Stack layout (32 B):
 *     0(sp)..5(sp) = new_keys[6] (tightly packed non-zero keycodes)
 * ---------------------------------------------------------------------------- */
.type hid_process_kbd, @function
hid_process_kbd:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s3, 24(sp)                      /* new_mod */
    sw      s4, 20(sp)                      /* new_count */
    sw      s5, 16(sp)                      /* loop idx / scratch */
    sw      s6, 12(sp)                      /* old_count / scratch */

    /* 1. Pack non-zero keys from payload[2..7] into 0(sp)..5(sp);
     *    abort entire frame if ErrorRollOver (0x01) is present. */
    addi    t0, s1, HID_OFF_PAYLOAD + 2
    li      t1, 0                           /* i = 0..5 */
    li      s4, 0                           /* new_count = 0 */
    li      t3, KEY_STATE_MAX_KEYS
    li      t4, CH9350_KBD_ROLLOVER
1:
    lbu     t2, 0(t0)
    beq     t2, t4, kbd_proc_done           /* Phantom/rollover frame -> ignore */
    beqz    t2, 2f
    add     t5, sp, s4
    sb      t2, 0(t5)
    addi    s4, s4, 1
2:
    addi    t0, t0, 1
    addi    t1, t1, 1
    bltu    t1, t3, 1b

    /* Zero-pad remainder of new_keys[new_count..5] */
    mv      t1, s4
3:
    bgeu    t1, t3, 4f
    add     t5, sp, t1
    sb      zero, 0(t5)
    addi    t1, t1, 1
    j       3b
4:
    /* 2. Diff modifier byte and emit key-down/up events for 0xE0..0xE7 */
    lbu     s3, HID_OFF_PAYLOAD(s1)         /* s3 = new_mod */
    lbu     t0, HID_OFF_KBD_MODS(s1)        /* t0 = old_mod */
    xor     s6, t0, s3                      /* s6 = changed mod bits */
    beqz    s6, kbd_diff_releases

    li      s5, 0                           /* bit = 0..7 */
kbd_mod_loop:
    srl     t0, s6, s5
    andi    t0, t0, 1
    beqz    t0, kbd_mod_next

    addi    a0, s5, KBD_MOD_KEYCODE_BASE    /* keycode = 0xE0 + bit */
    slli    t1, s3, KEY_EVENT_MOD_SHIFT
    or      a0, a0, t1                      /* | (new_mod << 8) */
    srl     t2, s3, s5
    andi    t2, t2, 1
    beqz    t2, 5f
    li      t2, KEY_EVENT_DOWN_BIT
    or      a0, a0, t2                      /* | KEY_EVENT_DOWN_BIT */
5:
    call    hid_push_kbd_event

kbd_mod_next:
    addi    s5, s5, 1
    li      t0, 8
    bltu    s5, t0, kbd_mod_loop

    /* 3. Diff released keys: in old_keys[0..old_count-1], not in new_keys */
kbd_diff_releases:
    lbu     s6, HID_OFF_KBD_COUNT(s1)
    li      s5, 0
kbd_rel_outer:
    bgeu    s5, s6, kbd_diff_presses
    addi    t0, s1, HID_OFF_KBD_KEYS
    add     t0, t0, s5
    lbu     t1, 0(t0)                       /* t1 = old_key */

    /* Search new_keys[0..s4-1] */
    li      t2, 0
kbd_rel_inner:
    bgeu    t2, s4, kbd_rel_emit            /* Not found -> released! */
    add     t3, sp, t2
    lbu     t4, 0(t3)
    beq     t4, t1, kbd_rel_next            /* Still held */
    addi    t2, t2, 1
    j       kbd_rel_inner

kbd_rel_emit:
    /* If the released key is the active repeating key, cancel repeat & disarm Alarm 0 */
    lbu     t0, HID_OFF_RPT_KEY(s1)
    bne     t1, t0, 1f
    sb      zero, HID_OFF_RPT_KEY(s1)
    li      t0, TIMER0_BASE
    li      t2, TIMER_ALARM0_BIT
    sw      t2, TIMER_ARMED_OFF(t0)
    sw      t2, TIMER_INTR_OFF(t0)
1:
    slli    t2, s3, KEY_EVENT_MOD_SHIFT
    or      a0, t1, t2                      /* DOWN = 0 */
    call    hid_push_kbd_event

kbd_rel_next:
    addi    s5, s5, 1
    j       kbd_rel_outer

    /* 4. Diff pressed keys: in new_keys[0..s4-1], not in old_keys[0..s6-1] */
kbd_diff_presses:
    li      s5, 0
kbd_prs_outer:
    bgeu    s5, s4, kbd_commit_state
    add     t0, sp, s5
    lbu     t1, 0(t0)                       /* t1 = new_key */

    /* Search old_keys[0..s6-1] */
    li      t2, 0
kbd_prs_inner:
    bgeu    t2, s6, kbd_prs_emit            /* Not found -> newly pressed! */
    addi    t3, s1, HID_OFF_KBD_KEYS
    add     t3, t3, t2
    lbu     t4, 0(t3)
    beq     t4, t1, kbd_prs_next            /* Already held */
    addi    t2, t2, 1
    j       kbd_prs_inner

kbd_prs_emit:
    /* Last-pressed non-modifier key owns typematic repeat; arm Alarm 0 for delay_ms */
    sb      t1, HID_OFF_RPT_KEY(s1)
    lhu     t0, HID_OFF_RPT_DELAY_MS(s1)
    beqz    t0, 2f
    lhu     t2, HID_OFF_RPT_RATE_MS(s1)
    beqz    t2, 2f
    li      t2, 1000
    mul     t0, t0, t2                      /* delay_us = delay_ms * 1000 */
    li      t2, TIMER0_BASE
    li      t3, TIMER_ALARM0_BIT
    sw      t3, TIMER_INTR_OFF(t2)          /* Clear any stale pending flag */
    lw      t3, TIMER_RAWL_OFF(t2)
    add     t3, t3, t0
    sw      t3, TIMER_ALARM0_OFF(t2)        /* Arm Alarm 0 */
2:
    slli    t2, s3, KEY_EVENT_MOD_SHIFT
    or      a0, t1, t2
    li      t2, KEY_EVENT_DOWN_BIT
    or      a0, a0, t2                      /* DOWN = 1 */
    call    hid_push_kbd_event

kbd_prs_next:
    addi    s5, s5, 1
    j       kbd_prs_outer

    /* 5. Commit new live keyboard state */
kbd_commit_state:
    sb      s3, HID_OFF_KBD_MODS(s1)
    sb      s4, HID_OFF_KBD_COUNT(s1)
    li      t0, 0
    li      t1, KEY_STATE_MAX_KEYS
6:
    add     t2, sp, t0
    lbu     t3, 0(t2)
    addi    t4, s1, HID_OFF_KBD_KEYS
    add     t4, t4, t0
    sb      t3, 0(t4)
    addi    t0, t0, 1
    bltu    t0, t1, 6b

kbd_proc_done:
    lw      s6, 12(sp)
    lw      s5, 16(sp)
    lw      s4, 20(sp)
    lw      s3, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size hid_process_kbd, . - hid_process_kbd

/* ----------------------------------------------------------------------------
 * Internal (ISR): hid_process_mouse()
 *   Expects s1 = BIOS_HID_STATE_BASE.
 *   Payload[0] = buttons (u8), [1] = dx (s8), [2] = dy (s8), [3] = dwheel (s8).
 * ---------------------------------------------------------------------------- */
.type hid_process_mouse, @function
hid_process_mouse:
    lbu     t0, HID_OFF_PAYLOAD + 0(s1)     /* t0 = new_btns */
    lb      t1, HID_OFF_PAYLOAD + 1(s1)     /* t1 = dx (signed) */
    lb      t2, HID_OFF_PAYLOAD + 2(s1)     /* t2 = dy (signed) */
    lb      t3, HID_OFF_PAYLOAD + 3(s1)     /* t3 = dwheel (signed) */

    /* 1. Update and clamp screen-space (x, y) to [0..639] x [0..479] */
    lhu     t4, HID_OFF_MOUSE_X(s1)
    add     t4, t4, t1
    bgez    t4, 1f
    li      t4, 0
    j       2f
1:
    li      t5, (VIDEO_WIDTH - 1)
    ble     t4, t5, 2f
    mv      t4, t5
2:
    sh      t4, HID_OFF_MOUSE_X(s1)         /* t4 = clamped x */

    lhu     t5, HID_OFF_MOUSE_Y(s1)
    add     t5, t5, t2
    bgez    t5, 3f
    li      t5, 0
    j       4f
3:
    li      t6, (VIDEO_HEIGHT - 1)
    ble     t5, t6, 4f
    mv      t5, t6
4:
    sh      t5, HID_OFF_MOUSE_Y(s1)         /* t5 = clamped y */

    /* 2. Enqueue position event if any of dx, dy, dwheel is non-zero */
    or      t6, t1, t2
    or      t6, t6, t3
    beqz    t6, mouse_check_buttons

    lbu     a0, HID_OFF_MPOS_HEAD(s1)
    lbu     a1, HID_OFF_MPOS_TAIL(s1)
    addi    a2, a0, 1
    andi    a2, a2, HID_MPOS_RING_MASK
    beq     a2, a1, mouse_check_buttons     /* Position ring full -> drop */
    slli    a0, a0, 3                       /* entry offset = head * 8 */
    addi    a3, s1, HID_OFF_MPOS_RING
    add     a3, a3, a0
    sh      t4, 0(a3)                       /* x */
    sh      t5, 2(a3)                       /* y */
    sb      t1, 4(a3)                       /* dx */
    sb      t2, 5(a3)                       /* dy */
    sb      t3, 6(a3)                       /* dwheel */
    sb      zero, 7(a3)                     /* pad */
    sb      a2, HID_OFF_MPOS_HEAD(s1)

    /* 3. Diff buttons and enqueue one event per changed button bit */
mouse_check_buttons:
    lbu     t1, HID_OFF_MOUSE_BTNS(s1)      /* old_btns */
    xor     t2, t1, t0                      /* t2 = changed bits */
    beqz    t2, mouse_proc_done

    sb      t0, HID_OFF_MOUSE_BTNS(s1)      /* Commit new_btns */
    li      t3, 0                           /* bit = 0..7 */
mouse_btn_loop:
    srl     t6, t2, t3
    andi    t6, t6, 1
    beqz    t6, mouse_btn_next

    /* Build button event word in a4:
     *   bits 7:0   = (1 << bit)
     *   bits 15:8  = new_btns
     *   bit  16    = down (1 if new_btns & (1 << bit) else 0) */
    li      a4, 1
    sll     a4, a4, t3                      /* single changed button bit */
    slli    a5, t0, MOUSE_EVENT_STATE_SHIFT
    or      a4, a4, a5
    srl     a5, t0, t3
    andi    a5, a5, 1
    beqz    a5, 5f
    li      a5, MOUSE_EVENT_DOWN_BIT
    or      a4, a4, a5
5:
    lbu     a0, HID_OFF_MBTN_HEAD(s1)
    lbu     a1, HID_OFF_MBTN_TAIL(s1)
    addi    a2, a0, 1
    andi    a2, a2, HID_MBTN_RING_MASK
    beq     a2, a1, mouse_btn_next          /* Button ring full -> drop */
    slli    a0, a0, 3
    addi    a3, s1, HID_OFF_MBTN_RING
    add     a3, a3, a0
    sw      a4, 0(a3)                       /* event word */
    sh      t4, 4(a3)                       /* captured x */
    sh      t5, 6(a3)                       /* captured y */
    sb      a2, HID_OFF_MBTN_HEAD(s1)

mouse_btn_next:
    addi    t3, t3, 1
    li      t6, 8
    bltu    t3, t6, mouse_btn_loop

mouse_proc_done:
    ret
.size hid_process_mouse, . - hid_process_mouse

/* ============================================================================
 * Public BIOS ABI Service Implementations (0x30-0x33 Keyboard, 0x38-0x3F Mouse)
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * input_kbd_try_read() -> a0 = key_event (>= 0) or ERR_EMPTY (-3)
 * ---------------------------------------------------------------------------- */
.global input_kbd_try_read
.type input_kbd_try_read, @function
input_kbd_try_read:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT    /* Enter critical section */
    li      t0, BIOS_HID_STATE_BASE
    lbu     t1, HID_OFF_KBD_HEAD(t0)
    lbu     t2, HID_OFF_KBD_TAIL(t0)
    beq     t1, t2, 1f

    slli    t3, t2, 2
    addi    t4, t0, HID_OFF_KBD_RING
    add     t4, t4, t3
    lw      a0, 0(t4)
    addi    t2, t2, 1
    andi    t2, t2, HID_KBD_RING_MASK
    sb      t2, HID_OFF_KBD_TAIL(t0)
    j       2f
1:
    li      a0, ERR_EMPTY
2:
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6                     /* Restore previous MIE */
    ret
.size input_kbd_try_read, . - input_kbd_try_read

/* ----------------------------------------------------------------------------
 * input_kbd_read() -> a0 = key_event (>= 0), blocking
 * ---------------------------------------------------------------------------- */
.global input_kbd_read
.type input_kbd_read, @function
input_kbd_read:
    addi    sp, sp, -16
    sw      ra, 12(sp)
1:
    call    input_kbd_try_read
    bltz    a0, 1b
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size input_kbd_read, . - input_kbd_read

/* ----------------------------------------------------------------------------
 * input_kbd_flush() -> a0 = ERR_OK (0)
 *   Clears queued keyboard events and cancels any active typematic repeat so
 *   a held key does not immediately inject a stale repeat into a fresh prompt.
 * ---------------------------------------------------------------------------- */
.global input_kbd_flush
.type input_kbd_flush, @function
input_kbd_flush:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     t1, HID_OFF_KBD_HEAD(t0)
    sb      t1, HID_OFF_KBD_TAIL(t0)
    sb      zero, HID_OFF_RPT_KEY(t0)
    li      t0, TIMER0_BASE
    li      t1, TIMER_ALARM0_BIT
    sw      t1, TIMER_ARMED_OFF(t0)
    sw      t1, TIMER_INTR_OFF(t0)
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    li      a0, ERR_OK
    ret
.size input_kbd_flush, . - input_kbd_flush

/* ----------------------------------------------------------------------------
 * input_kbd_state(a0 = dst_ptr) -> a0 = count (0..6) or ERR_INVALID_ARG (-2),
 *                                  a1 = modifiers (KEY_MOD_* mask)
 *   Writes active keycodes to dst_ptr[0..count-1], zero-padded to 8 bytes.
 * ---------------------------------------------------------------------------- */
.global input_kbd_state
.type input_kbd_state, @function
input_kbd_state:
    /* Validate [dst_ptr, dst_ptr + KEY_STATE_BUF_SIZE) inside User SRAM */
    li      t0, USER_RAM_BASE
    bltu    a0, t0, 2f
    li      t0, (USER_RAM_BASE + USER_RAM_SIZE - KEY_STATE_BUF_SIZE)
    bgtu    a0, t0, 2f
    mv      t5, a0                          /* t5 = dst_ptr */

    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     a0, HID_OFF_KBD_COUNT(t0)       /* return count in a0 */
    lbu     a1, HID_OFF_KBD_MODS(t0)        /* return modifiers in a1 */

    li      t1, 0
    li      t2, KEY_STATE_MAX_KEYS
1:
    addi    t3, t0, HID_OFF_KBD_KEYS
    add     t3, t3, t1
    lbu     t4, 0(t3)
    add     t3, t5, t1
    sb      t4, 0(t3)
    addi    t1, t1, 1
    bltu    t1, t2, 1b

    /* Zero-pad bytes 6 and 7 of the 8-byte caller buffer */
    sb      zero, 6(t5)
    sb      zero, 7(t5)

    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    ret
2:
    li      a0, ERR_INVALID_ARG
    ret
.size input_kbd_state, . - input_kbd_state

/* ----------------------------------------------------------------------------
 * input_mouse_pos_try_read() ->
 *   Success: a0 = 0, a1 = x, a2 = y, a3 = dx, a4 = dy, a5 = dwheel
 *   Empty:   a0 = ERR_EMPTY (-3)
 * ---------------------------------------------------------------------------- */
.global input_mouse_pos_try_read
.type input_mouse_pos_try_read, @function
input_mouse_pos_try_read:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     t1, HID_OFF_MPOS_HEAD(t0)
    lbu     t2, HID_OFF_MPOS_TAIL(t0)
    beq     t1, t2, 1f

    slli    t3, t2, 3
    addi    t4, t0, HID_OFF_MPOS_RING
    add     t4, t4, t3
    lhu     a1, 0(t4)                       /* x (0..639) */
    lhu     a2, 2(t4)                       /* y (0..479) */
    lb      a3, 4(t4)                       /* dx (signed) */
    lb      a4, 5(t4)                       /* dy (signed) */
    lb      a5, 6(t4)                       /* dwheel (signed) */
    addi    t2, t2, 1
    andi    t2, t2, HID_MPOS_RING_MASK
    sb      t2, HID_OFF_MPOS_TAIL(t0)
    li      a0, ERR_OK
    j       2f
1:
    li      a0, ERR_EMPTY
2:
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    ret
.size input_mouse_pos_try_read, . - input_mouse_pos_try_read

/* ----------------------------------------------------------------------------
 * input_mouse_pos_read() -> a0 = 0, a1 = x, a2 = y, a3 = dx, a4 = dy, a5 = dw
 * ---------------------------------------------------------------------------- */
.global input_mouse_pos_read
.type input_mouse_pos_read, @function
input_mouse_pos_read:
    addi    sp, sp, -16
    sw      ra, 12(sp)
1:
    call    input_mouse_pos_try_read
    bltz    a0, 1b
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size input_mouse_pos_read, . - input_mouse_pos_read

/* ----------------------------------------------------------------------------
 * input_mouse_pos_flush() -> a0 = ERR_OK (0)
 * ---------------------------------------------------------------------------- */
.global input_mouse_pos_flush
.type input_mouse_pos_flush, @function
input_mouse_pos_flush:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     t1, HID_OFF_MPOS_HEAD(t0)
    sb      t1, HID_OFF_MPOS_TAIL(t0)
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    li      a0, ERR_OK
    ret
.size input_mouse_pos_flush, . - input_mouse_pos_flush

/* ----------------------------------------------------------------------------
 * input_mouse_btn_try_read() ->
 *   Success: a0 = btn_event (>= 0), a1 = captured x, a2 = captured y
 *   Empty:   a0 = ERR_EMPTY (-3)
 * ---------------------------------------------------------------------------- */
.global input_mouse_btn_try_read
.type input_mouse_btn_try_read, @function
input_mouse_btn_try_read:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     t1, HID_OFF_MBTN_HEAD(t0)
    lbu     t2, HID_OFF_MBTN_TAIL(t0)
    beq     t1, t2, 1f

    slli    t3, t2, 3
    addi    t4, t0, HID_OFF_MBTN_RING
    add     t4, t4, t3
    lw      a0, 0(t4)                       /* packed button event */
    lhu     a1, 4(t4)                       /* captured x */
    lhu     a2, 6(t4)                       /* captured y */
    addi    t2, t2, 1
    andi    t2, t2, HID_MBTN_RING_MASK
    sb      t2, HID_OFF_MBTN_TAIL(t0)
    j       2f
1:
    li      a0, ERR_EMPTY
2:
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    ret
.size input_mouse_btn_try_read, . - input_mouse_btn_try_read

/* ----------------------------------------------------------------------------
 * input_mouse_btn_read() -> a0 = btn_event, a1 = captured x, a2 = captured y
 * ---------------------------------------------------------------------------- */
.global input_mouse_btn_read
.type input_mouse_btn_read, @function
input_mouse_btn_read:
    addi    sp, sp, -16
    sw      ra, 12(sp)
1:
    call    input_mouse_btn_try_read
    bltz    a0, 1b
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size input_mouse_btn_read, . - input_mouse_btn_read

/* ----------------------------------------------------------------------------
 * input_mouse_btn_flush() -> a0 = ERR_OK (0)
 * ---------------------------------------------------------------------------- */
.global input_mouse_btn_flush
.type input_mouse_btn_flush, @function
input_mouse_btn_flush:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     t1, HID_OFF_MBTN_HEAD(t0)
    sb      t1, HID_OFF_MBTN_TAIL(t0)
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    li      a0, ERR_OK
    ret
.size input_mouse_btn_flush, . - input_mouse_btn_flush

/* ----------------------------------------------------------------------------
 * input_mouse_state() -> a0 = buttons (0..255), a1 = x (0..639), a2 = y (0..479)
 * ---------------------------------------------------------------------------- */
.global input_mouse_state
.type input_mouse_state, @function
input_mouse_state:
    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    lbu     a0, HID_OFF_MOUSE_BTNS(t0)
    lhu     a1, HID_OFF_MOUSE_X(t0)
    lhu     a2, HID_OFF_MOUSE_Y(t0)
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    ret
.size input_mouse_state, . - input_mouse_state

/* ----------------------------------------------------------------------------
 * input_mouse_set_pos(a0 = x, a1 = y) -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 * ---------------------------------------------------------------------------- */
.global input_mouse_set_pos
.type input_mouse_set_pos, @function
input_mouse_set_pos:
    li      t0, VIDEO_WIDTH
    bgeu    a0, t0, 1f
    li      t0, VIDEO_HEIGHT
    bgeu    a1, t0, 1f

    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    sh      a0, HID_OFF_MOUSE_X(t0)
    sh      a1, HID_OFF_MOUSE_Y(t0)
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    li      a0, ERR_OK
    ret
1:
    li      a0, ERR_INVALID_ARG
    ret
.size input_mouse_set_pos, . - input_mouse_set_pos

/* ----------------------------------------------------------------------------
 * input_kbd_keycode_to_ascii(a0 = keycode, a1 = modifiers)
 *   -> a0 = printable ASCII (0x20..0x7E), or 0 if non-printable.
 *   Shift-aware US keyboard layout for main block (KEY_A..KEY_SLASH) and
 *   numeric keypad (KEY_KP_DIVIDE..KEY_KP_DOT).
 * ---------------------------------------------------------------------------- */
.global input_kbd_keycode_to_ascii
.type input_kbd_keycode_to_ascii, @function
input_kbd_keycode_to_ascii:
    /* Main printable block: KEY_A (0x04) .. KEY_SLASH (0x38) */
    li      t0, KEY_A
    bltu    a0, t0, kbd_to_ascii_none
    li      t0, KEY_SLASH
    bgtu    a0, t0, kbd_to_ascii_keypad

    addi    t1, a0, -KEY_A
    andi    t2, a1, (KEY_MOD_LSHIFT | KEY_MOD_RSHIFT)
    la      t0, kbd_ascii_normal
    beqz    t2, 1f
    la      t0, kbd_ascii_shift
1:
    add     t0, t0, t1
    lbu     a0, 0(t0)
    ret

kbd_to_ascii_keypad:
    /* Numeric keypad printable block: KEY_KP_DIVIDE (0x54) .. KEY_KP_DOT (0x63) */
    li      t0, KEY_KP_DIVIDE
    bltu    a0, t0, kbd_to_ascii_none
    li      t0, KEY_KP_DOT
    bgtu    a0, t0, kbd_to_ascii_none
    addi    t1, a0, -KEY_KP_DIVIDE
    la      t0, kbd_keypad_ascii
    add     t0, t0, t1
    lbu     a0, 0(t0)
    ret

kbd_to_ascii_none:
    li      a0, 0
    ret
.size input_kbd_keycode_to_ascii, . - input_kbd_keycode_to_ascii

/* ----------------------------------------------------------------------------
 * input_timer0_irq_handler(): Called from trap_meip_entry (IRQ 0, MIE=0,
 *   Bank 8 IRQ stack). Emits a synthetic repeat event for HID_OFF_RPT_KEY
 *   with KEY_EVENT_DOWN_BIT | KEY_EVENT_REPEAT_BIT and re-arms Alarm 0 for
 *   HID_OFF_RPT_RATE_MS milliseconds.
 * ---------------------------------------------------------------------------- */
.global input_timer0_irq_handler
.type input_timer0_irq_handler, @function
input_timer0_irq_handler:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)

    /* Clear latched Alarm 0 IRQ + APB write-flush read (§2.1.2, p. 28) */
    li      s0, TIMER0_BASE
    li      t0, TIMER_ALARM0_BIT
    sw      t0, TIMER_INTR_OFF(s0)
    lw      zero, TIMER_INTR_OFF(s0)

    li      s1, BIOS_HID_STATE_BASE
    lbu     t0, HID_OFF_RPT_KEY(s1)
    beqz    t0, timer0_irq_done
    lhu     t1, HID_OFF_RPT_DELAY_MS(s1)
    beqz    t1, timer0_irq_done
    lhu     t1, HID_OFF_RPT_RATE_MS(s1)
    beqz    t1, timer0_irq_done

    /* Enqueue (KEY_EVENT_REPEAT_BIT | KEY_EVENT_DOWN_BIT | mods<<8 | key) */
    lbu     t2, HID_OFF_KBD_MODS(s1)
    slli    t2, t2, KEY_EVENT_MOD_SHIFT
    or      a0, t0, t2
    li      t2, (KEY_EVENT_DOWN_BIT | KEY_EVENT_REPEAT_BIT)
    or      a0, a0, t2
    call    hid_push_kbd_event

    /* Re-arm TIMER0 Alarm 0 for rate_ms * 1000 us */
    lhu     t1, HID_OFF_RPT_RATE_MS(s1)
    li      t2, 1000
    mul     t1, t1, t2
    lw      t2, TIMER_RAWL_OFF(s0)
    add     t2, t2, t1
    sw      t2, TIMER_ALARM0_OFF(s0)

timer0_irq_done:
    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size input_timer0_irq_handler, . - input_timer0_irq_handler

/* ----------------------------------------------------------------------------
 * input_kbd_set_repeat(a0 = delay_ms, a1 = rate_ms)
 *   -> a0 = ERR_OK (0) or ERR_INVALID_ARG (-2)
 *   Valid range: 0..65535 ms. Either 0 disables typematic repeat immediately.
 * ---------------------------------------------------------------------------- */
.global input_kbd_set_repeat
.type input_kbd_set_repeat, @function
input_kbd_set_repeat:
    li      t0, KBD_REPEAT_MAX_MS
    bgtu    a0, t0, 2f
    bgtu    a1, t0, 2f

    csrrci  t6, mstatus, MSTATUS_MIE_BIT
    li      t0, BIOS_HID_STATE_BASE
    sh      a0, HID_OFF_RPT_DELAY_MS(t0)
    sh      a1, HID_OFF_RPT_RATE_MS(t0)

    /* If disabled (either 0), cancel any active repeat & disarm Alarm 0 */
    beqz    a0, 1f
    bnez    a1, 3f
1:
    sb      zero, HID_OFF_RPT_KEY(t0)
    li      t0, TIMER0_BASE
    li      t1, TIMER_ALARM0_BIT
    sw      t1, TIMER_ARMED_OFF(t0)
    sw      t1, TIMER_INTR_OFF(t0)
3:
    andi    t6, t6, MSTATUS_MIE_BIT
    csrs    mstatus, t6
    li      a0, ERR_OK
    ret
2:
    li      a0, ERR_INVALID_ARG
    ret
.size input_kbd_set_repeat, . - input_kbd_set_repeat

/* ----------------------------------------------------------------------------
 * input_kbd_get_repeat() -> a0 = delay_ms (0..65535), a1 = rate_ms (0..65535)
 * ---------------------------------------------------------------------------- */
.global input_kbd_get_repeat
.type input_kbd_get_repeat, @function
input_kbd_get_repeat:
    li      t0, BIOS_HID_STATE_BASE
    lhu     a0, HID_OFF_RPT_DELAY_MS(t0)
    lhu     a1, HID_OFF_RPT_RATE_MS(t0)
    ret
.size input_kbd_get_repeat, . - input_kbd_get_repeat

/* ============================================================================
 * Read-Only Keycode-to-ASCII Lookup Tables (.rodata in XIP Flash)
 * ============================================================================ */
.section .rodata, "a"

/* Main block KEY_A (0x04) .. KEY_SLASH (0x38): 53 entries (0 = non-printable) */
kbd_ascii_normal:
    .byte 'a','b','c','d','e','f','g','h','i','j','k','l','m'
    .byte 'n','o','p','q','r','s','t','u','v','w','x','y','z'
    .byte '1','2','3','4','5','6','7','8','9','0'
    .byte 0, 0, 0, 0, ' '               /* Enter, Esc, Backspace, Tab, Space */
    .byte '-','=','[',']','\\','#',';','\'','`',',','.','/'

kbd_ascii_shift:
    .byte 'A','B','C','D','E','F','G','H','I','J','K','L','M'
    .byte 'N','O','P','Q','R','S','T','U','V','W','X','Y','Z'
    .byte '!','@','#','$','%','^','&','*','(',')'
    .byte 0, 0, 0, 0, ' '               /* Enter, Esc, Backspace, Tab, Space */
    .byte '_','+','{','}','|','~',':','"','~','<','>','?'

/* Numeric keypad KEY_KP_DIVIDE (0x54) .. KEY_KP_DOT (0x63): 16 entries */
kbd_keypad_ascii:
    .byte '/','*','-','+',0             /* /, *, -, +, KP Enter */
    .byte '1','2','3','4','5','6','7','8','9','0','.'
