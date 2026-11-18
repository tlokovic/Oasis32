# Pico 2 Desert Island Computer Development Plan

## Phase 1: Test Harness for the hardware

The goal of this phase is to confirm that the hardware is working and can be driven
entirely without third-party code. This phase does *not* address the true complexity
of developing an OS from scratch. At the end of this phase, we will have two implementations
of the same test harness, one written in C++ and one in RISC-V assembly. The assembly
one will become the foundation of the OS development in Phase 2. The C++ one is there to
aid us in development, testing, and debugging the hardware, and will mostly be
ignored after that.

To avoid confounding factors in case any component is faulty or wired incorrectly, we
will attach and test one component at a time, building up progressively until we have
a working system. This way, if the addition of one component introduces faults, we will
know which component is the problem.

### Test Harness Behavior

On startup, the test harness enters a loop that does the following in a single RISC-V core:

*  Blink the Red, Green, and Blue LEDs one after the other, at intervals of one second.
*  Beep the piezo once every five seconds.
*  Print a changing message (such as a timestamp or counter value) to the serial port
   once a second.
*  Echo keystrokes from the serial port back to the serial port.
*  Display a changing pattern on the HDMI display.
*  When keyboard and mouse events appear on the CH9350, print a summary to the serial port.
*  Once a second, a 512 byte block is written to one of several blocks on the SD card, then
   read back to confirm that it can be read back correctly. 

### C++ Implemenation Constraints

The C++ implementation will be located in `test_harness/cpp/`. It will use *only* the Pico
2 SDK, and no other third party libraries. This will help "keep us honest" to the actual
goal of owning all of the code and driving the hardware without third-party code.

The C++ implementation should target the RISC-V cores, to be as close as possible in behavior
to the intended assembly implementation. (This also opens the possiblity of examining the
compiled RISC-V assembly when writing the hand-written assembly version.)

### Assembly Implementation Constraints

The assembly implementation will be located in `test_harness/asm`. It will perform the
minimal initialization to put the RISC-V cores in M mode and initialize the hardware for
the behaviors described above.

### Phase 1a: LEDs, Piezo, and Reset

In this phase, only the LEDs, Piezo, and reset button are wired up. Only the LED and piezo
behaviors above are implemented.

### Phase 1b: Serial port

In this phase, the serial port (CP2102N) is wired up. The startup code is updated
to initialize the serial port. (In the C++ implementation this may connect stdio to the port.
The assembly implementation will just access it bytewise.) The startup code should print
a startup message, then the once-a-second changing message behavior should be added.

### Phase 1c: Display

In this phase, the DVI sock is wired up, and some constant pattern is written to it.

### Phase 1d: Keyboard/Mouse

In this phase, the CH9350 is wired up, and the keyboard/mouse event summary behavior is
added.

### Phase 1e: SD Card

In this phase, the SD card breakout is wired up, and the block read/write behavior is added.

## Phase 2: OS Foundation

TODO
