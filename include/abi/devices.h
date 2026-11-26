/*
 * ============================================================================
 * Oasis32 Public ABI — Hardware-Independent Device Constants
 * ============================================================================
 * Public geometry, bitfields, and format constants for Oasis32 virtual/public
 * devices (Display, Sprites, Storage, LEDs, HID Input). Contains ZERO RP2350
 * silicon registers or physical pin numbers.
 *
 * RULE: Pure #define integer/hex expressions and C-style comments only.
 *
 * Reference: docs/VideoArchitecture.md, docs/BootBehavior.md
 * ============================================================================
 */

#ifndef OASIS32_ABI_DEVICES_H
#define OASIS32_ABI_DEVICES_H

/* ----------------------------------------------------------------------------
 * Display & Text Overlay Geometry (640x480 1 bpp + 80x60 Text Overlay)
 * ---------------------------------------------------------------------------- */
#define VIDEO_WIDTH                 640
#define VIDEO_HEIGHT                480
#define VIDEO_STRIDE_BYTES          80      /* 640 / 8 */
#define VIDEO_STRIDE_WORDS          20      /* 640 / 32 */
#define VIDEO_REFRESH_HZ            60

#define VIDEO_TEXT_COLS             80
#define VIDEO_TEXT_ROWS             60
#define VIDEO_FONT_GLYPHS           256
#define VIDEO_FONT_GLYPH_HEIGHT     8       /* 8x8 glyphs, 8 bytes each */

/* VIDEO_CTRL register offsets & bits (base = VIDEO_CTRL_BASE) */
#define VIDEO_CTRL_FLAGS_OFF        0x00
#define VIDEO_CTRL_LATCH_OAM_BIT    (1 << 0) /* 1 = frame-latched, 0 = live */

/* ----------------------------------------------------------------------------
 * Hardware Sprite Engine (16 OAM Slots, 58 Masked 16x16 Patterns)
 * ---------------------------------------------------------------------------- */
#define SPRITE_OAM_COUNT            16
#define SPRITE_OAM_STRIDE           8
#define SPRITE_OAM_OFF_X            0x00    /* int16_t (-15..639) */
#define SPRITE_OAM_OFF_Y            0x02    /* int16_t (-15..479) */
#define SPRITE_OAM_OFF_PAT          0x04    /* uint8_t (0..57) */
#define SPRITE_OAM_OFF_FLAGS        0x05    /* uint8_t */

#define SPRITE_FLAG_ENABLE          (1 << 0)
#define SPRITE_FLAG_HFLIP           (1 << 1)
#define SPRITE_FLAG_VFLIP           (1 << 2)
#define SPRITE_FLAG_BEHIND_TEXT     (1 << 3)
#define SPRITE_BLEND_SHIFT          4
#define SPRITE_BLEND_MASK           (3 << 4)
#define SPRITE_BLEND_OPAQUE         (0 << 4) /* (bg & ~mask) | pixels */
#define SPRITE_BLEND_OR             (1 << 4) /* bg | pixels */
#define SPRITE_BLEND_XOR            (2 << 4) /* bg ^ pixels */

#define SPRITE_PAT_COUNT            58
#define SPRITE_PAT_STRIDE           64      /* 32 B pixel plane + 32 B mask */
#define SPRITE_PAT_PIXEL_OFF        0x00
#define SPRITE_PAT_MASK_OFF         0x20
#define SPRITE_WIDTH                16
#define SPRITE_HEIGHT               16

/* ----------------------------------------------------------------------------
 * Block Storage (SD Card)
 * ---------------------------------------------------------------------------- */
#define SD_SECTOR_SIZE              512
#define SD_STATUS_PRESENT           (1 << 0) /* Card physically seated */
#define SD_STATUS_READY             (1 << 1) /* Card initialized & ready */
#define SD_STATUS_SDHC              (1 << 2) /* 1 = SDHC/SDXC (LBA), 0 = SDSC */

/* ----------------------------------------------------------------------------
 * Audio (Piezo Buzzer)
 * ---------------------------------------------------------------------------- */
#define AUDIO_FREQ_OFF              0
#define AUDIO_FREQ_MIN              16
#define AUDIO_FREQ_MAX              20000

/* ----------------------------------------------------------------------------
 * Status LEDs (logical indices & 3-bit mask)
 * ---------------------------------------------------------------------------- */
#define LED_RED                     0
#define LED_GREEN                   1
#define LED_BLUE                    2
#define LED_COUNT                   3

#define LED_BIT_RED                 (1 << 0)
#define LED_BIT_GREEN               (1 << 1)
#define LED_BIT_BLUE                (1 << 2)

/* ----------------------------------------------------------------------------
 * Keyboard & Mouse Input Event Bitfields & Bitmasks
 * ---------------------------------------------------------------------------- */
#define KEY_MOD_LCTRL               (1 << 0)
#define KEY_MOD_LSHIFT              (1 << 1)
#define KEY_MOD_LALT                (1 << 2)
#define KEY_MOD_LGUI                (1 << 3)
#define KEY_MOD_RCTRL               (1 << 4)
#define KEY_MOD_RSHIFT              (1 << 5)
#define KEY_MOD_RALT                (1 << 6)
#define KEY_MOD_RGUI                (1 << 7)

#define KEY_EVENT_CODE_MASK         0x00FF
#define KEY_EVENT_MOD_SHIFT         8
#define KEY_EVENT_MOD_MASK          0xFF00
#define KEY_EVENT_DOWN_BIT          (1 << 16)
#define KEY_STATE_MAX_KEYS          6
#define KEY_STATE_BUF_SIZE          8

#define MOUSE_BTN_LEFT              (1 << 0)
#define MOUSE_BTN_RIGHT             (1 << 1)
#define MOUSE_BTN_MIDDLE            (1 << 2)
#define MOUSE_BTN_SIDE1             (1 << 3)
#define MOUSE_BTN_SIDE2             (1 << 4)

#define MOUSE_EVENT_BTN_MASK        0x00FF
#define MOUSE_EVENT_STATE_SHIFT     8
#define MOUSE_EVENT_STATE_MASK      0xFF00
#define MOUSE_EVENT_DOWN_BIT        (1 << 16)

#endif /* OASIS32_ABI_DEVICES_H */
