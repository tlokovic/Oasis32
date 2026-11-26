/*
 * ============================================================================
 * Oasis32 Stage-1 BIOS — SD Card Block Driver (PL022 SPI0 + GP6 Card Detect)
 * ============================================================================
 * Synchronous 512-byte LBA block driver with bounded TIMER0 timeouts.
 * All SPI0 / GPIO / SD protocol details remain private to the BIOS.
 *
 * Exposes:
 *   - sd_hw_init  ()                   -> boot-time SPI0 + GP2..GP6 setup
 *   - sd_status   ()                   -> a0 = SD_STATUS_* bitmask (>= 0)
 *   - sd_init     ()                   -> a0 = ERR_OK, ERR_NO_DEVICE, or ERR_IO
 *   - sd_read     (a0=lba, a1=buf_ptr) -> a0 = ERR_OK / ERR_NO_DEVICE / ERR_INVALID_ARG / ERR_IO
 *   - sd_write    (a0=lba, a1=buf_ptr) -> a0 = ERR_OK / ERR_NO_DEVICE / ERR_INVALID_ARG / ERR_IO
 *   - sd_capacity ()                   -> a0 = ERR_OK or ERR_NO_DEVICE, a1 = sectors
 *
 * References:
 *   - sd-physical-layer-simplified-spec.pdf §5.3 (CSD, pp. 163-173),
 *     §7.2-§7.3 (SPI Mode Init & Commands, pp. 185-194)
 *   - rp2350-datasheet.pdf §12.3.5 (PL022 SPI0, p. 958)
 * ============================================================================
 */

#include "abi/memory_map.h"
#include "abi/bios_abi.h"
#include "abi/devices.h"
#include "hw/rp2350_regs.h"
#include "hw/oasis32_pins.h"
#include "bios_config.h"
#include "bios_ram.h"

#define SD_CD_DEBOUNCE_US           50000       /* 50 ms mechanical CD debounce */
#define SD_CMD0_TIMEOUT_US          250000      /* 250 ms power-up + CMD0 retry */
#define SD_ACMD41_TIMEOUT_US        1000000     /* 1.0 s card power-up timeout */
#define SD_READ_TOKEN_TIMEOUT_US    250000      /* 250 ms data token timeout */
#define SD_WRITE_BUSY_TIMEOUT_US    500000      /* 500 ms flash program timeout */

.section .text, "ax"

/* ============================================================================
 * Low-Level PL022 SPI0 & CS/CD Helpers
 * ============================================================================ */

/* sd_spi_set_speed(a0 = SSPCR0, a1 = SSPCPSR) */
.type sd_spi_set_speed, @function
sd_spi_set_speed:
    li      t0, SPI0_BASE
    sw      zero, SPI_SSPCR1_OFF(t0)        /* Disable SSE while changing clock */
    sw      a1, SPI_SSPCPSR_OFF(t0)
    sw      a0, SPI_SSPCR0_OFF(t0)
    li      t1, SPI_CR1_ENABLE
    sw      t1, SPI_SSPCR1_OFF(t0)
1:
    lw      t1, SPI_SSPSR_OFF(t0)
    andi    t1, t1, SPI_SR_RNE_BIT
    beqz    t1, 2f
    lw      zero, SPI_SSPDR_OFF(t0)         /* Drain any stale RX FIFO bytes */
    j       1b
2:
    ret
.size sd_spi_set_speed, . - sd_spi_set_speed

/* sd_spi_xfer(a0 = tx_byte) -> a0 = rx_byte */
.type sd_spi_xfer, @function
sd_spi_xfer:
    li      t0, SPI0_BASE
1:
    lw      t1, SPI_SSPSR_OFF(t0)
    andi    t1, t1, SPI_SR_TNF_BIT
    beqz    t1, 1b                          /* Wait for TX FIFO space */
    sw      a0, SPI_SSPDR_OFF(t0)
2:
    lw      t1, SPI_SSPSR_OFF(t0)
    andi    t1, t1, SPI_SR_RNE_BIT
    beqz    t1, 2b                          /* Wait for RX byte */
    lw      a0, SPI_SSPDR_OFF(t0)
    andi    a0, a0, 0xFF
    ret
.size sd_spi_xfer, . - sd_spi_xfer

.type sd_cs_select, @function
sd_cs_select:
    li      t0, SIO_BASE
    li      t1, SIO_SD_CS_MASK
    sw      t1, SIO_GPIO_OUT_CLR_OFF(t0)
    ret
.size sd_cs_select, . - sd_cs_select

.type sd_deselect_and_clock, @function
sd_deselect_and_clock:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    li      t0, SIO_BASE
    li      t1, SIO_SD_CS_MASK
    sw      t1, SIO_GPIO_OUT_SET_OFF(t0)
    li      a0, 0xFF
    call    sd_spi_xfer                     /* 8 trailing clocks to release MISO */
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size sd_deselect_and_clock, . - sd_deselect_and_clock

/* sd_is_card_present() -> a0 = 1 if debounced GP6 is seated, 0 if empty.
 * Also checks IO_BANK0 INTR0.GPIO6_EDGE_HIGH (hardware rising-edge latch) so
 * even a fast remove-and-reinsert between polls invalidates SD_STATUS_READY. */
.type sd_is_card_present, @function
sd_is_card_present:
    /* 1. Check hardware rising-edge latch on GP6 (any removal invalidates ready) */
    li      t0, IO_BANK0_BASE
    lw      t1, IO_BANK0_INTR0_OFF(t0)
    li      t2, IO_INTR0_GPIO6_EDGE_HIGH
    and     t1, t1, t2
    beqz    t1, 1f
    sw      t2, IO_BANK0_INTR0_OFF(t0)      /* Write-1-to-clear latch */
    li      t0, BIOS_SD_FLAGS_ADDR
    sw      zero, 0(t0)
    li      t0, BIOS_SD_SECTORS_ADDR
    sw      zero, 0(t0)
1:
    /* 2. Sample raw GP6 (LOW = seated -> 1, HIGH = empty -> 0) and debounce 50 ms */
    li      t0, SIO_BASE
    lw      t1, SIO_GPIO_IN_OFF(t0)
    andi    t1, t1, SIO_SD_CD_MASK
    seqz    t1, t1                          /* t1 = raw present (0 or 1) */

    li      t0, TIMER0_BASE
    lw      t2, TIMER_RAWL_OFF(t0)          /* t2 = now_us */

    li      t0, BIOS_SD_CD_LAST_RAW_ADDR
    lw      t3, 0(t0)
    beq     t1, t3, 2f
    sw      t1, 0(t0)                       /* raw changed -> reset debounce timer */
    li      t0, BIOS_SD_CD_CHANGE_US_ADDR
    sw      t2, 0(t0)
    li      t0, BIOS_SD_CD_STABLE_ADDR
    lw      a0, 0(t0)
    ret
2:
    li      t0, BIOS_SD_CD_STABLE_ADDR
    lw      a0, 0(t0)
    beq     t1, a0, 3f                      /* Already stable */

    li      t3, BIOS_SD_CD_CHANGE_US_ADDR
    lw      t3, 0(t3)
    sub     t3, t2, t3
    li      t4, SD_CD_DEBOUNCE_US
    bltu    t3, t4, 3f                      /* Still within 50 ms debounce window */

    /* Commit new debounced state */
    sw      t1, 0(t0)
    mv      a0, t1
    bnez    a0, 3f
    li      t0, BIOS_SD_FLAGS_ADDR
    sw      zero, 0(t0)
    li      t0, BIOS_SD_SECTORS_ADDR
    sw      zero, 0(t0)
3:
    ret
.size sd_is_card_present, . - sd_is_card_present

/* sd_send_cmd(a0 = cmd_idx, a1 = arg, a2 = crc) -> a0 = R1 */
.type sd_send_cmd, @function
sd_send_cmd:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      a0, 20(sp)
    sw      a1, 16(sp)
    sw      a2, 12(sp)

    /* Wait up to 64 bytes for card DO to idle high (0xFF) */
    li      s0, 64
1:
    li      a0, 0xFF
    call    sd_spi_xfer
    li      t0, 0xFF
    beq     a0, t0, 2f
    addi    s0, s0, -1
    bnez    s0, 1b
2:
    lw      a0, 20(sp)
    andi    a0, a0, 0x3F
    ori     a0, a0, 0x40
    call    sd_spi_xfer                     /* Byte 0: 01 + cmd_idx */

    lw      s0, 16(sp)
    srli    a0, s0, 24
    andi    a0, a0, 0xFF
    call    sd_spi_xfer                     /* Byte 1: arg[31:24] */
    srli    a0, s0, 16
    andi    a0, a0, 0xFF
    call    sd_spi_xfer                     /* Byte 2: arg[23:16] */
    srli    a0, s0, 8
    andi    a0, a0, 0xFF
    call    sd_spi_xfer                     /* Byte 3: arg[15:8] */
    andi    a0, s0, 0xFF
    call    sd_spi_xfer                     /* Byte 4: arg[7:0] */

    lw      a0, 12(sp)
    call    sd_spi_xfer                     /* Byte 5: CRC */

    /* Poll up to 16 bytes for R1 (bit 7 == 0) */
    li      s0, 16
3:
    li      a0, 0xFF
    call    sd_spi_xfer
    andi    t0, a0, 0x80
    beqz    t0, 4f
    addi    s0, s0, -1
    bnez    s0, 3b
4:
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size sd_send_cmd, . - sd_send_cmd

/* sd_read_data_packet(a0 = dst_ptr, a1 = byte_len) -> a0 = 1 (ok) / 0 (fail) */
.type sd_read_data_packet, @function
sd_read_data_packet:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    mv      s0, a0                          /* dst_ptr */
    mv      s1, a1                          /* len */

    /* Bounded 250 ms wait for 0xFE start block token */
    li      t0, TIMER0_BASE
    lw      s2, TIMER_RAWL_OFF(t0)
    li      t1, SD_READ_TOKEN_TIMEOUT_US
    add     s2, s2, t1                      /* s2 = deadline_us */
1:
    li      a0, 0xFF
    call    sd_spi_xfer
    li      t0, 0xFF
    bne     a0, t0, 2f
    li      t0, TIMER0_BASE
    lw      t1, TIMER_RAWL_OFF(t0)
    sub     t1, t1, s2
    bltz    t1, 1b
    j       pkt_fail
2:
    li      t0, 0xFE
    bne     a0, t0, pkt_fail
3:
    li      a0, 0xFF
    call    sd_spi_xfer
    sb      a0, 0(s0)
    addi    s0, s0, 1
    addi    s1, s1, -1
    bnez    s1, 3b

    li      a0, 0xFF
    call    sd_spi_xfer                     /* Discard CRC16 */
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 1
    j       pkt_ret
pkt_fail:
    li      a0, 0
pkt_ret:
    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size sd_read_data_packet, . - sd_read_data_packet

/* ============================================================================
 * Boot-Time Hardware Initialization: sd_hw_init()
 * ============================================================================ */
.global sd_hw_init
.type sd_hw_init, @function
sd_hw_init:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    /* 1. Configure SPI0 for 393.75 kHz Motorola SPI Mode 0, 8-bit */
    li      a0, CFG_SPI_CR0_INIT_394K
    li      a1, CFG_SPI_CPSR_INIT_394K
    call    sd_spi_set_speed

    /* 2. IO_BANK0: GP2/3/4 = SPI0 (F1), GP5/6 = SIO (F5) */
    li      t0, IO_BANK0_BASE
    li      t1, IO_FUNCSEL_SPI
    sw      t1, IO_SD_SCK_CTRL_OFF(t0)
    sw      t1, IO_SD_MOSI_CTRL_OFF(t0)
    sw      t1, IO_SD_MISO_CTRL_OFF(t0)
    li      t1, IO_FUNCSEL_SIO
    sw      t1, IO_SD_CS_CTRL_OFF(t0)
    sw      t1, IO_SD_CD_CTRL_OFF(t0)

    /* 3. SIO: GP5 (CSn) output HIGH; GP6 (CD) input */
    li      t0, SIO_BASE
    li      t1, SIO_SD_CS_MASK
    sw      t1, SIO_GPIO_OUT_SET_OFF(t0)
    sw      t1, SIO_GPIO_OE_SET_OFF(t0)

    /* 4. PADS_BANK0: clear ISO/OD on GP2/3/5; set IE+PUE (clear ISO/PDE) on GP4/6 */
    li      t0, PADS_BANK0_BASE + ATOMIC_CLR
    li      t1, (PADS_ISO_BIT | PADS_OD_BIT)
    sw      t1, PADS_SD_SCK_OFF(t0)
    sw      t1, PADS_SD_MOSI_OFF(t0)
    sw      t1, PADS_SD_CS_OFF(t0)
    li      t1, (PADS_ISO_BIT | PADS_PDE_BIT)
    sw      t1, PADS_SD_MISO_OFF(t0)
    sw      t1, PADS_SD_CD_OFF(t0)

    li      t0, PADS_BANK0_BASE + ATOMIC_SET
    li      t1, (PADS_IE_BIT | PADS_PUE_BIT)
    sw      t1, PADS_SD_MISO_OFF(t0)        /* Pull-up on MISO (GP4) */
    sw      t1, PADS_SD_CD_OFF(t0)          /* Pull-up on CD (GP6, active LOW) */

    /* 5. Wait 100 us for GP6 pull-up to settle, then snapshot initial CD state */
    li      t0, TIMER0_BASE
    lw      t1, TIMER_RAWL_OFF(t0)
1:
    lw      t2, TIMER_RAWL_OFF(t0)
    sub     t3, t2, t1
    li      t4, 100
    bltu    t3, t4, 1b

    li      t0, SIO_BASE
    lw      t1, SIO_GPIO_IN_OFF(t0)
    andi    t1, t1, SIO_SD_CD_MASK
    seqz    t1, t1                          /* 1 if seated at boot, 0 if empty */
    li      t0, BIOS_SD_CD_STABLE_ADDR
    sw      t1, 0(t0)
    li      t0, BIOS_SD_CD_LAST_RAW_ADDR
    sw      t1, 0(t0)
    li      t0, BIOS_SD_CD_CHANGE_US_ADDR
    sw      t2, 0(t0)

    /* Clear any power-on GP6 rising-edge latch */
    li      t0, IO_BANK0_BASE
    li      t1, IO_INTR0_GPIO6_EDGE_HIGH
    sw      t1, IO_BANK0_INTR0_OFF(t0)

    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size sd_hw_init, . - sd_hw_init

/* ============================================================================
 * Public BIOS ABI Service Implementations (BIOS_BLK_SD, 0x40-0x44)
 * ============================================================================ */

/* ----------------------------------------------------------------------------
 * sd_status() -> a0 = SD_STATUS_* bitmask (>= 0)
 * ---------------------------------------------------------------------------- */
.global sd_status
.type sd_status, @function
sd_status:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    call    sd_is_card_present
    beqz    a0, 1f
    li      t0, BIOS_SD_FLAGS_ADDR
    lw      t0, 0(t0)
    ori     a0, t0, SD_STATUS_PRESENT
1:
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size sd_status, . - sd_status

/* ----------------------------------------------------------------------------
 * sd_init() -> a0 = ERR_OK (0), ERR_NO_DEVICE (-6), or ERR_IO (-5)
 * ---------------------------------------------------------------------------- */
.global sd_init
.type sd_init, @function
sd_init:
    addi    sp, sp, -48
    sw      ra, 44(sp)
    sw      s0, 40(sp)
    sw      s1, 36(sp)
    sw      s2, 32(sp)

    /* 1. Verify card is physically seated (raw GP6 check; CMD0 loop handles settle) */
    li      t0, SIO_BASE
    lw      t1, SIO_GPIO_IN_OFF(t0)
    andi    t1, t1, SIO_SD_CD_MASK
    bnez    t1, sd_init_nodev

    /* Reset cached driver state and clear GP6 rising-edge latch */
    li      t0, BIOS_SD_FLAGS_ADDR
    sw      zero, 0(t0)
    li      t0, BIOS_SD_SECTORS_ADDR
    sw      zero, 0(t0)
    li      t0, IO_BANK0_BASE
    li      t1, IO_INTR0_GPIO6_EDGE_HIGH
    sw      t1, IO_BANK0_INTR0_OFF(t0)

    /* 2. Drop SPI0 to 393.75 kHz and retry (80 dummy clocks + CMD0) up to 250 ms
     *    so a freshly inserted card cleanly rides out its power-up reset. */
    li      a0, CFG_SPI_CR0_INIT_394K
    li      a1, CFG_SPI_CPSR_INIT_394K
    call    sd_spi_set_speed

    li      t0, TIMER0_BASE
    lw      s2, TIMER_RAWL_OFF(t0)
    li      t1, SD_CMD0_TIMEOUT_US
    add     s2, s2, t1                      /* s2 = CMD0 deadline_us */
2:
    li      t0, SIO_BASE
    li      t1, SIO_SD_CS_MASK
    sw      t1, SIO_GPIO_OUT_SET_OFF(t0)    /* CS HIGH */

    li      s0, 10                          /* 80 dummy clocks */
1:
    li      a0, 0xFF
    call    sd_spi_xfer
    addi    s0, s0, -1
    bnez    s0, 1b

    /* CMD0 (GO_IDLE_STATE, CRC=0x95) -> expect R1 = 0x01 */
    call    sd_cs_select
    li      a0, 0
    li      a1, 0
    li      a2, 0x95
    call    sd_send_cmd
    mv      s1, a0
    call    sd_deselect_and_clock
    li      t0, 0x01
    beq     s1, t0, 3f

    li      t0, TIMER0_BASE
    lw      t1, TIMER_RAWL_OFF(t0)
    sub     t1, t1, s2
    bltz    t1, 2b
    j       sd_init_ioerr

    /* 4. CMD8 (SEND_IF_COND, 0x1AA, CRC=0x87) -> s2 = is_v2 (1 or 0) */
3:
    call    sd_cs_select
    li      a0, 8
    li      a1, 0x1AA
    li      a2, 0x87
    call    sd_send_cmd
    mv      s1, a0
    li      s2, 0
    li      t0, 0x01
    bne     s1, t0, 4f
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
    mv      s0, a0                          /* Echo check byte (expect 0xAA) */
4:
    call    sd_deselect_and_clock
    li      t0, 0x01
    beq     s1, t0, 5f
    li      t0, 0x05                        /* Legacy SD v1.x */
    bne     s1, t0, sd_init_ioerr
    j       6f
5:
    li      t0, 0xAA
    bne     s0, t0, sd_init_ioerr
    li      s2, 1                           /* SD v2.0 */

    /* 5. ACMD41 polling loop with bounded 1.0 s timeout */
6:
    li      t0, TIMER0_BASE
    lw      s0, TIMER_RAWL_OFF(t0)
    li      t1, SD_ACMD41_TIMEOUT_US
    add     s0, s0, t1                      /* s0 = deadline_us */
7:
    call    sd_cs_select
    li      a0, 55                          /* CMD55 */
    li      a1, 0
    li      a2, 0xFF
    call    sd_send_cmd
    call    sd_deselect_and_clock

    call    sd_cs_select
    li      a0, 41                          /* ACMD41 */
    li      a1, 0
    beqz    s2, 8f
    li      a1, 0x40000000                  /* HCS = 1 for SD v2.0 */
8:
    li      a2, 0xFF
    call    sd_send_cmd
    mv      s1, a0
    call    sd_deselect_and_clock
    beqz    s1, 9f                          /* R1 == 0x00 -> Ready! */

    li      t0, TIMER0_BASE
    lw      t1, TIMER_RAWL_OFF(t0)
    sub     t1, t1, s0
    bltz    t1, 7b
    j       sd_init_ioerr

    /* 6. CMD58 (READ_OCR) -> inspect CCS bit (OCR[0] bit 6) */
9:
    call    sd_cs_select
    li      a0, 58
    li      a1, 0
    li      a2, 0xFF
    call    sd_send_cmd
    mv      s1, a0
    li      s0, 0
    bnez    s1, 10f
    li      a0, 0xFF
    call    sd_spi_xfer
    mv      s0, a0                          /* OCR[0] */
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
10:
    call    sd_deselect_and_clock
    bnez    s1, sd_init_ioerr

    /* s2 = is_sdhc = is_v2 && (OCR[0] & 0x40) */
    andi    s0, s0, 0x40
    snez    s0, s0
    and     s2, s2, s0

    /* If SDSC (!s2), force 512-byte block length via CMD16 */
    bnez    s2, 11f
    call    sd_cs_select
    li      a0, 16
    li      a1, SD_SECTOR_SIZE
    li      a2, 0xFF
    call    sd_send_cmd
    mv      s1, a0
    call    sd_deselect_and_clock
    bnez    s1, sd_init_ioerr

    /* 7. Switch SPI0 to 12.60 MHz for data transfers */
11:
    li      a0, CFG_SPI_CR0_RUN_12M6
    li      a1, CFG_SPI_CPSR_RUN_12M6
    call    sd_spi_set_speed

    /* 8. CMD9 (SEND_CSD): read 16-byte CSD into 0(sp)..15(sp) for capacity */
    call    sd_cs_select
    li      a0, 9
    li      a1, 0
    li      a2, 0xFF
    call    sd_send_cmd
    li      s0, 0                           /* sectors = 0 if CSD unavailable */
    bnez    a0, 12f
    mv      a0, sp
    li      a1, 16
    call    sd_read_data_packet
    mv      s1, a0
    call    sd_deselect_and_clock
    beqz    s1, 13f

    /* Parse CSD v2.0 vs CSD v1.0 (sd-physical-layer-simplified-spec.pdf §5.3) */
    lbu     t0, 0(sp)
    srli    t0, t0, 6                       /* CSD_STRUCTURE = csd[0][7:6] */
    li      t1, 1
    bne     t0, t1, csd_v1

    /* CSD v2.0: blocks = (((csd[7]&0x3F)<<16 | csd[8]<<8 | csd[9]) + 1) * 1024 */
    lbu     t0, 7(sp)
    andi    t0, t0, 0x3F
    slli    t0, t0, 16
    lbu     t1, 8(sp)
    slli    t1, t1, 8
    or      t0, t0, t1
    lbu     t1, 9(sp)
    or      t0, t0, t1
    addi    t0, t0, 1
    slli    s0, t0, 10
    j       13f

csd_v1:
    lbu     t0, 5(sp)
    andi    t0, t0, 0x0F                    /* READ_BL_LEN */
    lbu     t1, 6(sp)
    andi    t1, t1, 0x03
    slli    t1, t1, 10
    lbu     t2, 7(sp)
    slli    t2, t2, 2
    or      t1, t1, t2
    lbu     t2, 8(sp)
    srli    t2, t2, 6
    or      t1, t1, t2                      /* C_SIZE */
    addi    t1, t1, 1
    lbu     t2, 9(sp)
    andi    t2, t2, 0x03
    slli    t2, t2, 1
    lbu     t3, 10(sp)
    srli    t3, t3, 7
    or      t2, t2, t3                      /* C_SIZE_MULT */
    add     t0, t0, t2
    addi    t0, t0, -7
    sll     s0, t1, t0
    j       13f
12:
    call    sd_deselect_and_clock

    /* 9. Commit initialized state to USB DPRAM */
13:
    li      t0, BIOS_SD_SECTORS_ADDR
    sw      s0, 0(t0)
    li      t1, SD_STATUS_READY
    beqz    s2, 14f
    ori     t1, t1, SD_STATUS_SDHC
14:
    li      t0, BIOS_SD_FLAGS_ADDR
    sw      t1, 0(t0)
    li      t1, 1
    li      t0, BIOS_SD_CD_STABLE_ADDR
    sw      t1, 0(t0)
    li      t0, BIOS_SD_CD_LAST_RAW_ADDR
    sw      t1, 0(t0)
    li      t0, IO_BANK0_BASE
    li      t1, IO_INTR0_GPIO6_EDGE_HIGH
    sw      t1, IO_BANK0_INTR0_OFF(t0)
    li      a0, ERR_OK
    j       sd_init_ret

sd_init_nodev:
    li      a0, ERR_NO_DEVICE
    j       sd_init_ret

sd_init_ioerr:
    li      a0, ERR_IO

sd_init_ret:
    lw      s2, 32(sp)
    lw      s1, 36(sp)
    lw      s0, 40(sp)
    lw      ra, 44(sp)
    addi    sp, sp, 48
    ret
.size sd_init, . - sd_init

/* ----------------------------------------------------------------------------
 * sd_read(a0 = lba, a1 = buf_ptr) -> a0 = ERR_OK / ERR_NO_DEVICE / ERR_INVALID_ARG / ERR_IO
 * ---------------------------------------------------------------------------- */
.global sd_read
.type sd_read, @function
sd_read:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    mv      s0, a0                          /* lba */
    mv      s1, a1                          /* buf_ptr */

    call    sd_is_card_present
    beqz    a0, sd_read_nodev

    li      t0, BIOS_SD_FLAGS_ADDR
    lw      t1, 0(t0)
    andi    t2, t1, SD_STATUS_READY
    beqz    t2, sd_read_nodev

    /* Validate [buf_ptr, buf_ptr + 512) inside User SRAM */
    li      t0, USER_RAM_BASE
    bltu    s1, t0, sd_read_inval
    li      t0, (USER_RAM_END - SD_SECTOR_SIZE)
    bgtu    s1, t0, sd_read_inval

    /* Validate lba < sectors (when capacity is known) */
    li      t0, BIOS_SD_SECTORS_ADDR
    lw      t2, 0(t0)
    beqz    t2, 1f
    bgeu    s0, t2, sd_read_inval
1:
    /* Convert LBA to byte address for SDSC cards */
    andi    t2, t1, SD_STATUS_SDHC
    bnez    t2, 2f
    slli    s0, s0, 9
2:
    call    sd_cs_select
    li      a0, 17                          /* CMD17 (READ_SINGLE_BLOCK) */
    mv      a1, s0
    li      a2, 0xFF
    call    sd_send_cmd
    bnez    a0, sd_read_iofail

    mv      a0, s1
    li      a1, SD_SECTOR_SIZE
    call    sd_read_data_packet
    mv      s0, a0
    call    sd_deselect_and_clock
    beqz    s0, sd_read_ioerr
    li      a0, ERR_OK
    j       sd_read_ret

sd_read_iofail:
    call    sd_deselect_and_clock
sd_read_ioerr:
    li      a0, ERR_IO
    j       sd_read_ret
sd_read_inval:
    li      a0, ERR_INVALID_ARG
    j       sd_read_ret
sd_read_nodev:
    li      a0, ERR_NO_DEVICE
sd_read_ret:
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size sd_read, . - sd_read

/* ----------------------------------------------------------------------------
 * sd_write(a0 = lba, a1 = buf_ptr) -> a0 = ERR_OK / ERR_NO_DEVICE / ERR_INVALID_ARG / ERR_IO
 * ---------------------------------------------------------------------------- */
.global sd_write
.type sd_write, @function
sd_write:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    mv      s0, a0                          /* lba */
    mv      s1, a1                          /* buf_ptr */

    call    sd_is_card_present
    beqz    a0, sd_write_nodev

    li      t0, BIOS_SD_FLAGS_ADDR
    lw      t1, 0(t0)
    andi    t2, t1, SD_STATUS_READY
    beqz    t2, sd_write_nodev

    /* Validate [buf_ptr, buf_ptr + 512) inside User SRAM */
    li      t0, USER_RAM_BASE
    bltu    s1, t0, sd_write_inval
    li      t0, (USER_RAM_END - SD_SECTOR_SIZE)
    bgtu    s1, t0, sd_write_inval

    /* Validate lba < sectors (when capacity is known) */
    li      t0, BIOS_SD_SECTORS_ADDR
    lw      t2, 0(t0)
    beqz    t2, 1f
    bgeu    s0, t2, sd_write_inval
1:
    andi    t2, t1, SD_STATUS_SDHC
    bnez    t2, 2f
    slli    s0, s0, 9
2:
    call    sd_cs_select
    li      a0, 24                          /* CMD24 (WRITE_BLOCK) */
    mv      a1, s0
    li      a2, 0xFF
    call    sd_send_cmd
    bnez    a0, sd_write_iofail

    /* 1-byte gap + 0xFE Start Block Token */
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFE
    call    sd_spi_xfer

    /* Stream 512 bytes from caller's buf_ptr */
    li      s2, SD_SECTOR_SIZE
3:
    lbu     a0, 0(s1)
    call    sd_spi_xfer
    addi    s1, s1, 1
    addi    s2, s2, -1
    bnez    s2, 3b

    /* 2 dummy CRC16 bytes + read data response token */
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
    li      a0, 0xFF
    call    sd_spi_xfer
    andi    t0, a0, 0x1F
    li      t1, 0x05                        /* 0b00101 = Data Accepted */
    bne     t0, t1, sd_write_iofail

    /* Poll card busy (DO == 0x00) with bounded 500 ms timeout */
    li      t0, TIMER0_BASE
    lw      s2, TIMER_RAWL_OFF(t0)
    li      t1, SD_WRITE_BUSY_TIMEOUT_US
    add     s2, s2, t1                      /* s2 = deadline_us */
4:
    li      a0, 0xFF
    call    sd_spi_xfer
    bnez    a0, 5f                          /* Non-zero -> programming complete */
    li      t0, TIMER0_BASE
    lw      t1, TIMER_RAWL_OFF(t0)
    sub     t1, t1, s2
    bltz    t1, 4b
    j       sd_write_iofail
5:
    call    sd_deselect_and_clock
    li      a0, ERR_OK
    j       sd_write_ret

sd_write_iofail:
    call    sd_deselect_and_clock
    li      a0, ERR_IO
    j       sd_write_ret
sd_write_inval:
    li      a0, ERR_INVALID_ARG
    j       sd_write_ret
sd_write_nodev:
    li      a0, ERR_NO_DEVICE
sd_write_ret:
    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
.size sd_write, . - sd_write

/* ----------------------------------------------------------------------------
 * sd_capacity() -> a0 = ERR_OK or ERR_NO_DEVICE, a1 = total 512-byte sectors
 * ---------------------------------------------------------------------------- */
.global sd_capacity
.type sd_capacity, @function
sd_capacity:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    call    sd_is_card_present
    beqz    a0, 1f
    li      t0, BIOS_SD_FLAGS_ADDR
    lw      t0, 0(t0)
    andi    t0, t0, SD_STATUS_READY
    beqz    t0, 1f
    li      t0, BIOS_SD_SECTORS_ADDR
    lw      a1, 0(t0)
    li      a0, ERR_OK
    j       2f
1:
    li      a0, ERR_NO_DEVICE
2:
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret
.size sd_capacity, . - sd_capacity
