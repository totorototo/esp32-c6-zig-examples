# hue — toggle a Philips Hue light from an ESP32-C6, in Zig with MicroZig

Talks to the Hue bridge's local API v1 over plain HTTP. No cloud and no TLS: API v2 is
HTTPS-only, and there is no TLS stack in the firmware.

1. At boot, fetches `/api/config` and logs the bridge name. This needs no pairing.
2. **Pairing mode** (no `-Dhue_user`): press the round link button on the bridge. For 60 s the
   board retries `POST /api`, then logs the username to rebuild with.
3. **Lights** (`-Dhue_user`): logs every light, room and zone with its id, name and state.
4. **Control** (`-Dhue_user`, plus `-Dhue_light` without the screen):
   - Web remote on port 80: on/off, a brightness slider, and a colour picker (hidden for
     white-only lights). `GET /state` returns JSON; `POST /set?on=1&bri=200&hue=8000&sat=254`
     applies any subset of the parameters.
   - Touch screen (default, see below), two pages:
     - **List**: `LIGHTS | ROOMS` tabs (rooms and zones from the bridge's `/groups`), six
       rows a page with `< 1/2 >` paging. Tap a row's swatch to toggle it, its name to
       open its settings.
     - **Settings**: `<` back, tap ON/OFF, drag the brightness bar or the colour strip,
       tap WHITE. A room or zone is set through `/groups/<id>/action`, all its lights
       at once.

     While you drag, the screen follows your finger and the bridge gets the latest value
     at most every 150 ms (it handles about 10 commands/s per light), plus the final value
     on release.
   - The web remote acts on what's selected on the screen (or on `-Dhue_light`).
     `-Dhue_light` is optional with the screen: it only picks the page to boot on.
   - What's on screen is refreshed every 5 s and on every page change, so changes made
     from the Hue app show up.

   Everything runs in one loop: `netconn_accept` with a 20 ms timeout doubles as the
   touch polling tick, so there is no second task and no locking.

Status (starting, pairing, done, error) shows on the screen. With `-Dscreen=false`, the
on-board LED shows it instead (blue = starting, orange = pairing, green = done or idle,
red = error) and, in control mode, mirrors the light's colour.

## Touch screen

A 2.8" ILI9341 240x320 SPI TFT with an FT6206/FT6236 capacitive touch controller on I2C
(e.g. Adafruit's 2.8" capacitive breakout; Wokwi part `board-ili9341-cap-touch`).

| Screen    | ESP32-C6 | | Screen | ESP32-C6 |
|-----------|----------|-|--------|----------|
| SCK       | GPIO19   | | SDA    | GPIO22   |
| MOSI      | GPIO18   | | SCL    | GPIO23   |
| CS        | GPIO20   | | VCC    | 3V3      |
| D/C       | GPIO21   | | LED    | 3V3      |
| RST       | GPIO2    | | GND    | GND      |

MISO and the touch INT pin stay unconnected. The C6 has a single general-purpose SPI (SPI2)
and the screen takes it, so the WS2812 LED stays dark. If touches land mirrored on a
real panel, flip the axes in `src/ft6206.zig` `read`.

## Build

    zig build -Doptimize=ReleaseSmall                                     # pairing mode
    zig build -Doptimize=ReleaseSmall -Dhue_user=<username>               # screen: list page
    zig build -Doptimize=ReleaseSmall -Dhue_user=<username> -Dhue_light=3 # open on light 3

Other options: `-Dscreen=false` (no touch screen; the LED mirrors the light instead),
`-Dhue_ip=` (default `192.168.1.125`), `-Dssid=`, `-Dpassword=` (default `Wokwi-GUEST`, open). The username is a bridge credential: keep it on the command line, never
in the source.

## Run

Wokwi (setup in the top-level README): open `diagram.json`. The touch screen is wired as
above (click it to touch), and the web remote is forwarded to http://localhost:8080/.

The simulated board needs to reach your real bridge, so run it from the VS Code extension
(its gateway routes the board's traffic through your computer) with `-Dhue_ip=` set to the
bridge's address. On macOS 15+, allow VS Code under System Settings → Privacy & Security →
Local Network, or the connection is refused. Step 1 (the bridge name in the log) shows
whether it works. `wokwi-cli` runs in Wokwi's cloud and can't reach your LAN.

Hardware: `espflash flash --monitor zig-out/firmware/hue.elf` (logs on UART0, 115200 baud),
with `-Dssid`/`-Dpassword` set to your Wi-Fi.
