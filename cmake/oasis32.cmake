# =============================================================================
# Oasis32 Shared CMake Helpers & Architectural Boundary Enforcement
# =============================================================================
# Provides:
#   1. `oasis32_abi` (INTERFACE target) exposing ONLY `include/` (public ABI).
#   2. `oasis32_preprocess_ld(...)` to preprocess `.ld.S` templates into `.ld`
#      scripts using `gcc -E -P -x c` with Ninja-compatible `DEPFILE` tracking.
#   3. `oasis32_add_bios_executable(...)` for Stage-1 BIOS (XIP Flash + UF2).
#   4. `oasis32_add_disk_executable(...)` for Stage-2 SD payloads (strictly
#      isolated to `oasis32_abi` and `include/ld/sd_payload.ld.S`).
#
# Reference: docs/BootBehavior.md §5.3-§5.4
# =============================================================================

include_guard(GLOBAL)

# -----------------------------------------------------------------------------
# 1. Public ABI Header-Only Interface Target
# -----------------------------------------------------------------------------
if (NOT TARGET oasis32_abi)
    add_library(oasis32_abi INTERFACE)
    target_include_directories(oasis32_abi INTERFACE
        "${CMAKE_SOURCE_DIR}/include"
    )
endif()

# -----------------------------------------------------------------------------
# Helper: Resolve picotool executable (imported target or Pico extension PATH)
# -----------------------------------------------------------------------------
function(_oasis32_resolve_picotool OUT_VAR)
    if (TARGET picotool)
        set(${OUT_VAR} $<TARGET_FILE:picotool> PARENT_SCOPE)
    else()
        find_program(_picotool_bin
            NAMES picotool
            HINTS
                "${USERHOME}/.pico-sdk/picotool/${picotoolVersion}/picotool"
                "$ENV{USERPROFILE}/.pico-sdk/picotool/2.3.1/picotool"
                "$ENV{HOME}/.pico-sdk/picotool/2.3.1/picotool"
            REQUIRED
        )
        set(${OUT_VAR} "${_picotool_bin}" PARENT_SCOPE)
    endif()
endfunction()

# -----------------------------------------------------------------------------
# 2. Linker Script Preprocessor (.ld.S -> .ld with DEPFILE header tracking)
# -----------------------------------------------------------------------------
# Usage:
#   oasis32_preprocess_ld(
#       OUTPUT_VAR  <var receiving generated .ld path>
#       TEMPLATE    <path/to/script.ld.S>
#       OUTPUT_NAME <generated.ld>
#       INCLUDE_DIRS <dir1> [<dir2> ...]
#   )
function(oasis32_preprocess_ld)
    cmake_parse_arguments(LD "" "OUTPUT_VAR;TEMPLATE;OUTPUT_NAME" "INCLUDE_DIRS" ${ARGN})

    set(_out_ld "${CMAKE_CURRENT_BINARY_DIR}/${LD_OUTPUT_NAME}")
    set(_out_dep "${_out_ld}.d")

    set(_inc_flags "")
    foreach(_dir IN LISTS LD_INCLUDE_DIRS)
        list(APPEND _inc_flags "-I${_dir}")
    endforeach()

    add_custom_command(
        OUTPUT "${_out_ld}"
        COMMAND ${CMAKE_C_COMPILER} -E -P -x c
                ${_inc_flags}
                -MD -MF "${_out_dep}" -MT "${_out_ld}"
                "${LD_TEMPLATE}"
                -o "${_out_ld}"
        MAIN_DEPENDENCY "${LD_TEMPLATE}"
        DEPFILE "${_out_dep}"
        COMMENT "Preprocessing linker script ${LD_OUTPUT_NAME}"
        VERBATIM
    )

    set(${LD_OUTPUT_VAR} "${_out_ld}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# 3. Stage-1 BIOS Executable Helper (Flash-resident, private HW access)
# -----------------------------------------------------------------------------
# Usage:
#   oasis32_add_bios_executable(<target> <src1.S> [<src2.S> ...])
function(oasis32_add_bios_executable TARGET_NAME)
    set(_sources ${ARGN})

    oasis32_preprocess_ld(
        OUTPUT_VAR   _bios_ld
        TEMPLATE     "${CMAKE_SOURCE_DIR}/bios/ld/bios.ld.S"
        OUTPUT_NAME  "${TARGET_NAME}.ld"
        INCLUDE_DIRS "${CMAKE_SOURCE_DIR}/include" "${CMAKE_SOURCE_DIR}/bios/internal"
    )

    add_executable(${TARGET_NAME} ${_sources} "${_bios_ld}")

    # BIOS sees both the public ABI and its own PRIVATE internal hardware maps.
    target_link_libraries(${TARGET_NAME} PRIVATE oasis32_abi)
    target_include_directories(${TARGET_NAME} PRIVATE
        "${CMAKE_SOURCE_DIR}/bios/internal"
    )

    set_target_properties(${TARGET_NAME} PROPERTIES
        LINKER_LANGUAGE ASM
        SUFFIX ".elf"
        LINK_DEPENDS "${_bios_ld}"
    )

    target_compile_options(${TARGET_NAME} PRIVATE
        -mcpu=hazard3-rp2350
        -g
    )

    target_link_options(${TARGET_NAME} PRIVATE
        -nostdlib
        -nostartfiles
        -nodefaultlibs
        -Wl,--build-id=none
        -Wl,-T,${_bios_ld}
        -Wl,-Map=$<TARGET_FILE:${TARGET_NAME}>.map
    )

    _oasis32_resolve_picotool(_picotool)

    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        COMMAND ${CMAKE_OBJDUMP} -h $<TARGET_FILE:${TARGET_NAME}> > $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.dis
        COMMAND ${CMAKE_OBJDUMP} -d $<TARGET_FILE:${TARGET_NAME}> >> $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.dis
        COMMAND ${CMAKE_OBJCOPY} -Obinary $<TARGET_FILE:${TARGET_NAME}> $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.bin
        COMMAND ${_picotool} uf2 convert --quiet $<TARGET_FILE:${TARGET_NAME}> $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.uf2 --family rp2350-riscv --platform rp2350 --abs-block
        COMMENT "Generating ${TARGET_NAME}.dis, .bin, and .uf2"
        VERBATIM
    )
endfunction()

# -----------------------------------------------------------------------------
# 4. Stage-2 SD Disk Payload Helper (Strictly Isolated to Public ABI)
# -----------------------------------------------------------------------------
# Usage:
#   oasis32_add_disk_executable(<target> <src1.S> [<src2.S> ...])
function(oasis32_add_disk_executable TARGET_NAME)
    set(_sources ${ARGN})

    oasis32_preprocess_ld(
        OUTPUT_VAR   _disk_ld
        TEMPLATE     "${CMAKE_SOURCE_DIR}/include/ld/sd_payload.ld.S"
        OUTPUT_NAME  "${TARGET_NAME}.ld"
        INCLUDE_DIRS "${CMAKE_SOURCE_DIR}/include"
    )

    add_executable(${TARGET_NAME} ${_sources} "${_disk_ld}")

    # STRICT BOUNDARY: Disks link ONLY against oasis32_abi (never bios/internal).
    target_link_libraries(${TARGET_NAME} PRIVATE oasis32_abi)

    set_target_properties(${TARGET_NAME} PROPERTIES
        LINKER_LANGUAGE ASM
        SUFFIX ".elf"
        LINK_DEPENDS "${_disk_ld}"
    )

    # Declared Oasis32 unprivileged RISC-V ISA (no CSR or vendor Xh3* extensions).
    target_compile_options(${TARGET_NAME} PRIVATE
        -march=rv32imac_zifencei
        -mabi=ilp32
        -g
    )

    target_link_options(${TARGET_NAME} PRIVATE
        -nostdlib
        -nostartfiles
        -nodefaultlibs
        -Wl,--build-id=none
        -Wl,-T,${_disk_ld}
        -Wl,-Map=$<TARGET_FILE:${TARGET_NAME}>.map
    )

    if (NOT Python3_EXECUTABLE)
        find_package(Python3 COMPONENTS Interpreter REQUIRED)
    endif()

    set(_patch_crc_script "${CMAKE_SOURCE_DIR}/cmake/patch_oa32_crc.py")

    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        COMMAND ${CMAKE_OBJDUMP} -h $<TARGET_FILE:${TARGET_NAME}> > $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.dis
        COMMAND ${CMAKE_OBJDUMP} -d $<TARGET_FILE:${TARGET_NAME}> >> $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.dis
        COMMAND ${CMAKE_OBJCOPY} -Obinary $<TARGET_FILE:${TARGET_NAME}> $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.oa32
        COMMAND ${Python3_EXECUTABLE} "${_patch_crc_script}" $<TARGET_FILE_DIR:${TARGET_NAME}>/${TARGET_NAME}.oa32
        COMMENT "Generating ${TARGET_NAME}.dis and CRC-stamped ${TARGET_NAME}.oa32 disk image"
        VERBATIM
    )
endfunction()
