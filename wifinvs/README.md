# wifinvs — Wi-Fi config kept in flash, on ESP32-C6 in Zig with MicroZig

Test sample for the Wi-Fi driver's NVS callbacks: with `wifi.init(gpa, .{ .nvs = &store })`
the driver keeps its configuration in the `nvs` partition (namespace `nvs.net80211`), like
ESP-IDF with `nvs_enable`. The first boot applies a station config and joins `Wokwi-GUEST`,
then resets the CPU; the second boot reads the station SSID back from the driver right after
`wifi.init`, before applying anything. Logs go to UART0 (115200 baud). No wiring.

Fetches MicroZig from the `esp32-c6` branch of
[totorototo/microzig](https://github.com/totorototo/microzig), pinned in `build.zig.zon` (see the
top-level README).

## Build

    zig build -Doptimize=ReleaseSmall

Needs Zig 0.17.1. Output in `zig-out/firmware/`: `wifinvs.elf` and `wifinvs.bin`.

## Run

Wokwi: open `diagram.json` in VS Code with the Wokwi extension, or headless:

    wokwi-cli --timeout 90000 --expect-text "wifinvs test: PASS" --fail-text "wifinvs test: FAIL" .

Expected log:

    [info] boot 1
    [info] station ssid after init: ``
    [info] connected to `Wokwi-GUEST`
    [info] first boot: config saved, resetting
    ...
    [info] boot 2
    [info] station ssid after init: `Wokwi-GUEST`
    [info] wifinvs test: PASS

On hardware the joined network has to be `Wokwi-GUEST` for boot 1 to finish, so this is a
simulator test. In your own firmware the same option means a saved network survives reboots.

## Sharing the store

The store passed to `wifi.init` is used from the Wi-Fi task. After `wifi.init`, wrap the
application's own accesses to it in `wifi.lock_nvs()` / `wifi.unlock_nvs()`.
