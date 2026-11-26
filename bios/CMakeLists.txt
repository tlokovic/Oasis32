cmake_minimum_required(VERSION 3.13)

# =============================================================================
# Oasis32 Stage-1 System ROM / BIOS (XIP Flash-Resident)
# =============================================================================
# Built via oasis32_add_bios_executable (cmake/oasis32.cmake):
#   - Zero linked Pico SDK, C runtime, or third-party libraries
#   - Preprocesses bios/ld/bios.ld.S with DEPFILE header tracking
#   - Emits oasis32_bios.elf, .dis, .bin, and flashable .uf2

oasis32_add_bios_executable(oasis32_bios
    src/boot.S
    src/clocks.S
    src/timer.S
    src/leds.S
    src/piezo.S
    src/uart0.S
    src/font.S
    src/video.S
    src/abi_dispatch.S
    src/hardware_demo.S
    src/main.S
)
