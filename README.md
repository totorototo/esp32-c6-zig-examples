# ESP32-C6 examples in Zig with MicroZig

Small firmware projects for the ESP32-C6-DevKitC-1, written in Zig on top of
[MicroZig](https://github.com/ZigEmbeddedGroup/microzig). Each one runs in the
[Wokwi](https://wokwi.com) simulator (Wi-Fi included), so no hardware is needed to try them.

| Example                  | What it shows                                                                    |
|--------------------------|----------------------------------------------------------------------------------|
| [`blinky`](blinky)       | The on-board WS2812 RGB LED through SPI2, logs over USB-Serial-JTAG               |
| [`nvs`](nvs)             | Settings that survive a reset: flash driver and ESP-IDF's NVS format, self-check   |
| [`oled`](oled)           | An SSD1306 128x64 display over I2C, with a 5x7 font                               |
| [`rmt`](rmt)             | WS2812 LEDs through RMT: the on-board LED and a 16 LED ring, with a self-check    |
| [`weblight`](weblight)   | Wi-Fi + lwIP: a web page that sets the RGB LED's colour                           |
| [`hue`](hue)             | A Philips Hue remote: bridge pairing, local API, web remote, ILI9341 touch screen |
| [`wifinvs`](wifinvs)     | Wi-Fi config and PHY calibration kept in NVS: saved by one boot, reused by the next |

Each directory is its own Zig package: `cd` into it and follow its README.

[`common`](common) is not an example: it holds the networking code `weblight` and `hue`
share (Wi-Fi bring-up, lwIP's OS glue and `lwipopts.h`, small HTTP helpers). They depend on it
by path and call `common.add_net(...)` from their `build.zig`, which builds lwIP and adds a
`net` module to the firmware. To copy one of them out of this repo, take `common/` along.

## Requirements

- Zig **0.17.1** exactly (`minimum_zig_version`; MicroZig tracks Zig closely).
- To simulate: [Wokwi for VS Code](https://docs.wokwi.com/vscode/getting-started) (see below).
- To flash: [`espflash`](https://github.com/esp-rs/espflash),
  e.g. `espflash flash --monitor zig-out/firmware/<name>.elf`.

## Simulating with Wokwi

1. Install the Wokwi Simulator extension in VS Code and activate its free license
   (command palette: **Wokwi: Request a New License**).
2. Build the example first: `zig build -Doptimize=ReleaseSmall` in its directory. Each
   `wokwi.toml` points at `zig-out/firmware/<name>.elf`, so nothing runs until it exists.
3. Open the example's `diagram.json` and start the simulation (**Wokwi: Start Simulator**,
   or the play button on the diagram). UART0 logs show in the serial monitor.

Wi-Fi: the default build options join `Wokwi-GUEST`, the simulator's open access point, so
`weblight` and `hue` need no credentials there. Their web pages are forwarded to
http://localhost:8080/ by `[[net.forward]]` in `wokwi.toml`.

Headless runs (CI, scripts): `wokwi-cli` with a token from
https://wokwi.com/dashboard/ci in `WOKWI_CLI_TOKEN`, e.g.
`wokwi-cli --timeout 20000 --screenshot-part lcd1 --screenshot-time 19000 hue`. It simulates
in Wokwi's cloud, so it can't reach devices on your network (the Hue bridge).

## MicroZig fork

Upstream MicroZig doesn't support the ESP32-C6 yet. These examples build against the
`esp32-c6` branch of [totorototo/microzig](https://github.com/totorototo/microzig), a fork
kept as one branch rebased on upstream `main`. Each `build.zig.zon` pins a commit of it, so a
build fetches exactly that commit:

    .microzig = .{
        .url = "git+https://github.com/totorototo/microzig#<commit>",
        .hash = "...",
    },

The fork's root `build.zig.zon` differs from upstream so it can be fetched by git URL: it
includes the whole tree and exposes `modules/lwip` and `modules/foundation-libc`, which
`common/build.zig` reaches through `mz_dep.builder.lazyDependency(...)`.

To move every example to a newer commit of the fork:

    for d in blinky nvs oled rmt weblight hue wifinvs; do
        (cd $d && zig fetch --save=microzig "git+https://github.com/totorototo/microzig#<commit>")
    done

If the fork falls behind upstream or changes its API, these examples stop building until
they're updated: the pin keeps old builds reproducible, nothing more.

## License

MIT, see [LICENSE](LICENSE). Third-party material and its licenses are listed in
[NOTICE](NOTICE).
