# boot — the ESP32-C6's three boot paths, in Zig with MicroZig

Test sample for MicroZig's C6 targets. One firmware, built three times:

| Firmware                    | Target                  | Started by                                   |
|-----------------------------|-------------------------|----------------------------------------------|
| `boot_image.elf` / `.bin`   | `esp32_c6`              | ESP-IDF 2nd stage bootloader (ESP app image) |
| `boot_direct.bin`           | `esp32_c6_direct_boot`  | The ROM, from flash offset 0, no bootloader  |
| `boot_ram.elf`              | `esp32_c6_flashless`    | espflash, into RAM over serial; no flash     |

Each layout puts things in different places, so the firmware checks what the startup code
and linker script must get right: initialised data copied to RAM, zeroed data zero, RAM code
running from RAM, code and rodata where the target says (flash window, or RAM when
flashless), data writable. Logs go to UART0 (115200 baud) and end with `boot test: PASS`,
then `alive N` every second. No wiring.

## Build

    zig build -Doptimize=ReleaseSmall

## Run

Wokwi runs only `boot_image` (`wokwi.toml`): it always adds its own bootloader, and has no
serial loader.

    wokwi-cli --timeout 20000 --expect-text "boot test: PASS" --fail-text "boot test: FAIL" .

On a board:

    espflash flash --monitor zig-out/firmware/boot_image.elf
    espflash write-bin 0x0 zig-out/firmware/boot_direct.bin && espflash monitor
    espflash flash --ram --no-stub --monitor zig-out/firmware/boot_ram.elf

`--no-stub`: the flasher stub runs from the same RAM the image loads into. Writing
`boot_direct.bin` at 0x0 replaces the bootloader; `espflash flash` puts it back.

Expected log (addresses differ per variant):

    [info] boot test on ESP32-C6, direct boot
    [info] ram code at 0x4080024c, code at 0x420009d4, rodata at 0x42000e80
    [info] boot test: PASS
    [info] alive 0

## Status

`boot_image` passes in Wokwi. `boot_direct` and `boot_ram` are only checked on the host: the
direct boot binary starts with the ROM's magic words (`1d04dbae` twice) and its entry is
0x4200_0008, and the RAM image links everything in 0x4080_0000-0x4086_E610. They need a board.
Direct boot also needs the chip's `DIS_DIRECT_BOOT` eFuse left unburnt (the default).
