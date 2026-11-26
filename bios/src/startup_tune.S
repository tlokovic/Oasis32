/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — Startup Chime & Blocking Note Player
 * ============================================================================
 * Plays a short retro-computer startup chime via the public BIOS ecall ABI
 * (BIOS_AUDIO_TONE and BIOS_TIME_US).
 *
 * Exports:
 *   - play_note(a0 = freq_hz, a1 = duration_ms)
 *   - play_startup_tune()
 * ============================================================================
 */

#include "abi/bios_abi.h"
#include "abi/devices.h"

.section .text, "ax"

/* ----------------------------------------------------------------------------
 * play_note(a0 = freq_hz, a1 = duration_ms):
 *   Blocking note player. Plays `freq_hz` (or silence if 0) for `duration_ms`
 *   milliseconds, then silences the piezo before returning.
 * ---------------------------------------------------------------------------- */
.global play_note
.type play_note, @function
play_note:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)
    sw      s1, 4(sp)

    /* Compute duration_us = duration_ms * 1000 */
    li      t0, 1000
    mul     s1, a1, t0

    /* Start tone (or silence if a0 == 0) */
    li      a7, BIOS_AUDIO_TONE
    ecall

    /* Snapshot monotonic start timestamp (low 32 bits of us counter) */
    li      a7, BIOS_TIME_US
    ecall
    mv      s0, a0                      /* s0 = start_us */

    /* Blocking wait until (now_us - start_us) >= duration_us */
1:
    li      a7, BIOS_TIME_US
    ecall
    sub     t0, a0, s0
    bltu    t0, s1, 1b

    /* Silence piezo on exit */
    li      a0, AUDIO_FREQ_OFF
    li      a7, BIOS_AUDIO_TONE
    ecall

    lw      s1, 4(sp)
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size play_note, . - play_note

/* ----------------------------------------------------------------------------
 * play_startup_tune():
 *   Plays a 5-note C-major boot chime (580 ms total) from
 *   startup_tune_notes (terminated by duration_ms == 0).
 * ---------------------------------------------------------------------------- */
.global play_startup_tune
.type play_startup_tune, @function
play_startup_tune:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      s0, 8(sp)

    la      s0, startup_tune_notes
1:
    lhu     a0, 0(s0)                   /* freq_hz (0 = rest) */
    lhu     a1, 2(s0)                   /* duration_ms (0 = end of tune) */
    beqz    a1, 2f
    call    play_note
    addi    s0, s0, 4
    j       1b
2:
    lw      s0, 8(sp)
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size play_startup_tune, . - play_startup_tune

/* ============================================================================
 * Startup Tune Note Table: { uint16_t freq_hz, uint16_t duration_ms }
 *   5-note C5 -> E5 -> G5 -> C6 -> G5 chime (580 ms total)
 * ============================================================================ */
.section .rodata, "a"
.p2align 2
startup_tune_notes:
    .hword  523,  90                    /* C5 */
    .hword  659,  90                    /* E5 */
    .hword  784,  90                    /* G5 */
    .hword 1047, 220                    /* C6 */
    .hword  784,  90                    /* G5 */
    .hword    0,   0                    /* terminator */
