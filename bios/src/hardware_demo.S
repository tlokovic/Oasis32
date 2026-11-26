/*
 * ============================================================================
 * Oasis32 Hardware Demo — ABI Validation Harness (Temporary BIOS Payload)
 * ============================================================================
 * Reconstructs the Phase 2 test harness behaviors strictly through the public
 * Oasis32 BIOS ecall ABI (`include/abi/bios_abi.h`, `include/abi/devices.h`),
 * with ZERO direct hardware register access or `bios/internal/` includes.
 *
 * Currently exercises:
 *   - Serial Console (BIOS_SERIAL_TRY_READ, BIOS_SERIAL_WRITE): splash + echo
 *   - Monotonic Timer (BIOS_TIME_US): non-blocking cooperative scheduling
 *   - Status LEDs (BIOS_LED_WRITE): Red -> Green -> Blue cycle (1/s)
 *   - Piezo Audio (BIOS_AUDIO_TONE): 100 ms @ 1 kHz beep every 3 s
 *   - DVI Framebuffer (VIDEO_FRAMEBUF_BASE): 1 px border + 20x15 grid +
 *     bouncing 32x32 XOR box (~60 px/s) scanned out by Core 1
 *   - DVI Text Overlay (VIDEO_TEXT_BUF_BASE): bouncing "Oasis32" string at
 *     character granularity starting from top-right, OR-composited by Core 1
 *   - Hardware Sprites (SPRITE_OAM / SPRITE_PAT): all 16 16x16 'R' sprites
 *     starting at y=232 and bouncing in [4..460] at 1x/2x/4x speeds so all 16
 *     periodically reconverge on one scanline!
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"

#define DEMO_LED_INTERVAL_US        1000000
#define DEMO_PIEZO_PERIOD_US        3000000
#define DEMO_PIEZO_DURATION_US      100000
#define DEMO_PIEZO_FREQ_HZ          1000
#define DEMO_VIDEO_STEP_US          16667   /* ~60 px/s (1 px per 60 Hz frame) */
#define DEMO_TEXT_STEP_US           125000  /* 8 cells/s (64 px/s) */

#define DEMO_BOX_SIZE_PX            32
#define DEMO_BOX_MIN_X              1
#define DEMO_BOX_MAX_X              (VIDEO_WIDTH - 1 - DEMO_BOX_SIZE_PX)
#define DEMO_BOX_MIN_Y              1
#define DEMO_BOX_MAX_Y              (VIDEO_HEIGHT - 1 - DEMO_BOX_SIZE_PX)

#define DEMO_TEXT_LEN               7       /* "Oasis32" */
#define DEMO_TEXT_MIN_COL           1
#define DEMO_TEXT_MAX_COL           (VIDEO_TEXT_COLS - 1 - DEMO_TEXT_LEN)
#define DEMO_TEXT_MIN_ROW           1
#define DEMO_TEXT_MAX_ROW           (VIDEO_TEXT_ROWS - 2)

#define DEMO_SPR_COUNT              SPRITE_OAM_COUNT    /* All 16 sprites */
#define DEMO_SPR_START_Y            232                 /* Exact center */
#define DEMO_SPR_MIN_Y              4                   /* 232 - 228 (div by 4) */
#define DEMO_SPR_MAX_Y              460                 /* 232 + 228 (div by 4) */

/* Local stack-frame slots for text & 32-sprite state (16-byte-aligned 112 B) */
#define STK_TEXT_NEXT_US            0
#define STK_TEXT_COL                4
#define STK_TEXT_ROW                8
#define STK_TEXT_DCOL               12
#define STK_TEXT_DROW               16
#define STK_SPR_DY                  20      /* 32 signed int8_t vertical velocities */

/* Assemble-time 16-pixel ASCII-art sprite row encoders (char 0 -> bit 0 LSB):
 *   '#' = opaque white (pixel=1, mask=1)
 *   'o' = opaque black (pixel=0, mask=1)
 *   '.' = transparent  (pixel=0, mask=0) */
.macro spr_pix_row str
    .set _s_val, 0
    .set _s_bit, 1
    .irpc _c, "\str"
        .ifc "\_c", "#"
            .set _s_val, _s_val | _s_bit
        .endif
        .set _s_bit, _s_bit << 1
    .endr
    .hword _s_val
.endm

.macro spr_msk_row str
    .set _s_val, 0
    .set _s_bit, 1
    .irpc _c, "\str"
        .ifc "\_c", "#"
            .set _s_val, _s_val | _s_bit
        .endif
        .ifc "\_c", "o"
            .set _s_val, _s_val | _s_bit
        .endif
        .set _s_bit, _s_bit << 1
    .endr
    .hword _s_val
.endm

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * hardware_demo(): Non-blocking cooperative demo loop called from bios_main
 *   s0  = scratch / received byte / current now_us snapshot
 *   s1  = next_led_us    (32-bit low microsecond deadline)
 *   s2  = active LED idx (0=Red, 1=Green, 2=Blue)
 *   s3  = next_piezo_us  (next 3 s beep start deadline)
 *   s4  = piezo_stop_us  (100 ms stop deadline while active)
 *   s5  = piezo_active   (0=silent, 1=beeping)
 *   s6  = next_video_us  (16,667 us bouncing box & sprite step deadline)
 *   s7  = box_x          (1..607)
 *   s8  = box_y          (1..447)
 *   s9  = box_dx         (+1 or -1)
 *   s10 = box_dy         (+1 or -1)
 *   sp+0..29 = bouncing text & 6-sprite demo state
 * ---------------------------------------------------------------------------- */
.global hardware_demo
.type hardware_demo, @function
hardware_demo:
    addi    sp, sp, -112
    sw      ra, 108(sp)
    sw      s0, 104(sp)
    sw      s1, 100(sp)
    sw      s2, 96(sp)
    sw      s3, 92(sp)
    sw      s4, 88(sp)
    sw      s5, 84(sp)
    sw      s6, 80(sp)
    sw      s7, 76(sp)
    sw      s8, 72(sp)
    sw      s9, 68(sp)
    sw      s10, 64(sp)

    la      a0, str_splash
    call    demo_puts

    /* Draw static 1 px outer border + 20x15 (32x32) grid and initial XOR box */
    call    demo_fb_draw_grid_and_border
    li      s7, 16                      /* box_x = 16 */
    li      s8, 16                      /* box_y = 16 */
    li      s9, 1                       /* box_dx = +1 */
    li      s10, 1                      /* box_dy = +1 */
    mv      a0, s7
    mv      a1, s8
    call    demo_fb_xor_box

    /* Tile the full 256-glyph CP437 font table in 16x16 blocks across 80x60
     * VIDEO_TEXT_BUF_BASE (5 wide x 3.75 tall): glyph = ((row & 15) << 4) | (col & 15).
     * Bouncing "Oasis32" clears cells to 0x00 as it passes over them. */
    li      t0, VIDEO_TEXT_BUF_BASE
    li      t1, 0                       /* row = 0..59 */
    li      t2, VIDEO_TEXT_ROWS
    li      t3, VIDEO_TEXT_COLS
1:
    andi    t4, t1, 15
    slli    t4, t4, 4                   /* row_hi = (row & 15) << 4 */
    li      t5, 0                       /* col = 0..79 */
2:
    andi    t6, t5, 15
    or      t6, t4, t6                  /* glyph = ((row & 15) << 4) | (col & 15) */
    sb      t6, 0(t0)
    addi    t0, t0, 1
    addi    t5, t5, 1
    bltu    t5, t3, 2b
    addi    t1, t1, 1
    bltu    t1, t2, 1b

    /* Place initial "Oasis32" text overlay at top-right corner (col=72, row=1) */
    li      t0, DEMO_TEXT_MAX_COL
    sw      t0, STK_TEXT_COL(sp)
    li      t1, DEMO_TEXT_MIN_ROW
    sw      t1, STK_TEXT_ROW(sp)
    li      t2, -1
    sw      t2, STK_TEXT_DCOL(sp)
    li      t2, 1
    sw      t2, STK_TEXT_DROW(sp)
    mv      a0, t0
    mv      a1, t1
    la      a2, str_bounce_text
    call    demo_text_write

    /* Initialize 16x16 'R' pattern (pat 0) and all 32 harmonic test sprites */
    addi    a0, sp, STK_SPR_DY
    call    demo_sprites_init

    /* Snapshot initial timestamp */
    li      a7, BIOS_TIME_US
    ecall
    mv      s0, a0                      /* s0 = now_us */

    /* Start on LED_RED (0) and schedule first step in 1 second */
    li      s2, LED_RED
    mv      a0, s2
    li      a1, 1
    li      a7, BIOS_LED_WRITE
    ecall
    li      t0, DEMO_LED_INTERVAL_US
    add     s1, s0, t0                  /* s1 = next_led_us */

    /* Trigger initial 100 ms @ 1 kHz beep on boot, then repeat every 3 s */
    li      a0, DEMO_PIEZO_FREQ_HZ
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 1
    li      t0, DEMO_PIEZO_DURATION_US
    add     s4, s0, t0                  /* s4 = piezo_stop_us */
    li      t0, DEMO_PIEZO_PERIOD_US
    add     s3, s0, t0                  /* s3 = next_piezo_us */

    /* Schedule first bouncing-box step (16.67 ms) and text step (125 ms) */
    li      t0, DEMO_VIDEO_STEP_US
    add     s6, s0, t0                  /* s6 = next_video_us */
    li      t0, DEMO_TEXT_STEP_US
    add     t0, s0, t0
    sw      t0, STK_TEXT_NEXT_US(sp)

demo_loop:
    /* 1. Non-blocking serial echo (BIOS_SERIAL_TRY_READ) */
    li      a7, BIOS_SERIAL_TRY_READ
    ecall
    bltz    a0, check_timers            /* ERR_EMPTY (-3) -> no byte waiting */

    mv      s0, a0                      /* Save received byte */
    la      a0, str_rx_prefix
    call    demo_puts
    mv      a0, s0
    call    demo_print_u8_dec
    la      a0, str_hex_sep
    call    demo_puts
    mv      a0, s0
    call    demo_print_u8_hex
    la      a0, str_bin_sep
    call    demo_puts
    mv      a0, s0
    call    demo_print_u8_bin
    la      a0, str_crlf
    call    demo_puts

check_timers:
    /* Snapshot current monotonic timestamp once per iteration */
    li      a7, BIOS_TIME_US
    ecall
    mv      s0, a0                      /* s0 = now_us */

    /* 2. Non-blocking 1-second LED cycle (BIOS_LED_WRITE) */
    sub     t0, s0, s1                  /* Wrap-safe signed delta */
    bltz    t0, check_piezo

    mv      a0, s2
    li      a1, 0
    li      a7, BIOS_LED_WRITE
    ecall

    addi    s2, s2, 1
    li      t0, LED_COUNT
    bltu    s2, t0, 1f
    li      s2, LED_RED
1:
    mv      a0, s2
    li      a1, 1
    li      a7, BIOS_LED_WRITE
    ecall

    li      t0, DEMO_LED_INTERVAL_US
    add     s1, s1, t0

check_piezo:
    /* 3. Non-blocking 100 ms @ 1 kHz beep every 3 s (BIOS_AUDIO_TONE) */
    beqz    s5, check_piezo_start

    sub     t0, s0, s4                  /* Active: wait for stop deadline */
    bltz    t0, check_video
    li      a0, AUDIO_FREQ_OFF
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 0
    j       check_video

check_piezo_start:
    sub     t0, s0, s3                  /* Silent: wait for next 3 s period */
    bltz    t0, check_video
    li      a0, DEMO_PIEZO_FREQ_HZ
    li      a7, BIOS_AUDIO_TONE
    ecall
    li      s5, 1
    li      t0, DEMO_PIEZO_DURATION_US
    add     s4, s0, t0
    li      t0, DEMO_PIEZO_PERIOD_US
    add     s3, s3, t0

check_video:
    /* 4. Non-blocking ~60 px/s bouncing 32x32 XOR box on VIDEO_FRAMEBUF_BASE */
    sub     t0, s0, s6
    bltz    t0, check_text

    /* Erase old box */
    mv      a0, s7
    mv      a1, s8
    call    demo_fb_xor_box

    /* Bounce X in [DEMO_BOX_MIN_X, DEMO_BOX_MAX_X] */
    blez    s9, 1f
    li      t0, DEMO_BOX_MAX_X
    blt     s7, t0, 2f
    neg     s9, s9
    j       2f
1:
    li      t0, DEMO_BOX_MIN_X
    bgt     s7, t0, 2f
    neg     s9, s9
2:
    add     s7, s7, s9

    /* Bounce Y in [DEMO_BOX_MIN_Y, DEMO_BOX_MAX_Y] */
    blez    s10, 3f
    li      t0, DEMO_BOX_MAX_Y
    blt     s8, t0, 4f
    neg     s10, s10
    j       4f
3:
    li      t0, DEMO_BOX_MIN_Y
    bgt     s8, t0, 4f
    neg     s10, s10
4:
    add     s8, s8, s10

    /* Draw new box, step the 6 bouncing sprites, and advance deadline */
    mv      a0, s7
    mv      a1, s8
    call    demo_fb_xor_box

    addi    a0, sp, STK_SPR_DY
    call    demo_sprites_step

    li      t0, DEMO_VIDEO_STEP_US
    add     s6, s6, t0

check_text:
    /* 5. Non-blocking bouncing "Oasis32" text overlay on VIDEO_TEXT_BUF_BASE */
    lw      t1, STK_TEXT_NEXT_US(sp)
    sub     t0, s0, t1
    bltz    t0, demo_loop

    /* Erase old string with transparent 0x00 cells */
    lw      a0, STK_TEXT_COL(sp)
    lw      a1, STK_TEXT_ROW(sp)
    li      a2, DEMO_TEXT_LEN
    call    demo_text_clear

    /* Bounce column in [DEMO_TEXT_MIN_COL, DEMO_TEXT_MAX_COL] */
    lw      t2, STK_TEXT_COL(sp)
    lw      t3, STK_TEXT_DCOL(sp)
    blez    t3, 5f
    li      t4, DEMO_TEXT_MAX_COL
    blt     t2, t4, 6f
    neg     t3, t3
    j       6f
5:
    li      t4, DEMO_TEXT_MIN_COL
    bgt     t2, t4, 6f
    neg     t3, t3
6:
    add     t2, t2, t3
    sw      t2, STK_TEXT_COL(sp)
    sw      t3, STK_TEXT_DCOL(sp)

    /* Bounce row in [DEMO_TEXT_MIN_ROW, DEMO_TEXT_MAX_ROW] */
    lw      t2, STK_TEXT_ROW(sp)
    lw      t3, STK_TEXT_DROW(sp)
    blez    t3, 7f
    li      t4, DEMO_TEXT_MAX_ROW
    blt     t2, t4, 8f
    neg     t3, t3
    j       8f
7:
    li      t4, DEMO_TEXT_MIN_ROW
    bgt     t2, t4, 8f
    neg     t3, t3
8:
    add     t2, t2, t3
    sw      t2, STK_TEXT_ROW(sp)
    sw      t3, STK_TEXT_DROW(sp)

    /* Draw "Oasis32" at new (col, row) and advance deadline */
    lw      a0, STK_TEXT_COL(sp)
    lw      a1, STK_TEXT_ROW(sp)
    la      a2, str_bounce_text
    call    demo_text_write

    lw      t1, STK_TEXT_NEXT_US(sp)
    li      t0, DEMO_TEXT_STEP_US
    add     t1, t1, t0
    sw      t1, STK_TEXT_NEXT_US(sp)
    j       demo_loop
.size hardware_demo, . - hardware_demo

/* ----------------------------------------------------------------------------
 * demo_text_write(a0 = col, a1 = row, a2 = NUL-terminated string):
 *   Writes string bytes into 80x60 VIDEO_TEXT_BUF_BASE at (col, row).
 * ---------------------------------------------------------------------------- */
.type demo_text_write, @function
demo_text_write:
    li      t0, VIDEO_TEXT_COLS
    mul     t0, a1, t0
    add     t0, t0, a0
    li      t1, VIDEO_TEXT_BUF_BASE
    add     t0, t1, t0
1:
    lbu     t2, 0(a2)
    beqz    t2, 2f
    sb      t2, 0(t0)
    addi    a2, a2, 1
    addi    t0, t0, 1
    j       1b
2:
    ret
.size demo_text_write, . - demo_text_write

/* ----------------------------------------------------------------------------
 * demo_text_clear(a0 = col, a1 = row, a2 = count):
 *   Writes `count` transparent 0x00 cells into VIDEO_TEXT_BUF_BASE at (col, row).
 * ---------------------------------------------------------------------------- */
.type demo_text_clear, @function
demo_text_clear:
    li      t0, VIDEO_TEXT_COLS
    mul     t0, a1, t0
    add     t0, t0, a0
    li      t1, VIDEO_TEXT_BUF_BASE
    add     t0, t1, t0
1:
    beqz    a2, 2f
    sb      zero, 0(t0)
    addi    t0, t0, 1
    addi    a2, a2, -1
    j       1b
2:
    ret
.size demo_text_clear, . - demo_text_clear

/* ----------------------------------------------------------------------------
 * demo_sprites_init(a0 = int8_t dy[32] buffer):
 *   Copies the 64-byte 16x16 'R' pattern into VIDEO_SPRITE_PAT_BASE (pat 0),
 *   and initializes all 32 OAM slots evenly across x = 2 + i*20 at y = 232
 *   covering all 24 (behind/front) x (OPAQUE/OR/XOR) x (4 flip) combinations
 *   plus 8 repeats, with harmonic vertical speeds (1x, 2x, 4x, alternating +/-).
 * ---------------------------------------------------------------------------- */
.type demo_sprites_init, @function
demo_sprites_init:
    /* 1. Copy 64-byte 'R' pattern (16 words) -> VIDEO_SPRITE_PAT_BASE */
    la      t0, demo_spr_pat_r
    li      t1, VIDEO_SPRITE_PAT_BASE
    li      t2, VIDEO_SPRITE_PAT_BASE + SPRITE_PAT_STRIDE
1:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    bltu    t1, t2, 1b

    /* 2. Populate DEMO_SPR_COUNT OAM slots evenly spaced across 640 px */
    li      t0, VIDEO_SPRITE_OAM_BASE
    li      t1, 0                       /* i = 0..DEMO_SPR_COUNT-1 */
    li      t2, 12                      /* x = 12, 52, 92, ..., 612 */
    li      t6, 0                       /* speed_idx = 0 (1x), 1 (2x), 2 (4x) */
2:
    /* Store x (t2) and starting center y = 232 */
    sh      t2, SPRITE_OAM_OFF_X(t0)
    li      t3, DEMO_SPR_START_Y
    sh      t3, SPRITE_OAM_OFF_Y(t0)
    sb      zero, SPRITE_OAM_OFF_PAT(t0)

    /* combo = (i < 24) ? i : (i - 24) */
    mv      t3, t1
    li      t4, 24
    bltu    t3, t4, 3f
    addi    t3, t3, -24
3:
    /* flags = ENABLE | (behind << 3) | (blend << 4) | (flip << 1) */
    li      t5, SPRITE_FLAG_ENABLE
    li      t4, 12
    bltu    t3, t4, 4f
    addi    t3, t3, -12
    ori     t5, t5, SPRITE_FLAG_BEHIND_TEXT
4:
    srli    t4, t3, 2                   /* blend = 0, 1, or 2 */
    slli    t4, t4, SPRITE_BLEND_SHIFT
    or      t5, t5, t4
    andi    t4, t3, 3                   /* flip = 0..3 -> bits [2:1] */
    slli    t4, t4, 1
    or      t5, t5, t4
    sb      t5, SPRITE_OAM_OFF_FLAGS(t0)
    sh      zero, 6(t0)                 /* reserved = 0 */

    /* Harmonic velocity: 1 << speed_idx -> {1, 2, 4}, negated on odd i */
    li      t3, 1
    sll     t3, t3, t6
    andi    t4, t1, 1
    beqz    t4, 5f
    neg     t3, t3
5:
    sb      t3, 0(a0)

    /* Advance speed_idx = (speed_idx + 1) % 3 */
    addi    t6, t6, 1
    li      t4, 3
    bltu    t6, t4, 6f
    li      t6, 0
6:
    addi    t0, t0, SPRITE_OAM_STRIDE
    addi    a0, a0, 1
    addi    t2, t2, 40
    addi    t1, t1, 1
    li      t4, DEMO_SPR_COUNT
    bltu    t1, t4, 2b
    ret
.size demo_sprites_init, . - demo_sprites_init

/* ----------------------------------------------------------------------------
 * demo_sprites_step(a0 = int8_t dy[32]):
 *   Steps all 32 OAM slots vertically at 1x/2x/4x speeds within [4..460].
 *   Because 228 is divisible by 1, 2, and 4, all 32 reconverge at y = 232
 *   every 456 frames (~7.6 s), exercising the full 32-sprite scanline peak.
 * ---------------------------------------------------------------------------- */
.type demo_sprites_step, @function
demo_sprites_step:
    li      t0, VIDEO_SPRITE_OAM_BASE
    li      t1, DEMO_SPR_COUNT
    li      t5, DEMO_SPR_MIN_Y
    li      t6, DEMO_SPR_MAX_Y
1:
    lh      t2, SPRITE_OAM_OFF_Y(t0)    /* current y */
    lb      t3, 0(a0)                   /* signed dy (+/-1, +/-2, +/-4) */
    add     t2, t2, t3
    bgt     t2, t5, 2f
    mv      t2, t5
    neg     t3, t3
    j       3f
2:
    blt     t2, t6, 3f
    mv      t2, t6
    neg     t3, t3
3:
    sh      t2, SPRITE_OAM_OFF_Y(t0)
    sb      t3, 0(a0)
    addi    t0, t0, SPRITE_OAM_STRIDE
    addi    a0, a0, 1
    addi    t1, t1, -1
    bnez    t1, 1b
    ret
.size demo_sprites_step, . - demo_sprites_step

/* ----------------------------------------------------------------------------
 * demo_fb_draw_grid_and_border:
 *   Draws 1-pixel outer border (0,0)-(639,479) and word-aligned 20x15 grid
 *   of 32x32-pixel cells into VIDEO_FRAMEBUF_BASE (38,400 bytes).
 * ---------------------------------------------------------------------------- */
.type demo_fb_draw_grid_and_border, @function
demo_fb_draw_grid_and_border:
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, 0                       /* y = 0..479 */
    li      t2, VIDEO_HEIGHT
    li      t3, (VIDEO_HEIGHT - 1)      /* y = 479 */
    li      t4, 0x80000000              /* Rightmost pixel bit (x = 639) */
1:
    andi    t5, t1, 31
    beqz    t5, 2f
    beq     t1, t3, 2f
    li      t5, 0x00000001              /* Vertical grid line on bit 0 */
    j       3f
2:
    li      t5, -1                      /* 0xFFFFFFFF horizontal line */
3:
    li      t6, 0                       /* w = 0..19 */
    li      a0, (VIDEO_STRIDE_WORDS - 1)
    li      a2, VIDEO_STRIDE_WORDS
4:
    mv      a1, t5
    bne     t6, a0, 5f
    or      a1, a1, t4                  /* Right outer border at w == 19 */
5:
    sw      a1, 0(t0)
    addi    t0, t0, 4
    addi    t6, t6, 1
    bltu    t6, a2, 4b

    addi    t1, t1, 1
    bltu    t1, t2, 1b
    ret
.size demo_fb_draw_grid_and_border, . - demo_fb_draw_grid_and_border

/* ----------------------------------------------------------------------------
 * demo_fb_xor_box(a0 = x, a1 = y):
 *   XORs a 32x32-pixel solid square at (x, y) in VIDEO_FRAMEBUF_BASE.
 *   Each row spans at most two adjacent 32-bit words.
 * ---------------------------------------------------------------------------- */
.type demo_fb_xor_box, @function
demo_fb_xor_box:
    srli    t0, a0, 5                   /* word_idx = x >> 5 */
    andi    t1, a0, 31                  /* bit_shift = x & 31 */
    li      t2, -1
    sll     t3, t2, t1                  /* mask_lo = 0xFFFFFFFF << bit_shift */
    li      t4, 0                       /* mask_hi = 0 if bit_shift == 0 */
    beqz    t1, 1f
    li      t5, 32
    sub     t5, t5, t1
    srl     t4, t2, t5                  /* mask_hi = 0xFFFFFFFF >> (32 - shift) */
1:
    /* row_ptr = VIDEO_FRAMEBUF_BASE + y * 80 + word_idx * 4 */
    li      t5, VIDEO_STRIDE_BYTES
    mul     t5, a1, t5
    slli    t0, t0, 2
    add     t5, t5, t0
    li      t0, VIDEO_FRAMEBUF_BASE
    add     t0, t0, t5

    li      t1, DEMO_BOX_SIZE_PX        /* 32 rows */
2:
    lw      t5, 0(t0)
    xor     t5, t5, t3
    sw      t5, 0(t0)
    beqz    t4, 3f
    lw      t5, 4(t0)
    xor     t5, t5, t4
    sw      t5, 4(t0)
3:
    addi    t0, t0, VIDEO_STRIDE_BYTES
    addi    t1, t1, -1
    bnez    t1, 2b
    ret
.size demo_fb_xor_box, . - demo_fb_xor_box

/* ----------------------------------------------------------------------------
 * demo_putc(a0 = byte): Transmit one byte via BIOS_SERIAL_WRITE ecall
 * ---------------------------------------------------------------------------- */
.type demo_putc, @function
demo_putc:
    li      a7, BIOS_SERIAL_WRITE
    ecall
    ret
.size demo_putc, . - demo_putc

/* ----------------------------------------------------------------------------
 * demo_puts(a0 = NUL-terminated string): Print string via BIOS_SERIAL_WRITE
 * ---------------------------------------------------------------------------- */
.type demo_puts, @function
demo_puts:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0
1:
    lbu     a0, 0(s0)
    beqz    a0, 2f
    li      a7, BIOS_SERIAL_WRITE
    ecall
    addi    s0, s0, 1
    j       1b
2:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_puts, . - demo_puts

/* ----------------------------------------------------------------------------
 * demo_print_u8_dec(a0 = 0..255): Prints unsigned byte in base 10
 * ---------------------------------------------------------------------------- */
.type demo_print_u8_dec, @function
demo_print_u8_dec:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)

    mv      s0, a0                      /* Remaining value */
    li      s1, 0                       /* Printed-digit flag */

    /* Hundreds digit */
    li      t0, 100
    divu    t1, s0, t0
    beqz    t1, 1f
    addi    a0, t1, '0'
    call    demo_putc
    li      t0, 100
    remu    s0, s0, t0
    li      s1, 1
1:
    /* Tens digit */
    li      t0, 10
    divu    t1, s0, t0
    bnez    t1, 2f
    beqz    s1, 3f                      /* Skip leading zero */
2:
    addi    a0, t1, '0'
    call    demo_putc
    li      t0, 10
    remu    s0, s0, t0
3:
    /* Ones digit (always printed) */
    addi    a0, s0, '0'
    call    demo_putc

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_print_u8_dec, . - demo_print_u8_dec

/* ----------------------------------------------------------------------------
 * demo_print_u8_hex(a0 = 0..255): Prints two uppercase hex digits
 * ---------------------------------------------------------------------------- */
.type demo_print_u8_hex, @function
demo_print_u8_hex:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    mv      s0, a0

    srli    a0, s0, 4
    andi    a0, a0, 0x0F
    call    demo_print_hex_nibble

    andi    a0, s0, 0x0F
    call    demo_print_hex_nibble

    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_print_u8_hex, . - demo_print_u8_hex

.type demo_print_hex_nibble, @function
demo_print_hex_nibble:
    li      t0, 10
    bltu    a0, t0, 1f
    addi    a0, a0, ('A' - 10)
    j       demo_putc
1:
    addi    a0, a0, '0'
    j       demo_putc
.size demo_print_hex_nibble, . - demo_print_hex_nibble

/* ----------------------------------------------------------------------------
 * demo_print_u8_bin(a0 = 0..255): Prints 8 binary digits MSB -> LSB
 * ---------------------------------------------------------------------------- */
.type demo_print_u8_bin, @function
demo_print_u8_bin:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)
    mv      s0, a0
    li      s1, 7
1:
    srl     a0, s0, s1
    andi    a0, a0, 1
    addi    a0, a0, '0'
    call    demo_putc
    addi    s1, s1, -1
    bgez    s1, 1b

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size demo_print_u8_bin, . - demo_print_u8_bin

/* ============================================================================
 * Read-Only Strings (.rodata in XIP Flash)
 * ============================================================================ */
.section .rodata, "a"
str_splash:
    .asciz "\r\n========================================\r\n  Oasis32 System ROM (BIOS) v0.1\r\n  Hardware Demo (UART0 + TIMER0 + LEDs + Piezo + DVI/Text/16 Sprites)\r\n========================================\r\nReady. LEDs 1/s, Piezo 1kHz/3s, DVI + Text + 16 Sprites; type to echo:\r\n"
str_bounce_text:
    .asciz "Oasis32"

/* Single source of truth for the 16x16 asymmetric capital 'R' sprite:
 *   '#' = white outline (pixel=1, mask=1)
 *   'o' = opaque black interior (pixel=0, mask=1)
 *   '.' = transparent exterior & counter (pixel=0, mask=0) */
.macro demo_r_sprite_rows row_macro
    \row_macro ".############..."
    \row_macro ".#oooooooooo##.."
    \row_macro ".#ooooooooooo##."
    \row_macro ".#ooo#####oooo#."
    \row_macro ".#ooo#...#oooo#."
    \row_macro ".#ooo#...#oooo#."
    \row_macro ".#ooo#####oooo#."
    \row_macro ".#ooooooooooo##."
    \row_macro ".#oooooooooo##.."
    \row_macro ".#ooo####ooo#..."
    \row_macro ".#ooo#..##ooo#.."
    \row_macro ".#ooo#...##ooo#."
    \row_macro ".#ooo#....##ooo#"
    \row_macro ".#ooo#.....##oo#"
    \row_macro ".#ooo#......##o#"
    \row_macro ".#####.......###"
.endm

.p2align 2
demo_spr_pat_r:
    /* Bytes 0..31: Pixel Plane (16 x uint16_t) */
    demo_r_sprite_rows spr_pix_row
    /* Bytes 32..63: Mask Plane (16 x uint16_t) */
    demo_r_sprite_rows spr_msk_row
str_rx_prefix:
    .asciz "Serial character received: dec="
str_hex_sep:
    .asciz " hex=0x"
str_bin_sep:
    .asciz " bin=0b"
str_crlf:
    .asciz "\r\n"
