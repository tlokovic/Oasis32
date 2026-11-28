/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Core 1 Video Coprocessor (HSTX 640x480 @ 60 Hz 1 bpp)
 * ============================================================================
 * Launches RP2350 Core 1 as Oasis32's dedicated, hidden Video Coprocessor:
 *   - Core 0 (`video_init`): clears public FRAMEBUF (0x20072000, 38,400 B),
 *     wakes Core 1 via the Boot ROM SIO FIFO handshake (rp2350-datasheet.pdf
 *     §5.3, pp. 345-347), and waits for Core 1's ready acknowledgement.
 *   - Core 1 (`core1_video_entry`): owns Scratchpad Bank 9 (0x20081000-1FFF),
 *     HSTX (GP12-GP19), and ping-pong DMA channels 0 & 1 (DREQ_HSTX = 52).
 *     Streams 640x480 @ 60 Hz DVI by copying each active scanline from
 *     VIDEO_FRAMEBUF_BASE into the inactive Bank 9 ping-pong line buffer
 *     (BIOS_CORE1_LINE_A / BIOS_CORE1_LINE_B) while DMA streams the active
 *     line buffer to HSTX_FIFO. Increments BIOS_VSYNC_COUNT_ADDR once per
 *     frame at the start of VBLANK.
 *
 * Scope (Phase 3b — Full Video Coprocessor: Bitmap + Text/Attr + Sprites):
 *   - 4-layer scanline compositing in Bank 9 ping-pong line buffers:
 *       1. FRAMEBUF (640x480 1 bpp)
 *       2. Behind-text sprites (BEHIND_TEXT=1, OAM Slot 15 -> Slot 0)
 *       3. TEXT_BUF / FONT_RAM (80x60 OR-composited 8x8 CP437 glyphs) +
 *          TEXT_ATTR per-cell reverse (^ 0xFF) + hardware cursor (^ 0xFF)
 *       4. In-front sprites (BEHIND_TEXT=0, OAM Slot 15 -> Slot 0)
 *   - VBLANK frame-latching of SPRITE_OAM into BIOS_CORE1_OAM_LATCH when
 *     VIDEO_CTRL.LATCH_OAM (bit 0) is set, or live beam-racing when clear.
 *
 * Primary References:
 *   - docs/VideoArchitecture.md §2, §4
 *   - docs/MemoryMap.md §2.1-§2.3
 *   - rp2350-datasheet.pdf §3.1.4 (SIO FIFO), §3.8.6.3 (h3.unblock),
 *     §5.3 (Launching Core 1), §12.6.10 (DMA), §12.11.7 (HSTX)
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/devices.h"
#include "hw/rp2350_regs.h"
#include "hw/oasis32_pins.h"
#include "bios_config.h"
#include "bios_ram.h"

/* Scratchpad Bank 9 HSTX DMA command list & sprite-list offsets
 * (base = BIOS_CORE1_CMD_LIST = 0x200810A0, 352 bytes available) */
#define CMD_VBLANK_OFF_OFF          0x00    /* 6 words (24 B) */
#define CMD_VBLANK_ON_OFF           0x18    /* 6 words (24 B) */
#define CMD_VACTIVE_PRE_OFF         0x30    /* 7 words (28 B) */
#define CMD_BEHIND_LIST_OFF         0x50    /* 17 B: enabled BEHIND_TEXT=1 slot offs + 0xFF */
#define CMD_FRONT_LIST_OFF          0x74    /* 17 B: enabled BEHIND_TEXT=0 slot offs + 0xFF */
#define CMD_CURSOR_ROW_OFF          0x88    /* int32_t active text row (0..59) or -1 */
#define CMD_CURSOR_COL_OFF          0x8C    /* uint32_t active text col (0..79) */
#define CMD_CURSOR_PHASE_OFF        0x90    /* uint32_t blink phase (0=on, 1=off) */
#define CMD_CURSOR_CNT_OFF          0x94    /* uint32_t blink frame counter */
#define CMD_CURSOR_BG_OFF           0x98    /* uint8_t saved pre-text bg byte at cursor */
#define CMD_LIST_TOTAL_WORDS        19      /* 76 bytes of Flash DMA cmd lists */
#define SPR_LIST_END                0xFF    /* Sentinel terminating Bank 9 sprite lists */

/* Handshake token sent by Core 1 -> Core 0 once HSTX + DMA are running */
#define CORE1_VIDEO_READY_TOKEN     0x56494431  /* "VID1" */

/* Pad clear/set masks for GP12-GP19 DVI pins */
#define PADS_ISO_OD_MASK            (PADS_ISO_BIT | PADS_OD_BIT)

/* Hazard3 Xh3power event signal hint (rp2350-datasheet.pdf §3.8.6.3.2, p. 270) */
.macro h3_unblock
    slt     x0, x0, x1
.endm

.section .text, "ax"

/* ============================================================================
 * Core 0 Entry: video_init()
 *   1. Zero-fills public FRAMEBUF (VIDEO_FRAMEBUF_BASE, 38,400 bytes).
 *   2. Launches Core 1 via the 6-word Boot ROM SIO FIFO protocol:
 *        { 0, 0, 1, core1_trap_halt, BIOS_CORE1_STACK_TOP, core1_video_entry }
 *   3. Waits for Core 1's CORE1_VIDEO_READY_TOKEN over the SIO FIFO.
 * ============================================================================ */
.global video_init
.type video_init, @function
video_init:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)

    /* 1. Clear 640x480 1 bpp public framebuffer to black (0x20072000..0x2007B5FF) */
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + VIDEO_FRAMEBUF_SIZE
1:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b

    /* 1b. Load default CP437 8x8 Flash font into VIDEO_FONT_RAM_BASE (2,048 B),
     *     clear TEXT_BUF, TEXT_ATTR, VIDEO_CTRL, SPRITE_OAM, and SPRITE_PAT, and
     *     enable default frame-latched OAM mode (VIDEO_CTRL.LATCH_OAM = 1). */
    call    font_load_default

    li      t0, VIDEO_TEXT_BUF_BASE
    li      t1, VIDEO_RAM_BASE + VIDEO_RAM_SIZE
2:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 2b

    li      t0, VIDEO_CTRL_BASE
    li      t1, VIDEO_CTRL_LATCH_OAM_BIT
    sw      t1, VIDEO_CTRL_FLAGS_OFF(t0)

    /* 2. Build 6-word Core 1 launch sequence in stack/rodata-free registers.
     *    We store the 6 words on Core 0's stack at 0(sp)..20(sp) — Wait:
     *    our frame has 0(sp)..11(sp) free, so expand? Better: use a small
     *    indexed table in .rodata! (All 6 words are link-time constants.) */
    li      s0, SIO_BASE
    la      s1, core1_launch_seq        /* Pointer to 6-word launch table */
    li      s2, 0                       /* seq = 0..5 */
    li      s3, 6                       /* sequence length */

launch_step:
    slli    t0, s2, 2
    add     t0, s1, t0
    lw      t1, 0(t0)                   /* t1 = cmd = cmd_sequence[seq] */

    /* Before sending 0, drain Core 0 RX FIFO and signal h3.unblock (SEV) */
    bnez    t1, launch_push
drain_rx:
    lw      t2, SIO_FIFO_ST_OFF(s0)
    andi    t2, t2, SIO_FIFO_ST_VLD_BIT
    beqz    t2, drain_done
    lw      zero, SIO_FIFO_RD_OFF(s0)
    j       drain_rx
drain_done:
    h3_unblock

launch_push:
    /* Push cmd blocking (wait for FIFO_ST.RDY == 1) */
    lw      t2, SIO_FIFO_ST_OFF(s0)
    andi    t2, t2, SIO_FIFO_ST_RDY_BIT
    beqz    t2, launch_push
    sw      t1, SIO_FIFO_WR_OFF(s0)
    h3_unblock

launch_pop:
    /* Pop echoed response blocking (wait for FIFO_ST.VLD == 1) */
    lw      t2, SIO_FIFO_ST_OFF(s0)
    andi    t2, t2, SIO_FIFO_ST_VLD_BIT
    beqz    t2, launch_pop
    lw      t3, SIO_FIFO_RD_OFF(s0)

    /* Advance on exact echo; otherwise restart handshake from seq = 0 */
    bne     t3, t1, launch_retry
    addi    s2, s2, 1
    bltu    s2, s3, launch_step
    j       wait_core1_ready

launch_retry:
    li      s2, 0
    j       launch_step

    /* 3. Wait for Core 1 to finish HSTX + DMA bring-up and post ready token */
wait_core1_ready:
    lw      t2, SIO_FIFO_ST_OFF(s0)
    andi    t2, t2, SIO_FIFO_ST_VLD_BIT
    beqz    t2, wait_core1_ready
    lw      t3, SIO_FIFO_RD_OFF(s0)
    li      t4, CORE1_VIDEO_READY_TOKEN
    bne     t3, t4, wait_core1_ready

    lw      s3, 12(sp)
    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size video_init, . - video_init

/* ----------------------------------------------------------------------------
 * video_frame_count() -> a0 = uint32_t monotonic VSYNC frame counter
 * ---------------------------------------------------------------------------- */
.global video_frame_count
.type video_frame_count, @function
video_frame_count:
    li      t0, BIOS_VSYNC_COUNT_ADDR
    lw      a0, 0(t0)
    ret
.size video_frame_count, . - video_frame_count

/* ----------------------------------------------------------------------------
 * video_wait_vsync() -> a0 = uint32_t new VSYNC frame counter (blocks ~<=16.7ms)
 * ---------------------------------------------------------------------------- */
.global video_wait_vsync
.type video_wait_vsync, @function
video_wait_vsync:
    li      t0, BIOS_VSYNC_COUNT_ADDR
    lw      t1, 0(t0)
1:
    lw      a0, 0(t0)
    beq     a0, t1, 1b
    ret
.size video_wait_vsync, . - video_wait_vsync


/* ============================================================================
 * Core 1 Entry: core1_video_entry()
 *   Entered from RP2350 Boot ROM with sp = BIOS_CORE1_STACK_TOP (0x20082000)
 *   and mtvec = core1_trap_halt. Never returns.
 *
 * Register Allocation in Steady-State Scanline Loop (zero RAM state overhead):
 *   s0 = DMA_BASE (0x50000000)
 *   s1 = dma_pong_next          (0 = waiting on CH0, 1 = waiting on CH1)
 *   s2 = v_scanline             (0..524; next scanline to queue)
 *   s3 = vactive_cmdlist_posted (0 = queue prefix + compose line, 1 = queue pixels)
 *   s4 = active_line_buf        (BIOS_CORE1_LINE_A or BIOS_CORE1_LINE_B)
 *   s5 = BIOS_CORE1_CMD_LIST    (0x200810A0: base of Bank 9 HSTX cmd lists)
 *   s6 = VIDEO_FRAMEBUF_BASE    (0x20072000)
 *   s7 = BIOS_VSYNC_COUNT_ADDR  (0x50100500)
 *   s8  = VIDEO_FONT_RAM_BASE   (0x2007B600)
 *   s9  = VIDEO_TEXT_BUF_BASE   (0x2007BE00)
 *   s10 = active_oam_base       (BIOS_CORE1_OAM_LATCH or VIDEO_SPRITE_OAM_BASE)
 *   s11 = VIDEO_SPRITE_PAT_BASE (0x2007E440)
 * ============================================================================ */
.p2align 2
.type core1_video_entry, @function
core1_video_entry:
    /* 1. Copy HSTX DMA command lists (19 words) from Flash into Bank 9 SRAM
     *    (BIOS_CORE1_CMD_LIST = 0x200810A0) so all DMA reads are 0-wait-state. */
    la      t0, hstx_cmd_lists_flash
    li      t1, BIOS_CORE1_CMD_LIST
    li      t2, CMD_LIST_TOTAL_WORDS
1:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t2, t2, -1
    bnez    t2, 1b

    /* 2. Configure HSTX TMDS 1 bpp expander and Adafruit DVI Sock crossbar */
    li      t0, HSTX_CTRL_BASE
    sw      zero, HSTX_CSR_OFF(t0)      /* Disable HSTX during setup */

    li      t1, CFG_HSTX_EXPAND_TMDS_1BPP
    sw      t1, HSTX_EXPAND_TMDS_OFF(t0)
    li      t1, CFG_HSTX_EXPAND_SHIFT_1BPP
    sw      t1, HSTX_EXPAND_SHIFT_OFF(t0)

    li      t1, HSTX_LANE0_P
    sw      t1, HSTX_BIT0_OFF(t0)
    li      t1, HSTX_LANE0_N
    sw      t1, HSTX_BIT1_OFF(t0)
    li      t1, HSTX_CLK_P
    sw      t1, HSTX_BIT2_OFF(t0)
    li      t1, HSTX_CLK_N
    sw      t1, HSTX_BIT3_OFF(t0)
    li      t1, HSTX_LANE2_P
    sw      t1, HSTX_BIT4_OFF(t0)
    li      t1, HSTX_LANE2_N
    sw      t1, HSTX_BIT5_OFF(t0)
    li      t1, HSTX_LANE1_P
    sw      t1, HSTX_BIT6_OFF(t0)
    li      t1, HSTX_LANE1_N
    sw      t1, HSTX_BIT7_OFF(t0)

    /* 3. Mux GP12-GP19 to HSTX (FUNCSEL=0), clear ISO & OD, set 12 mA drive + SLEWFAST
     *    while HSTX_CSR is still disabled so all 4 TMDS differential pairs
     *    start toggling simultaneously on the exact same clock edge. */
    li      t1, IO_BANK0_BASE + IO_DVI_BASE_CTRL_OFF
    li      t2, PADS_BANK0_BASE + ATOMIC_CLR + PADS_DVI_BASE_OFF
    li      t3, PADS_BANK0_BASE + ATOMIC_SET + PADS_DVI_BASE_OFF
    li      t4, 8
    li      t5, PADS_ISO_OD_MASK
    li      t6, (PADS_DRIVE_12MA_BITS | PADS_SLEWFAST_BIT)
2:
    sw      zero, 0(t1)
    sw      t5, 0(t2)
    sw      t6, 0(t3)
    addi    t1, t1, 8
    addi    t2, t2, 4
    addi    t3, t3, 4
    addi    t4, t4, -1
    bnez    t4, 2b

    /* 4. Prioritize DMA reads/writes and Core 1 (PROC1) on the AHB5 crossbar */
    li      t0, BUSCTRL_BASE
    li      t1, BUSCTRL_PRIO_VIDEO
    sw      t1, BUSCTRL_PRIORITY_OFF(t0)

    /* 5. Pre-load DMA CH0 (PING) and CH1 (PONG) with scanlines 0 and 1, and
     *    trigger CH0 BEFORE enabling HSTX so the HSTX FIFO is pre-filled with
     *    valid VBLANK sync symbols before the first TMDS clock edge leaves the pins. */
    li      s0, DMA_BASE
    li      s5, BIOS_CORE1_CMD_LIST
    addi    t1, s5, CMD_VBLANK_OFF_OFF
    li      t2, HSTX_FIFO_DATA
    li      t3, 6

    sw      t1, DMA_CH0_READ_OFF(s0)
    sw      t2, DMA_CH0_WRITE_OFF(s0)
    sw      t3, DMA_CH0_COUNT_OFF(s0)
    li      t4, CFG_DMA_CTRL_PING
    sw      t4, DMA_CH0_AL1_CTRL_OFF(s0)

    sw      t1, DMA_CH1_READ_OFF(s0)
    sw      t2, DMA_CH1_WRITE_OFF(s0)
    sw      t3, DMA_CH1_COUNT_OFF(s0)
    li      t4, CFG_DMA_CTRL_PONG
    sw      t4, DMA_CH1_AL1_CTRL_OFF(s0)

    /* Clear any stale raw DMA_INTR flags for CH0 & CH1 (polled mode: INTE0=0) */
    li      t1, 0x3
    sw      t1, DMA_INTR_OFF(s0)

    /* Zero Bank 9 latched OAM mirror (128 B) and terminate sprite lists */
    li      t0, BIOS_CORE1_OAM_LATCH
    li      t1, BIOS_CORE1_OAM_LATCH + VIDEO_SPRITE_OAM_SIZE
10:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 10b

    li      t0, SPR_LIST_END
    sb      t0, CMD_BEHIND_LIST_OFF(s5)
    sb      t0, CMD_FRONT_LIST_OFF(s5)

    /* Initialize Bank 9 latched hardware text cursor state (hidden) */
    li      t0, -1
    sw      t0, CMD_CURSOR_ROW_OFF(s5)
    sw      zero, CMD_CURSOR_COL_OFF(s5)
    sw      zero, CMD_CURSOR_PHASE_OFF(s5)
    sw      zero, CMD_CURSOR_CNT_OFF(s5)

    /* Initialize steady-state scanline registers */
    li      s1, 0                       /* dma_pong_next = 0 (CH0 finishes first) */
    li      s2, 2                       /* v_scanline = 2 (lines 0 & 1 pre-loaded) */
    li      s3, 0                       /* vactive_cmdlist_posted = 0 */
    li      s4, BIOS_CORE1_LINE_A       /* First active line composes into LINE_A */
    li      s6, VIDEO_FRAMEBUF_BASE
    li      s7, BIOS_VSYNC_COUNT_ADDR
    li      s8, VIDEO_FONT_RAM_BASE
    li      s9, VIDEO_TEXT_BUF_BASE
    li      s10, BIOS_CORE1_OAM_LATCH
    li      s11, VIDEO_SPRITE_PAT_BASE

    /* Start Channel 0 (PING) via MULTI_CHAN_TRIGGER to prime HSTX FIFO */
    li      t1, 0x1
    sw      t1, DMA_MULTI_TRIG_OFF(s0)

    /* 6. Enable HSTX serializer + command expander now that pads are ready
     *    and the HSTX FIFO is primed with VBLANK sync symbols. */
    li      t0, HSTX_CTRL_BASE
    li      t1, CFG_HSTX_CSR_DVI_ENABLE
    sw      t1, HSTX_CSR_OFF(t0)

    /* 7. Signal Core 0 that HSTX DVI output is live */
    li      t0, SIO_BASE
3:
    lw      t1, SIO_FIFO_ST_OFF(t0)
    andi    t1, t1, SIO_FIFO_ST_RDY_BIT
    beqz    t1, 3b
    li      t1, CORE1_VIDEO_READY_TOKEN
    sw      t1, SIO_FIFO_WR_OFF(t0)
    h3_unblock

    /* ========================================================================
     * Core 1 Steady-State Scanline Loop (Polls Raw DMA_INTR for CH0 / CH1)
     * ======================================================================== */
core1_scanline_loop:
    li      t0, 1
    sll     t0, t0, s1                  /* mask = 1 << dma_pong_next */
wait_dma_ch:
    lw      t1, DMA_INTR_OFF(s0)
    and     t1, t1, t0
    beqz    t1, wait_dma_ch

    /* Clear raw DMA_INTR flag for the channel that just finished */
    sw      t0, DMA_INTR_OFF(s0)

    /* Compute completed (now idle) channel register base: DMA_BASE + (ch << 6) */
    slli    t1, s1, 6
    add     t0, s0, t1                  /* t0 = &dma_hw->ch[ch] */
    xori    s1, s1, 1                   /* Toggle dma_pong_next for next wait */

    /* Dispatch by v_scanline:
     *   [0..9]   : VFP (VSYNC off)
     *   [10..11] : VSYNC (VSYNC on)
     *   [12..44] : VBP (VSYNC off)
     *   [45..524]: Active (480 lines, prefix + pixels) */
    li      t2, CFG_MODE_V_FRONT_PORCH
    bltu    s2, t2, line_vblank_off
    li      t2, CFG_MODE_V_SYNC_END
    bltu    s2, t2, line_vblank_on
    li      t2, CFG_MODE_V_BLANK_END
    bltu    s2, t2, line_vblank_off

    /* Active scanline (45..524): alternate prefix (7 w) and pixels (20 w) */
    bnez    s3, line_vactive_pixels

    /* --- Phase A (posted == 0): Queue active-line blanking prefix (7 words) ---
     * The OTHER DMA channel is currently streaming the previous line's 20 pixel
     * words (or line 44's vblank), giving ~3,200 cycles to compose this line
     * into the inactive Bank 9 buffer (s4) before Phase B queues it! */
    addi    t2, s5, CMD_VACTIVE_PRE_OFF
    li      t3, 7
    sw      t2, DMA_CH0_READ_OFF(t0)
    sw      t3, DMA_CH0_COUNT_OFF(t0)
    li      s3, 1                       /* vactive_cmdlist_posted = 1 */

    /* Compose active scanline y = (v_scanline - 45) into Bank 9 buffer s4
     * in 4 deterministic layers (docs/VideoArchitecture.md §5.3):
     *   1. FRAMEBUF (20 words = 80 bytes)
     *   2. Behind-text sprites (BEHIND_TEXT = 1, Slot 15 -> Slot 0)
     *   3. TEXT_BUF / FONT_RAM (OR-composited across 80 columns)
     *   4. In-front sprites (BEHIND_TEXT = 0, Slot 15 -> Slot 0) */
    addi    a5, s2, -CFG_MODE_V_BLANK_END   /* a5 = active_y (0..479) */
    li      t3, VIDEO_STRIDE_BYTES          /* 80 bytes/row */

    /* Layer 1: Copy 20 words from FRAMEBUF[y * 80] -> Bank 9 buffer s4 */
    mul     a0, a5, t3
    add     a0, s6, a0                      /* a0 = &FRAMEBUF[y * 80] */
    mv      a3, s4                          /* a3 = dst Bank 9 buffer */
    addi    a4, s4, VIDEO_STRIDE_BYTES      /* a4 = dst end (+80) */
compose_fb_loop:
    lw      t4, 0(a0)
    sw      t4, 0(a3)
    addi    a0, a0, 4
    addi    a3, a3, 4
    bltu    a3, a4, compose_fb_loop

    /* Layer 2: Behind-text sprites (BEHIND_TEXT = 1, Slot 15 -> Slot 0) */
    mv      a0, a5                          /* y */
    mv      a1, s4                          /* line_buf */
    mv      a2, s10                         /* active_oam_base */
    addi    a3, s5, CMD_BEHIND_LIST_OFF     /* Bank 9 enabled behind-text list */
    call    core1_draw_sprite_list

    /* Layer 3: TEXT_BUF / FONT_RAM + TEXT_ATTR 4-column word-wise compositing:
     *   out = bg | (glyph ^ attr_mask ^ cursor_mask)
     * If the hardware cursor is active on this text row, snapshot its pre-text
     * bg byte so Layer 3b can recomposite that single cell cleanly. */
    srli    t4, a5, 3                       /* text_row = y >> 3 (0..59) */
    lw      t1, CMD_CURSOR_ROW_OFF(s5)      /* latched cursor row or -1 */
    bne     t4, t1, 1f
    lw      t2, CMD_CURSOR_COL_OFF(s5)      /* latched cursor col (0..79) */
    add     t2, s4, t2
    lbu     t2, 0(t2)
    sb      t2, CMD_CURSOR_BG_OFF(s5)
1:
    li      t3, VIDEO_STRIDE_BYTES
    mul     t1, t4, t3                      /* row_off = text_row * 80 */
    add     a1, s9, t1                      /* a1 = &TEXT_BUF[text_row * 80] */
    li      a6, VIDEO_TEXT_ATTR_BASE
    add     a6, a6, t1                      /* a6 = &TEXT_ATTR[text_row * 80] */
    andi    t4, a5, 7                       /* glyph_row = y & 7 (0..7) */
    add     a2, s8, t4                      /* a2 = &FONT_RAM[0 + (y & 7)] */
    mv      a3, s4                          /* a3 = dst Bank 9 buffer */
    addi    a4, s4, VIDEO_STRIDE_BYTES      /* a4 = dst end (+80) */
    li      a7, 0x01010101                  /* bit-0 reverse mask for 4 cells */
    li      a0, 0xFF                        /* SWAR 0x01 -> 0xFF multiplier */
compose_text_word_loop:
    lw      t3, 0(a1)                       /* 4 TEXT_BUF cells [c3|c2|c1|c0] */
    lw      t5, 0(a6)                       /* 4 TEXT_ATTR cells [a3|a2|a1|a0] */
    and     t5, t5, a7                      /* Isolate bit 0 of each attr byte */
    beqz    t3, compose_text_zero_chars     /* Fast path: 4 empty glyph cells */

    andi    t4, t3, 0xFF
    slli    t4, t4, 3
    add     t4, t4, a2
    lbu     t0, 0(t4)                       /* g0 */

    srli    t4, t3, 8
    andi    t4, t4, 0xFF
    slli    t4, t4, 3
    add     t4, t4, a2
    lbu     t4, 0(t4)                       /* g1 */
    slli    t4, t4, 8
    or      t0, t0, t4

    srli    t4, t3, 16
    andi    t4, t4, 0xFF
    slli    t4, t4, 3
    add     t4, t4, a2
    lbu     t4, 0(t4)                       /* g2 */
    slli    t4, t4, 16
    or      t0, t0, t4

    srli    t4, t3, 24
    slli    t4, t4, 3
    add     t4, t4, a2
    lbu     t4, 0(t4)                       /* g3 */
    slli    t4, t4, 24
    or      t0, t0, t4

    mul     t5, t5, a0                      /* Expand 0x01 -> 0xFF per reversed cell */
    xor     t0, t0, t5                      /* Invert reversed glyphs before OR */
    lw      t4, 0(a3)
    or      t4, t4, t0                      /* OR-composite text onto line */
    sw      t4, 0(a3)
compose_text_next4:
    addi    a1, a1, 4
    addi    a6, a6, 4
    addi    a3, a3, 4
    bltu    a3, a4, compose_text_word_loop
    j       compose_text_done

compose_text_zero_chars:
    beqz    t5, compose_text_next4          /* Fast skip: 4 empty & normal cells */
    mul     t5, t5, a0                      /* Expand 0x01 -> 0xFF per reversed cell */
    lw      t4, 0(a3)
    or      t4, t4, t5                      /* OR-composite reversed blank cells */
    sw      t4, 0(a3)
    j       compose_text_next4

compose_text_done:

    /* Layer 3b: Non-destructive hardware text cursor (bg | (glyph ^ attr ^ 0xFF)).
     * Composes via XOR with TEXT_ATTR reverse before ORing onto the saved
     * pre-text bg byte, so cursor/reverse apply only to the text layer. */
    srli    t0, a5, 3                       /* text_row = y >> 3 (0..59) */
    lw      t1, CMD_CURSOR_ROW_OFF(s5)      /* latched cursor row or -1 */
    bne     t0, t1, compose_cursor_done
    lw      t2, CMD_CURSOR_COL_OFF(s5)      /* latched cursor col (0..79) */
    li      t3, VIDEO_STRIDE_BYTES
    mul     t0, t0, t3
    add     t0, t0, t2                      /* cell_idx = text_row * 80 + col */
    add     t1, s9, t0
    lbu     t1, 0(t1)                       /* ch = TEXT_BUF[cell_idx] */
    slli    t1, t1, 3
    add     t1, t1, a2                      /* &FONT_RAM[ch * 8 + (y & 7)] */
    lbu     t1, 0(t1)                       /* glyph_byte */
    li      t3, VIDEO_TEXT_ATTR_BASE
    add     t3, t3, t0
    lbu     t3, 0(t3)                       /* attr = TEXT_ATTR[cell_idx] */
    andi    t3, t3, TEXT_ATTR_REVERSE
    bnez    t3, 2f                          /* attr=1 ^ cursor=1 -> normal glyph */
    xori    t1, t1, 0xFF                    /* attr=0 ^ cursor=1 -> inverted glyph */
2:
    lbu     t3, CMD_CURSOR_BG_OFF(s5)       /* saved pre-text bg byte */
    or      t1, t3, t1
    add     t2, s4, t2
    sb      t1, 0(t2)
compose_cursor_done:

    /* Layer 4: In-front sprites (BEHIND_TEXT = 0, Slot 15 -> Slot 0) */
    mv      a0, a5                          /* y */
    mv      a1, s4                          /* line_buf */
    mv      a2, s10                         /* active_oam_base */
    addi    a3, s5, CMD_FRONT_LIST_OFF      /* Bank 9 enabled in-front list */
    call    core1_draw_sprite_list
    j       core1_scanline_loop

    /* --- Phase B (posted == 1): Queue already-composed Bank 9 buffer (20 w) --- */
line_vactive_pixels:
    li      t3, VIDEO_STRIDE_WORDS
    sw      s4, DMA_CH0_READ_OFF(t0)
    sw      t3, DMA_CH0_COUNT_OFF(t0)
    li      s3, 0                       /* vactive_cmdlist_posted = 0 */

    /* Swap Bank 9 ping-pong buffer: LINE_A (0x20081000) <-> LINE_B (0x20081050) */
    li      t2, (BIOS_CORE1_LINE_A ^ BIOS_CORE1_LINE_B)
    xor     s4, s4, t2

    /* Advance scanline; wrap 525 -> 0 (VSYNC count & OAM latch run in VBLANK!) */
    addi    s2, s2, 1
    li      t2, CFG_MODE_V_TOTAL
    bltu    s2, t2, core1_scanline_loop
    li      s2, 0
    lw      t3, 0(s7)
    addi    t3, t3, 1
    sw      t3, 0(s7)
    j       core1_scanline_loop

line_vblank_on:
    addi    t2, s5, CMD_VBLANK_ON_OFF
    li      t3, 6
    sw      t2, DMA_CH0_READ_OFF(t0)
    sw      t3, DMA_CH0_COUNT_OFF(t0)
    addi    s2, s2, 1
    j       core1_scanline_loop

line_vblank_off:
    addi    t2, s5, CMD_VBLANK_OFF_OFF
    li      t3, 6
    sw      t2, DMA_CH0_READ_OFF(t0)
    sw      t3, DMA_CH0_COUNT_OFF(t0)
    addi    s2, s2, 1

    /* On scanline 0 -> 1 (full 4,000-cycle VBLANK window), latch SPRITE_OAM
     * and rebuild the compact Bank 9 behind-text & in-front enabled lists. */
    li      t2, 1
    bne     s2, t2, core1_scanline_loop
    call    core1_vblank_latch_oam
    j       core1_scanline_loop
.size core1_video_entry, . - core1_video_entry

/* ----------------------------------------------------------------------------
 * core1_vblank_latch_oam:
 *   Runs once per frame on VBLANK line 0 (4,000 idle cycles available).
 *   If VIDEO_CTRL.LATCH_OAM == 1, copies SPRITE_OAM (128 B) into Bank 9
 *   (BIOS_CORE1_OAM_LATCH), sets s10 = BIOS_CORE1_OAM_LATCH, and builds the
 *   compact enabled-slot lists at CMD_BEHIND_LIST_OFF and CMD_FRONT_LIST_OFF
 *   (in Slot 15 -> Slot 0 order). If LATCH_OAM == 0 (live beam-racing), sets
 *   s10 = VIDEO_SPRITE_OAM_BASE and populates both lists with all 16 slots.
 * ---------------------------------------------------------------------------- */
.p2align 2
.type core1_vblank_latch_oam, @function
core1_vblank_latch_oam:
    /* Latch packed cursor state [blink:8 | vis:8 | row:8 | col:8] from USB DPRAM
     * and advance 60 Hz blink phase once per frame during VBLANK. */
    li      t0, BIOS_CURSOR_STATE_ADDR
    lw      t1, 0(t0)
    srli    t2, t1, 16
    andi    t2, t2, 0xFF                    /* t2 = visible */
    beqz    t2, cursor_latch_hidden

    andi    t3, t1, 0xFF                    /* t3 = col (0..79) */
    srli    t4, t1, 8
    andi    t4, t4, 0xFF                    /* t4 = row (0..59) */
    srli    t5, t1, 24                      /* t5 = blink_frames (0..255) */
    beqz    t5, cursor_latch_solid

    /* Blinking cursor: show when phase == 0, then advance frame counter */
    lw      t0, CMD_CURSOR_PHASE_OFF(s5)
    bnez    t0, cursor_latch_blink_off
    sw      t4, CMD_CURSOR_ROW_OFF(s5)
    sw      t3, CMD_CURSOR_COL_OFF(s5)
    j       cursor_latch_step_cnt
cursor_latch_blink_off:
    li      t2, -1
    sw      t2, CMD_CURSOR_ROW_OFF(s5)
cursor_latch_step_cnt:
    lw      t2, CMD_CURSOR_CNT_OFF(s5)
    addi    t2, t2, 1
    bltu    t2, t5, 9f
    li      t2, 0
    xori    t0, t0, 1
    sw      t0, CMD_CURSOR_PHASE_OFF(s5)
9:
    sw      t2, CMD_CURSOR_CNT_OFF(s5)
    j       cursor_latch_done

cursor_latch_solid:
    sw      t4, CMD_CURSOR_ROW_OFF(s5)
    sw      t3, CMD_CURSOR_COL_OFF(s5)
    sw      zero, CMD_CURSOR_PHASE_OFF(s5)
    sw      zero, CMD_CURSOR_CNT_OFF(s5)
    j       cursor_latch_done

cursor_latch_hidden:
    li      t2, -1
    sw      t2, CMD_CURSOR_ROW_OFF(s5)
    sw      zero, CMD_CURSOR_PHASE_OFF(s5)
    sw      zero, CMD_CURSOR_CNT_OFF(s5)

cursor_latch_done:
    li      t0, VIDEO_CTRL_BASE
    lw      t1, VIDEO_CTRL_FLAGS_OFF(t0)
    andi    t1, t1, VIDEO_CTRL_LATCH_OAM_BIT
    beqz    t1, latch_live_mode

    /* Frame-latched mode: copy 32 words SPRITE_OAM -> Bank 9 mirror */
    li      t0, VIDEO_SPRITE_OAM_BASE
    li      t1, BIOS_CORE1_OAM_LATCH
    li      t2, BIOS_CORE1_OAM_LATCH + VIDEO_SPRITE_OAM_SIZE
1:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    bltu    t1, t2, 1b
    li      s10, BIOS_CORE1_OAM_LATCH

    /* Partition enabled slots (15 -> 0) into behind_list & front_list */
    addi    t0, s5, CMD_BEHIND_LIST_OFF     /* behind write ptr */
    addi    t1, s5, CMD_FRONT_LIST_OFF      /* front write ptr */
    li      t2, (SPRITE_OAM_COUNT - 1) * SPRITE_OAM_STRIDE  /* 120 down to 0 */
2:
    add     t3, s10, t2
    lbu     t4, SPRITE_OAM_OFF_FLAGS(t3)
    andi    t5, t4, SPRITE_FLAG_ENABLE
    beqz    t5, 4f
    andi    t5, t4, SPRITE_FLAG_BEHIND_TEXT
    beqz    t5, 3f
    sb      t2, 0(t0)
    addi    t0, t0, 1
    j       4f
3:
    sb      t2, 0(t1)
    addi    t1, t1, 1
4:
    addi    t2, t2, -SPRITE_OAM_STRIDE
    bgez    t2, 2b

    li      t3, SPR_LIST_END
    sb      t3, 0(t0)
    sb      t3, 0(t1)
    ret

latch_live_mode:
    /* Dynamic / beam-racing mode: read live SPRITE_OAM, scan all 16 slots */
    li      s10, VIDEO_SPRITE_OAM_BASE
    addi    t0, s5, CMD_BEHIND_LIST_OFF
    addi    t1, s5, CMD_FRONT_LIST_OFF
    li      t2, (SPRITE_OAM_COUNT - 1) * SPRITE_OAM_STRIDE
5:
    sb      t2, 0(t0)
    sb      t2, 0(t1)
    addi    t0, t0, 1
    addi    t1, t1, 1
    addi    t2, t2, -SPRITE_OAM_STRIDE
    bgez    t2, 5b
    li      t3, SPR_LIST_END
    sb      t3, 0(t0)
    sb      t3, 0(t1)
    ret
.size core1_vblank_latch_oam, . - core1_vblank_latch_oam

/* ----------------------------------------------------------------------------
 * core1_draw_sprite_list(a0=y, a1=line_buf, a2=oam_base, a3=list_ptr):
 *   Walks the 0xFF-terminated Bank 9 slot-offset list (Slot 15 -> Slot 0).
 *   For each sprite covering scanline `y`, fetches its 16-bit pixel & mask
 *   row from VIDEO_SPRITE_PAT_BASE (in s11), applies VFLIP/HFLIP, clips
 *   horizontally to [0..639], and blends (OPAQUE / OR / XOR) into `line_buf`.
 *   Preserves s0-s11 and a5 (active_y).
 * ---------------------------------------------------------------------------- */
.p2align 2
.type core1_draw_sprite_list, @function
core1_draw_sprite_list:
    /* Fast exit if this layer has zero enabled sprites! */
    lbu     t0, 0(a3)
    li      t1, SPR_LIST_END
    beq     t0, t1, spr_fast_ret

    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      a5, 8(sp)

    li      a6, SPRITE_HEIGHT               /* 16 */
    li      a7, SPRITE_PAT_COUNT            /* 111 */
    /* Determine expected BEHIND_TEXT bit from list_ptr (behind vs front) */
    addi    t2, s5, CMD_BEHIND_LIST_OFF
    li      t1, 0
    bne     a3, t2, spr_list_loop
    li      t1, SPRITE_FLAG_BEHIND_TEXT
    /* Keep expected (ENABLE | want_behind) in 4(sp) for live-mode filtering */
spr_list_loop:
    ori     t2, t1, SPRITE_FLAG_ENABLE
    sw      t2, 4(sp)

spr_slot_loop:
    lbu     t2, 0(a3)                       /* slot byte offset (0..120) or 0xFF */
    li      t3, SPR_LIST_END
    beq     t2, t3, spr_list_done
    add     a4, a2, t2                      /* a4 = &oam_base[slot] */

    lbu     t0, SPRITE_OAM_OFF_FLAGS(a4)    /* t0 = flags */
    andi    t1, t0, (SPRITE_FLAG_ENABLE | SPRITE_FLAG_BEHIND_TEXT)
    lw      t2, 4(sp)
    bne     t1, t2, spr_next_slot

    /* Vertical hit-test: (uint32_t)(y - sy) < 16 */
    lh      t1, SPRITE_OAM_OFF_Y(a4)        /* t1 = signed sy */
    sub     t1, a0, t1                      /* t1 = row = y - sy */
    bgeu    t1, a6, spr_next_slot

    /* Horizontal visibility check: -15 <= sx <= 639 */
    lh      t2, SPRITE_OAM_OFF_X(a4)        /* t2 = signed sx */
    li      t3, -15
    blt     t2, t3, spr_next_slot
    li      t3, VIDEO_WIDTH
    bge     t2, t3, spr_next_slot

    /* Pattern index bounds check (0..110) */
    lbu     t3, SPRITE_OAM_OFF_PAT(a4)
    bgeu    t3, a7, spr_next_slot

    /* Apply VFLIP (row = 15 - row) */
    andi    t4, t0, SPRITE_FLAG_VFLIP
    beqz    t4, 1f
    xori    t1, t1, 15
1:
    /* Fetch 16-bit pixel & mask rows from SPRITE_PAT[pat * 64 + row * 2] */
    slli    t3, t3, 6                       /* pat * 64 */
    slli    t1, t1, 1                       /* row * 2 */
    add     t3, t3, t1
    add     t3, s11, t3                     /* &SPRITE_PAT[pat][row] */
    lhu     t4, SPRITE_PAT_PIXEL_OFF(t3)    /* t4 = pix16 */
    lhu     t5, SPRITE_PAT_MASK_OFF(t3)     /* t5 = msk16 */

    /* Apply HFLIP (simultaneous 32-bit SWAR reversal of pix16 | (msk16 << 16)) */
    andi    t1, t0, SPRITE_FLAG_HFLIP
    beqz    t1, spr_clip_x
    slli    t5, t5, 16
    or      t6, t4, t5
    call    core1_rev16_pair_t6
    slli    t4, t6, 16
    srli    t4, t4, 16                      /* t4 = reversed pix16 */
    srli    t5, t6, 16                      /* t5 = reversed msk16 */

spr_clip_x:
    /* Left-edge clipping: if sx < 0, shift out (-sx) left pixels and clamp sx=0 */
    bgez    t2, 2f
    neg     t1, t2
    srl     t4, t4, t1
    srl     t5, t5, t1
    li      t2, 0
2:
    /* Word-wise Bank 9 blending (1 aligned 32-bit word if bit_shift <= 16,
     * else 2 adjacent aligned 32-bit words). line_buf (a1) is 4-byte aligned. */
    srli    t1, t2, 5                       /* t1 = word_idx (0..19) */
    andi    t2, t2, 31                      /* t2 = bit_shift (0..31) */
    slli    t3, t1, 2
    add     t3, a1, t3                      /* t3 = &line_buf[word_idx * 4] */

    /* Extract blend mode: 0=OPAQUE, 1=OR, 2=XOR, 3=reserved */
    srli    t0, t0, SPRITE_BLEND_SHIFT
    andi    t0, t0, 3
    li      a5, 3
    beq     t0, a5, spr_next_slot

    /* First word (word_idx, always in bounds 0..19): shift left by bit_shift.
     * Preserve t4 (pix16) and t5 (msk16) for optional second word; use a4/a5/t6. */
    sll     t6, t4, t2                      /* pix_lo */
    lw      a5, 0(t3)                       /* bg_lo */
    beqz    t0, spr_lo_opaque
    li      a4, 1
    beq     t0, a4, spr_lo_or
    xor     a5, a5, t6                      /* XOR */
    j       spr_lo_store
spr_lo_or:
    or      a5, a5, t6                      /* OR */
    j       spr_lo_store
spr_lo_opaque:
    sll     a4, t5, t2                      /* msk_lo */
    not     a4, a4
    and     a5, a5, a4
    or      a5, a5, t6
spr_lo_store:
    sw      a5, 0(t3)

    /* Second word needed only if bit_shift > 16 AND word_idx + 1 < 20 */
    li      a5, 16
    ble     t2, a5, spr_next_slot
    li      a5, (VIDEO_STRIDE_WORDS - 1)    /* 19 */
    bgeu    t1, a5, spr_next_slot

    li      a4, 32
    sub     t2, a4, t2                      /* rshift = 32 - bit_shift (1..15) */
    srl     t6, t4, t2                      /* pix_hi */
    lw      a5, 4(t3)                       /* bg_hi */
    beqz    t0, spr_hi_opaque
    li      a4, 1
    beq     t0, a4, spr_hi_or
    xor     a5, a5, t6                      /* XOR */
    j       spr_hi_store
spr_hi_or:
    or      a5, a5, t6                      /* OR */
    j       spr_hi_store
spr_hi_opaque:
    srl     a4, t5, t2                      /* msk_hi */
    not     a4, a4
    and     a5, a5, a4
    or      a5, a5, t6
spr_hi_store:
    sw      a5, 4(t3)

spr_next_slot:
    addi    a3, a3, 1
    j       spr_slot_loop

spr_list_done:
    lw      a5, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
spr_fast_ret:
    ret
.size core1_draw_sprite_list, . - core1_draw_sprite_list

/* ----------------------------------------------------------------------------
 * core1_rev16_pair_t6:
 *   Simultaneously reverses bits [15:0] and bits [31:16] of t6 in-place
 *   (used to HFLIP both pix16 and msk16 in a single 32-bit SWAR pass).
 *   Clobbers t1 and a5 only.
 * ---------------------------------------------------------------------------- */
.type core1_rev16_pair_t6, @function
core1_rev16_pair_t6:
    /* Swap odd/even bits */
    li      t1, 0x55555555
    and     a5, t6, t1
    slli    a5, a5, 1
    srli    t6, t6, 1
    and     t6, t6, t1
    or      t6, t6, a5

    /* Swap 2-bit pairs */
    li      t1, 0x33333333
    and     a5, t6, t1
    slli    a5, a5, 2
    srli    t6, t6, 2
    and     t6, t6, t1
    or      t6, t6, a5

    /* Swap nibbles */
    li      t1, 0x0F0F0F0F
    and     a5, t6, t1
    slli    a5, a5, 4
    srli    t6, t6, 4
    and     t6, t6, t1
    or      t6, t6, a5

    /* Swap bytes within each 16-bit halfword */
    li      t1, 0x00FF00FF
    and     a5, t6, t1
    slli    a5, a5, 8
    srli    t6, t6, 8
    and     t6, t6, t1
    or      t6, t6, a5
    ret
.size core1_rev16_pair_t6, . - core1_rev16_pair_t6

/* Core 1 fault safety trap (Direct-mode mtvec target) */
.p2align 2
.type core1_trap_halt, @function
core1_trap_halt:
    wfi
    j       core1_trap_halt
.size core1_trap_halt, . - core1_trap_halt


/* ============================================================================
 * Read-Only Tables (.rodata in XIP Flash)
 * ============================================================================ */
.section .rodata, "a"
.p2align 2

/* Boot ROM Core 1 launch sequence (rp2350-datasheet.pdf §5.3, p. 347) */
core1_launch_seq:
    .word   0
    .word   0
    .word   1
    .word   core1_trap_halt             /* Core 1 mtvec (Direct mode) */
    .word   BIOS_CORE1_STACK_TOP        /* Core 1 sp (0x20082000) */
    .word   core1_video_entry           /* Core 1 entry PC */

/* HSTX DVI command lists (copied to BIOS_CORE1_CMD_LIST in Bank 9 at boot).
 * TMDS control symbols (DVI 1.0 Table 3-5):
 *   00 = 0x354, 01 = 0x0AB, 10 = 0x154, 11 = 0x2AB */
hstx_cmd_lists_flash:
    /* +0x00: vblank_line_vsync_off (6 words) */
    .word   (0x1000 | 16)                               /* RAW_REPEAT 16 (HFP) */
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB)     /* SYNC_V1_H1 */
    .word   (0x1000 | 96)                               /* RAW_REPEAT 96 (HSYNC) */
    .word   ((0x354 << 20) | (0x354 << 10) | 0x154)     /* SYNC_V1_H0 */
    .word   (0x1000 | (48 + 640))                       /* RAW_REPEAT 688 (HBP+blank) */
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB)     /* SYNC_V1_H1 */

    /* +0x18: vblank_line_vsync_on (6 words) */
    .word   (0x1000 | 16)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x0AB)     /* SYNC_V0_H1 */
    .word   (0x1000 | 96)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x354)     /* SYNC_V0_H0 */
    .word   (0x1000 | (48 + 640))
    .word   ((0x354 << 20) | (0x354 << 10) | 0x0AB)     /* SYNC_V0_H1 */

    /* +0x30: vactive_line_prefix (7 words) */
    .word   (0x1000 | 16)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB)     /* SYNC_V1_H1 */
    .word   (0x1000 | 96)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x154)     /* SYNC_V1_H0 */
    .word   (0x1000 | 48)
    .word   ((0x354 << 20) | (0x354 << 10) | 0x2AB)     /* SYNC_V1_H1 */
    .word   (0x2000 | 640)                              /* TMDS 640 active pixels */
