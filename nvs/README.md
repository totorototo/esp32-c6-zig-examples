# nvs — settings that survive a reset, on ESP32-C6 in Zig with MicroZig

Test sample for MicroZig's flash driver (`hal.flash`), partition table reader
(`hal.flash.partition_table`) and NVS store (`hal.flash.nvs`), which uses ESP-IDF's NVS format.
It counts boots, stores a string, an integer and a 6000 byte blob, resets the chip, and checks
after the reset that everything is still there. Logs go to UART0 (115200 baud). No wiring.

Fetches MicroZig from the `esp32-c6` branch of
[totorototo/microzig](https://github.com/totorototo/microzig), pinned in `build.zig.zon` (see the
top-level README).

## Build

    zig build -Doptimize=ReleaseSmall

Needs Zig 0.17.1. Output in `zig-out/firmware/`: `nvs.elf` and `nvs.bin` (ESP app image).
The regz warnings printed on the first build are harmless.

## Run

Wokwi: open `diagram.json` in VS Code with the Wokwi extension (`wokwi.toml` points at the
ELF), or run it headless as a test:

    wokwi-cli --timeout 20000 --expect-text "nvs test: PASS" --fail-text "nvs test: FAIL" .

Hardware: `espflash flash --monitor zig-out/firmware/nvs.elf`. The sample writes to the `nvs`
partition of the partition table, which espflash's default table has at 0x9000 (24 KiB).

Expected log, with the reset in the middle:

    [info] nvs on ESP32-C6
    [info] partition nvs: type 1 subtype 2 at 0x9000, 24 KiB
    ...
    [info] boot 1
    [info] first boot: values stored, resetting
    [info] nvs on ESP32-C6
    ...
    [info] boot 2
    [info] values read back after the reset
    [info] 600 updates in ... ms
    [info] nvs test: PASS

In Wokwi the flash starts blank on every simulation start, so the run always begins at boot 1.
On hardware the counter keeps growing across power cycles; from the second power-up on there
is no reset and the checks run straight away. `espflash erase-parts nvs` (or erasing the
flash) starts over.

## What the test checks

| Check                    | What it exercises                                                    |
|--------------------------|----------------------------------------------------------------------|
| Partition list           | Reading the partition table through the ROM flash driver             |
| Values after the reset   | Flash writes really reach the chip; string, integer, chunked blob    |
| Missing key, wrong type  | Error reporting                                                      |
| 600 counter updates      | Filling the partition several times: page reclaim and sector erase   |
| Reopen                   | The store initializes from what is in flash                          |

The NVS format itself is tested on the host in MicroZig (`zig build test` in
`port/espressif/esp`), including a power cut after every flash operation, and against images
made by Espressif's `esp-idf-nvs-partition-gen`. This sample adds what only the chip can show:
the flash driver.
