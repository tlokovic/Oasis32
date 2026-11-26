/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Core 1 Video Coprocessor (HSTX 640x480 @ 60 Hz 1 bpp)
 * ============================================================================
 * Launches RP2350 Core 1 as Oasis32's dedicated, hidden Video Coprocessor:
 *   - Core 0 (`video_init`): clears public FRAMEBUF (0x20074000, 38,400 B),
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
 * Scope (Phase 3b — Bitmap Framebuffer + Text Overlay):
 *   - Unified OR-compositing of FRAMEBUF | FONT_RAM[TEXT_BUF] per scanline.
 *   - Hardware sprites (SPRITE_OAM / SPRITE_PAT) will plug into the same
 *     Bank 9 scanline compositing stage in the next step.
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

/* Scratchpad Bank 9 HSTX DMA command list offsets (base = BIOS_CORE1_CMD_LIST) */
#define CMD_VBLANK_OFF_OFF          0x00    /* 6 words (24 B) */
#define CMD_VBLANK_ON_OFF           0x18    /* 6 words (24 B) */
#define CMD_VACTIVE_PRE_OFF         0x30    /* 7 words (28 B) */
#define CMD_LIST_TOTAL_WORDS        19      /* 76 bytes total */

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

    /* 1. Clear 640x480 1 bpp public framebuffer to black (0x20074000..0x2007D5FF) */
    li      t0, VIDEO_FRAMEBUF_BASE
    li      t1, VIDEO_FRAMEBUF_BASE + VIDEO_FRAMEBUF_SIZE
1:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b

    /* 1b. Load default CP437 8x8 Flash font into VIDEO_FONT_RAM_BASE (2,048 B)
     *     and clear 80x60 VIDEO_TEXT_BUF_BASE (4,800 B) to transparent 0x00. */
    call    font_load_default

    li      t0, VIDEO_TEXT_BUF_BASE
    li      t1, VIDEO_TEXT_BUF_BASE + VIDEO_TEXT_BUF_SIZE
2:
    sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 2b

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
 *   s6 = VIDEO_FRAMEBUF_BASE    (0x20074000)
 *   s7 = BIOS_VSYNC_COUNT_ADDR  (0x50100500)
 *   s8 = VIDEO_FONT_RAM_BASE    (0x2007D600)
 *   s9 = VIDEO_TEXT_BUF_BASE    (0x2007DE00)
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

    /* 3. Mux GP12-GP19 to HSTX (FUNCSEL=0), clear ISO & OD, set SLEWFAST */
    li      t1, IO_BANK0_BASE + IO_DVI_BASE_CTRL_OFF
    li      t2, PADS_BANK0_BASE + ATOMIC_CLR + PADS_DVI_BASE_OFF
    li      t3, PADS_BANK0_BASE + ATOMIC_SET + PADS_DVI_BASE_OFF
    li      t4, 8
    li      t5, PADS_ISO_OD_MASK
    li      t6, PADS_SLEWFAST_BIT
2:
    sw      zero, 0(t1)
    sw      t5, 0(t2)
    sw      t6, 0(t3)
    addi    t1, t1, 8
    addi    t2, t2, 4
    addi    t3, t3, 4
    addi    t4, t4, -1
    bnez    t4, 2b

    /* 4. Enable HSTX serializer + command expander */
    li      t1, CFG_HSTX_CSR_DVI_ENABLE
    sw      t1, HSTX_CSR_OFF(t0)

    /* 5. Prioritize DMA reads/writes on the AHB5 crossbar */
    li      t0, BUSCTRL_BASE
    li      t1, BUSCTRL_PRIO_DMA_RW
    sw      t1, BUSCTRL_PRIORITY_OFF(t0)

    /* 6. Pre-load DMA CH0 (PING) and CH1 (PONG) with scanlines 0 and 1 */
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

    /* Initialize steady-state scanline registers */
    li      s1, 0                       /* dma_pong_next = 0 (CH0 finishes first) */
    li      s2, 2                       /* v_scanline = 2 (lines 0 & 1 pre-loaded) */
    li      s3, 0                       /* vactive_cmdlist_posted = 0 */
    li      s4, BIOS_CORE1_LINE_A       /* First active line composes into LINE_A */
    li      s6, VIDEO_FRAMEBUF_BASE
    li      s7, BIOS_VSYNC_COUNT_ADDR
    li      s8, VIDEO_FONT_RAM_BASE
    li      s9, VIDEO_TEXT_BUF_BASE

    /* Start Channel 0 (PING) via MULTI_CHAN_TRIGGER */
    li      t1, 0x1
    sw      t1, DMA_MULTI_TRIG_OFF(s0)

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

    /* Compose active scanline y = (v_scanline - 45) into Bank 9 buffer s4:
     *   out_byte = FRAMEBUF[y * 80 + col] | FONT_RAM[TEXT_BUF[(y>>3)*80 + col] * 8 + (y & 7)]
     * Future: blend behind-text and in-front hardware sprites in this stage. */
    addi    t2, s2, -CFG_MODE_V_BLANK_END   /* t2 = active_y (0..479) */
    li      t3, VIDEO_STRIDE_BYTES          /* 80 bytes/row */
    mul     a0, t2, t3
    add     a0, s6, a0                      /* a0 = &FRAMEBUF[y * 80] */
    srli    t4, t2, 3                       /* text_row = y >> 3 (0..59) */
    mul     a1, t4, t3
    add     a1, s9, a1                      /* a1 = &TEXT_BUF[text_row * 80] */
    andi    t4, t2, 7                       /* glyph_row = y & 7 (0..7) */
    add     a2, s8, t4                      /* a2 = &FONT_RAM[0 + (y & 7)] */
    mv      a3, s4                          /* a3 = dst Bank 9 ping-pong buffer */
    addi    a4, s4, VIDEO_STRIDE_BYTES      /* a4 = dst end (+80) */
compose_col_loop:
    lbu     t3, 0(a1)                       /* glyph_idx = TEXT_BUF[col] */
    slli    t3, t3, 3                       /* glyph_idx * 8 */
    add     t3, t3, a2                      /* &FONT_RAM[glyph_idx * 8 + (y & 7)] */
    lbu     t3, 0(t3)                       /* glyph_byte */
    lbu     t4, 0(a0)                       /* fb_byte = FRAMEBUF[col] */
    or      t4, t4, t3                      /* unified OR-compositing */
    sb      t4, 0(a3)
    addi    a0, a0, 1
    addi    a1, a1, 1
    addi    a3, a3, 1
    bltu    a3, a4, compose_col_loop
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

    /* Advance scanline; on wrap 525 -> 0, increment monotonic VSYNC counter */
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
    j       core1_scanline_loop
.size core1_video_entry, . - core1_video_entry

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
