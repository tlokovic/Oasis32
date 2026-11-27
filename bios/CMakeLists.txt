cmake_minimum_required(VERSION 3.13)

# =============================================================================
# Oasis32 Stage-1 System ROM / BIOS (XIP Flash-Resident)
# =============================================================================
# Built via oasis32_add_bios_executable (cmake/oasis32.cmake):
#   - Zero linked Pico SDK, C runtime, or third-party libraries
#   - Preprocesses bios/ld/bios.ld.S with DEPFILE header tracking
#   - Emits oasis32_bios.elf, .dis, .bin, and flashable .uf2

if (NOT Python3_EXECUTABLE)
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
endif()

set(_splash_bmp "${CMAKE_SOURCE_DIR}/images/splash.bmp")
set(_splash_bin "${CMAKE_CURRENT_BINARY_DIR}/splash.bin")
set(_bmp_to_fb_script "${CMAKE_SOURCE_DIR}/cmake/bmp_to_fb.py")

add_custom_command(
    OUTPUT "${_splash_bin}"
    COMMAND ${Python3_EXECUTABLE} "${_bmp_to_fb_script}" "${_splash_bmp}" "${_splash_bin}"
    MAIN_DEPENDENCY "${_splash_bmp}"
    DEPENDS "${_bmp_to_fb_script}"
    COMMENT "Converting images/splash.bmp to 640x480 1bpp framebuffer"
    VERBATIM
)

set_source_files_properties(src/splash.S PROPERTIES
    OBJECT_DEPENDS "${_splash_bin}"
    COMPILE_OPTIONS "-Wa,-I${CMAKE_CURRENT_BINARY_DIR}"
)

oasis32_add_bios_executable(oasis32_bios
    src/boot.S
    src/clocks.S
    src/sys.S
    src/timer.S
    src/leds.S
    src/piezo.S
    src/uart0.S
    src/input.S
    src/sd.S
    src/font.S
    src/video.S
    src/text.S
    src/abi_dispatch.S
    src/startup_tune.S
    src/splash.S
    src/bootloader.S
    src/hardware_demo.S
    src/main.S
)
