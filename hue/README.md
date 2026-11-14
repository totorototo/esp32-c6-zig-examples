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
   - Touch screen (default, see below), rooms first:
     - **Home**: `ROOMS | LIGHTS` tabs, five rows a page. A row's switch (left) turns it
       on or off; the rest of the row (marked `>`) opens it. Page with `<` `>` or a swipe.
     - **A room or a light**: a tile in its colour, at its brightness. Tap it: on/off.
       Slide sideways on it: brightness (the whole tile's width is the range; sliding an
       off room turns it on). Press and hold it, or tap COLOUR: the colour field (hue
       across, white at the bottom). Let go to set; let go on the bottom strip to cancel.
       A room also has SCENES (each in its own colours; tap one to recall it, the last
       one recalled is marked) and LIGHTS (its lights, each opening its own page).
     - `<`, or a swipe right (on a list's first page), goes back.

     Scenes that belong to no room (old app LightScenes) aren't on the screen.

     Touches act on release: the row or button under the finger lights up, and sliding
     off it cancels. Changes show at once and are sent right after; if the bridge doesn't
     take one, the screen goes back and says NOT SENT. While sliding, the bridge gets the
     latest value at most every 150 ms (it handles about 10 commands/s per light), plus
     the final value on release. The light or room last opened is saved, and the screen
     reopens on it.
     - After 30 s without a touch the backlight dims; the touch that wakes it does
       nothing else, so brushing past a remote on a wall doesn't switch the lights.
   - Web remote on port 80, on what's selected: on/off, a brightness slider, and a colour
     picker (hidden for white-only lights). `GET /state` returns JSON;
     `POST /set?on=1&bri=200&hue=8000&sat=254` applies any subset of the parameters.
     Every POST needs an `X-Hue-Remote` header (any value, e.g. `curl -H 'X-Hue-Remote: 1'`):
     without it any web page you open could send them, since browsers don't ask before a
     bodiless cross-site POST but do ask before one with a custom header.
   - The on-board LED (WS2812 on GPIO8, driven by RMT so it works next to the screen)
     shows the status (blue = starting or searching, orange = waiting for you, green =
     done, red = error), then mirrors the selected light or room.
   - What's on screen is refreshed every 5 s and on every page change, so changes made
     from the Hue app show up (not in the 1.5 s after a change, when the bridge still
     reports the old state). Two failed refreshes in a row show BRIDGE OFFLINE along the
     bottom, over a page that stays usable, until one works.

   Everything runs in one loop: `netconn_accept` with a 20 ms timeout doubles as the
   touch polling tick, so there is no second task and no locking. A web client gets
   150 ms to start its request, so an idle browser connection can't freeze the screen.
   (Wi-Fi reconnects by itself, in ../common's own task.)

**When something is wrong**, the board says so on the screen and the LED, and never
panics. What can pass (no bridge yet, bridge not answering) is retried every 10 s. What
needs you (a `-Dhue_user` the bridge rejects, an unknown `-Dhue_light`) stays on screen
until you rebuild.

**The BOOT button:** a short press turns every light off. Held 3 s, the screen asks
FORGET / CANCEL; held 10 s (or with no touch screen, in the field UI, or while the board is
still looking for the bridge), or `curl -X POST -H 'X-Hue-Remote: 1' http://<board>/forget`, it doesn't ask. The
board forgets the bridge, the username and the selection, and restarts.

## Experimental: the field UI (`-Dui=field`)

No buttons and no lists: the screen *is* the light. One room fills the whole display in
its own colour, at its own brightness, with its name and level in large type.

- **Swipe** left or right: next or previous room, with a colour wipe. Dots show where you are.
- **Drag** up or down: brightness. The screen dims with you, and the bridge follows.
- **Tap:** on or off.
- **Press and hold:** the screen turns into a colour field (hue across, saturation down,
  white at the bottom). Slide to a colour and let go to set it, or let go on the bottom
  strip to cancel.
- **Swipe up from the bottom edge** (where the dots and `^ SCENES` are): the room's scenes,
  each a full-width band painted in the scene's own colours (the average of what it sets
  its lights to, read from `/scenes/<id>` one scene per tick and cached). Tap a band to
  recall it; swipe up or down to page; swipe down on the first page to go back.

It browses rooms (lights only when the bridge has no rooms). The web remote and the LED
follow the room on screen. `-Ddemo=true` runs either UI on made-up rooms without Wi-Fi
or a bridge, and in the field UI a scripted finger plays every gesture once, so it can be
watched (and screenshotted) in Wokwi:

    zig build -Doptimize=ReleaseSmall -Dui=field -Ddemo=true -Dled_level=255

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
| D/C       | GPIO21   | | LED    | GPIO3    |
| RST       | GPIO2    | | GND    | GND      |

MISO and the touch INT pin stay unconnected. The screen takes SPI2, the C6's only
general-purpose SPI; the on-board LED is on RMT, the backlight on LEDC PWM. A breakout whose
LED pin drives the backlight through a transistor (Adafruit's does) is fine on a GPIO; on a
bare panel, put one in. If touches land mirrored on a real panel, flip the
axes in `src/ft6206.zig` `read`.

## Build

    zig build -Doptimize=ReleaseSmall                       # find, pair, remember
    zig build -Doptimize=ReleaseSmall -Dhue_ip=192.168.1.20 # skip the search
    zig build test                                          # host tests (mDNS, scenes, bridge API, common's)

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
