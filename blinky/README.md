# blinky — ESP32-C6 in Zig with MicroZig

Blinks the on-board RGB LED of an ESP32-C6-DevKitC-1 (WS2812 on GPIO8, driven through SPI2)
and logs over the USB-Serial-JTAG port.

Fetches MicroZig from the `esp32-c6` branch of
[totorototo/microzig](https://github.com/totorototo/microzig), pinned in `build.zig.zon` (see the
top-level README).

## Build

    zig build -Doptimize=ReleaseSmall

Needs Zig 0.17.1. Output in `zig-out/firmware/`: `blinky.elf` and `blinky.bin` (ESP app image).

regz prints warnings during the first build (unknown arch `RV32IMAC`, a few skipped
MCPWM/PCNT fields); they're harmless.

## Flash

The image boots through the ESP-IDF 2nd stage bootloader, which espflash provides:

    cargo install espflash
    espflash flash --monitor zig-out/firmware/blinky.elf

Expected log:

    blinky on ESP32-C6, cpu clock 80 MHz
    blink 0
    blink 1
    ...

## Simulate

    wokwi-cli --timeout 5000 .

(or the Wokwi VS Code extension). The log goes to USB-Serial-JTAG, which Wokwi may not show;
the LED on the board is the thing to watch.
