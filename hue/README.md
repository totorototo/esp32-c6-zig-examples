# hue — a Philips Hue remote on an ESP32-C6, in Zig with MicroZig

Talks to the Hue bridge's local API v1 over plain HTTP. No cloud and no TLS: API v2 is
HTTPS-only, and there is no TLS stack in the firmware.

1. **Find the bridge:** `-Dhue_ip` if given, else the address saved in flash (if the bridge
   still answers there), else an mDNS search for `_hue._tcp.local` on the LAN. The bridge
   that answers `/api/config` (no pairing needed) is logged and saved.
2. **Get a username:** `-Dhue_user` if given, else the one saved in flash, else **pairing**:
   press the round link button on the bridge, whenever you get to it: the board retries
   `POST /api` every 2 s until it works. The new username is saved, so this happens once. If the bridge later rejects a saved
   username (deleted in the Hue app), the board forgets it and pairs again.
3. **Lists** every light, room, zone and scene in the log.
4. **Control:**
   - Touch screen (default, see below), two pages:
     - **List**: `LIGHTS | ROOMS | SCENES` tabs, six rows a page with `< 1/2 >` paging.
       On lights and rooms, tap a row's swatch to toggle it, its name to open its
       settings. On scenes (each with its room below its name), tap a row to recall the
       scene on that room; the last one recalled is highlighted, and the room's state is
       re-read right away. The first row, `<  ROOM  >`, steps through ALL ROOMS and each
       room with scenes; opening a room picks its scenes.
     - **Settings**: `<` back, tap ON/OFF, drag the brightness bar or the colour strip,
       tap WHITE. A room or zone is set through `/groups/<id>/action`, all its lights
       at once.

     While you drag, the screen follows your finger and the bridge gets the latest value
     at most every 150 ms (it handles about 10 commands/s per light), plus the final value
     on release. The light or room last opened is saved, and the screen reopens on it.
   - Web remote on port 80, on what's selected: on/off, a brightness slider, and a colour
     picker (hidden for white-only lights). `GET /state` returns JSON;
     `POST /set?on=1&bri=200&hue=8000&sat=254` applies any subset of the parameters.
   - The on-board LED (WS2812 on GPIO8, driven by RMT so it works next to the screen)
     shows the status (blue = starting or searching, orange = waiting for you, green =
     done, red = error), then mirrors the selected light or room.
   - What's on screen is refreshed every 5 s and on every page change, so changes made
     from the Hue app show up.

   Everything runs in one loop: `netconn_accept` with a 20 ms timeout doubles as the
   touch polling tick, so there is no second task and no locking.

**When something is wrong**, the board says so on the screen and the LED, and never
panics. What can pass (no bridge yet, bridge not answering) is retried every 10 s. What
needs you (a `-Dhue_user` the bridge rejects, an unknown `-Dhue_light`) stays on screen
until you rebuild.

**Starting over:** hold the BOOT button for 3 s (or `curl -X POST http://<board>/forget`).
The board forgets the bridge, the username and the selection, and restarts.

## What is saved

In the flash's `nvs` partition, namespace `hue`, in ESP-IDF's NVS format (`src/settings.zig`):
`bridge_ip`, `user` and `selected`. The username is a bridge credential, and NVS here is
not encrypted: anyone holding the board can read it. It only works on your LAN, and
deleting it in the Hue app (Settings → Apps) revokes it.

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

MISO and the touch INT pin stay unconnected. The screen takes SPI2, the C6's only
general-purpose SPI; the LED is on RMT. If touches land mirrored on a real panel, flip the
axes in `src/ft6206.zig` `read`.

## Build

    zig build -Doptimize=ReleaseSmall                       # find, pair, remember
    zig build -Doptimize=ReleaseSmall -Dhue_ip=192.168.1.20 # skip the search
    zig build test                                          # host tests (mDNS, scenes JSON)

Options:
- `-Dhue_ip=`, `-Dhue_user=`: win over what is saved (and get saved).
- `-Dhue_light=<id>`: open on that light. Required with `-Dscreen=false`, unless a selection
  is saved.
- `-Dscreen=false`: no touch screen.
- `-Dled_level=1..255` (default 40): LED brightness. Use 255 in Wokwi, which draws the raw
  value, so dim levels look black there.
- `-Dssid=`, `-Dpassword=`: Wi-Fi (default `Wokwi-GUEST`, open).

Keep credentials on the command line, never in the source.

## Run

Wokwi (setup in the top-level README): open `diagram.json`. The touch screen is wired as
above (click it to touch), and the web remote is forwarded to http://localhost:8080/.

The simulated board needs to reach your real bridge, so run it from the VS Code extension
(its gateway routes the board's traffic through your computer). On macOS 15+, allow VS Code
under System Settings → Privacy & Security → Local Network, or the connection is refused.
Two things differ from a board:
- The mDNS search probably doesn't cross the gateway: pass `-Dhue_ip=`.
- Wokwi's flash starts blank on every run, so nothing stays saved. Pairing logs the
  username once: rebuild with `-Dhue_user=<it>` to skip pairing on later runs.

`wokwi-cli` runs in Wokwi's cloud and can't reach your LAN: there the board searches, finds
nothing, and shows NO BRIDGE FOUND / RETRYING. CI checks that it gets that far.

The board never gives up on the bridge: it retries every 10 s (saved address, then a
search), so after a power cut it reconnects once the bridge has booted.

Hardware: `espflash flash --monitor zig-out/firmware/hue.elf` (logs on UART0, 115200 baud),
with `-Dssid`/`-Dpassword` set to your Wi-Fi. Pair once; after that it boots straight into
the remote.
