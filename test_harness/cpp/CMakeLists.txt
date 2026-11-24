cmake_minimum_required(VERSION 3.13)

# Add executable. Default name is the project name, version 0.1

add_executable(test_harness_cpp
    test_harness_cpp.c
    )

# pull in common dependencies
target_link_libraries(test_harness_cpp
    pico_stdlib
    hardware_pwm
)

if (PICO_CYW43_SUPPORTED)
    target_link_libraries(test_harness_cpp pico_cyw43_arch_none)
endif()

# create map/bin/hex file etc.
pico_add_extra_outputs(test_harness_cpp)

# add url via pico_set_program_url
