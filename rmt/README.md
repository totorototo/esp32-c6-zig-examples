# rmt — WS2812 LEDs through the RMT peripheral on ESP32-C6 in Zig with MicroZig

Test sample for MicroZig's RMT HAL (`hal.rmt`) and its WS2812 driver (`hal.drivers.WS2812_RMT`).
It drives the on-board RGB LED from RMT channel TX0 and a 16 LED ring from TX1, checks each
frame, then rotates a rainbow on the ring. Unlike `blinky`, SPI2 stays free. Logs go to UART0
(115200 baud).

Fetches MicroZig from the `esp32-c6` branch of
[totorototo/microzig](https://github.com/totorototo/microzig), pinned in `build.zig.zon` (see the
top-level README).

## Wiring

| WS2812 ring | ESP32-C6-DevKitC-1 |
|-------------|--------------------|
| DIN         | GPIO10             |
| VCC         | 5V                 |
| GND         | GND                |

The on-board LED is on GPIO8. On hardware, a 3.3 V data line into a ring powered from 5 V is
out of spec for the WS2812; it usually works with a short wire.

## Build

    zig build -Doptimize=ReleaseSmall

Needs Zig 0.17.1. Output in `zig-out/firmware/`: `rmt.elf` and `rmt.bin` (ESP app image).
The regz warnings printed on the first build are harmless.

Build it optimized: the 16 LED frame is longer than the channel's memory (48 pulse codes, one
per bit), so the HAL refills the memory while the frame is being sent. A Debug build may be too
slow for that and report `Underrun`.

## Run

Wokwi: open `diagram.json` in VS Code with the Wokwi extension (`wokwi.toml` points at the
ELF), or run it headless as a test:

    wokwi-cli --timeout 5000 --expect-text "rmt test: PASS" --fail-text "rmt test: FAIL" .

Hardware: `espflash flash --monitor zig-out/firmware/rmt.elf`, using the board's USB-UART port.

Expected log:

    [info] rmt on ESP32-C6, cpu clock 80 MHz, rmt tick 25 ns
    [info] TX0, 1 LED: ok, 150 us (expected about 30 us)
    [info] TX1, 2 LEDs: ok, 276 us (expected about 60 us)
    [info] TX1, 16 LEDs: ok, 699 us (expected about 480 us)
    [info] rmt test: PASS

## What the test checks

| Check         | What it exercises                                                              |
|---------------|--------------------------------------------------------------------------------|
| TX0, 1 LED    | A frame that fits in the channel memory                                        |
| TX1, 2 LEDs   | A frame that fills the memory exactly: the end marker is the first refill      |
| TX1, 16 LEDs  | A streamed frame, 8 refills of half the memory                                 |

A check passes if the write returns no error and took at least its bit time (1.25 us per bit)
and at most 1.5 times that plus 300 us. The durations above are Wokwi's: the extra 120 to
220 us is the driver encoding the first memory fill before the frame starts, on a simulated
CPU that is slow compared to its timers. Expect much less on hardware. The check catches a
wrong clock source or divider and a transmission that stops early. It doesn't check the waveform: for that, the diagram has a logic analyzer on GPIO10
(D0) and GPIO8 (D1). `wokwi-cli --vcd-file rmt.vcd .` saves the trace, where a 0 bit should be
0.4 us high / 0.85 us low and a 1 bit 0.8 us high / 0.45 us low.
