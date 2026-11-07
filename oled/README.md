# oled — SSD1306 I2C display on ESP32-C6 in Zig with MicroZig

Drives a 128x64 SSD1306 OLED over I2C: a title, the bus settings, a large frame counter
and a square bouncing along the bottom. Each frame pushes the full 1 KiB framebuffer, so it
exercises the C6 I2C HAL including multi-chunk writes. Logs go to UART0 (115200 baud).

Uses the local MicroZig checkout at `../../../microzig`, which must be on the `esp32-c6` branch.

## Wiring

| OLED | ESP32-C6-DevKitC-1 |
|------|--------------------|
| SDA  | GPIO22             |
| SCL  | GPIO23             |
| VCC  | 3V3                |
| GND  | GND                |

Address 0x3C (most modules; some use 0x3D). GPIO4-7 (JTAG) and GPIO8/9/15 (strapping) are avoided.

## Build

    zig build -Doptimize=ReleaseSmall

Needs Zig 0.17.1. Output in `zig-out/firmware/`: `oled.elf` and `oled.bin` (ESP app image).
The regz warnings printed on the first build are harmless.

## Run

Wokwi: open `diagram.json` in VS Code with the Wokwi extension (`wokwi.toml` points at the ELF).

Hardware: `espflash flash --monitor zig-out/firmware/oled.elf`, using the board's USB-UART port.

Expected log:

    [info] oled on ESP32-C6, cpu clock 80 MHz
    [info] SSD1306 ready at 0x3C, I2C 400 kHz
    [info] frame 0: framebuffer write took ... us

At 400 kHz, a frame write should take about 23 ms on hardware (1025 bytes × 9 clocks). A much
smaller number means the I2C clock is wrong. Wokwi doesn't model bus timing, so check this on
a real board.
