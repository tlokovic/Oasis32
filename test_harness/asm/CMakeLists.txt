cmake_minimum_required(VERSION 3.13)

# =============================================================================
# Bare-Metal RISC-V Assembly Test Harness (Zero SDK / Third-Party Code)
# =============================================================================
# Assembles test_harness_asm.S and links it directly with memmap.ld using
# -nostdlib -nostartfiles -nodefaultlibs so that ZERO Pico SDK code, C runtime
# startup files, or standard libraries are linked into the image.

add_executable(test_harness_asm
    test_harness_asm.S
)

set_target_properties(test_harness_asm PROPERTIES
    LINKER_LANGUAGE ASM
    SUFFIX ".elf"
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/memmap.ld"
)

# Target the RP2350 Hazard3 RISC-V core with debug symbols for disassembly/SWD.
target_compile_options(test_harness_asm PRIVATE
    -mcpu=hazard3-rp2350
    -g
)

# Bare-metal link: no stdlib, no CRT startup files, custom memory map script.
target_link_options(test_harness_asm PRIVATE
    -nostdlib
    -nostartfiles
    -nodefaultlibs
    -Wl,--build-id=none
    -Wl,-T,${CMAKE_CURRENT_SOURCE_DIR}/memmap.ld
    -Wl,-Map=$<TARGET_FILE:test_harness_asm>.map
)

# Resolve picotool (uses the imported target if available, otherwise searches
# the VS Code Pico extension install path and system PATH).
if (TARGET picotool)
    set(ASM_PICOTOOL $<TARGET_FILE:picotool>)
else()
    find_program(ASM_PICOTOOL
        NAMES picotool
        HINTS
            "${USERHOME}/.pico-sdk/picotool/${picotoolVersion}/picotool"
            "$ENV{USERPROFILE}/.pico-sdk/picotool/2.3.1/picotool"
            "$ENV{HOME}/.pico-sdk/picotool/2.3.1/picotool"
        REQUIRED
    )
endif()

# Generate disassembly (.dis), raw binary (.bin), and flashable UF2 (.uf2)
# matching the outputs produced for test_harness_cpp.
add_custom_command(TARGET test_harness_asm POST_BUILD
    COMMAND ${CMAKE_OBJDUMP} -h $<TARGET_FILE:test_harness_asm> > $<TARGET_FILE_DIR:test_harness_asm>/test_harness_asm.dis
    COMMAND ${CMAKE_OBJDUMP} -d $<TARGET_FILE:test_harness_asm> >> $<TARGET_FILE_DIR:test_harness_asm>/test_harness_asm.dis
    COMMAND ${CMAKE_OBJCOPY} -Obinary $<TARGET_FILE:test_harness_asm> $<TARGET_FILE_DIR:test_harness_asm>/test_harness_asm.bin
    COMMAND ${ASM_PICOTOOL} uf2 convert --quiet $<TARGET_FILE:test_harness_asm> $<TARGET_FILE_DIR:test_harness_asm>/test_harness_asm.uf2 --family rp2350-riscv --platform rp2350 --abs-block
    COMMENT "Generating test_harness_asm.dis, .bin, and .uf2"
    VERBATIM
)
