# hue — toggle a Philips Hue light from an ESP32-C6, in Zig with MicroZig

Talks to the Hue bridge's local API v1 over plain HTTP. No cloud and no TLS: API v2 is
HTTPS-only, and there is no TLS stack in the firmware.

1. At boot, fetches `/api/config` and logs the bridge name. This needs no pairing.
2. **Pairing mode** (no `-Dhue_user`): press the round link button on the bridge. For 60 s the
   board retries `POST /api`, then logs the username to rebuild with.
3. **Lights** (`-Dhue_user`): logs every light's id, name and state.
4. **Control** (`-Dhue_light` too):
   - BOOT button (GPIO9): a short press toggles the light, a long press steps the brightness
     (25 → 50 → 75 → 100 %, repeating every 0.6 s while held).
   - Web remote on port 80: on/off, a brightness slider, and a colour picker (hidden for
     white-only lights). `GET /state` returns JSON; `POST /set?on=1&bri=200&hue=8000&sat=254`
     applies any subset of the parameters.
   - The on-board LED mirrors the light's colour and brightness (dimmed). State is refreshed
     every 5 s, so changes made from the Hue app show up.

   Everything runs in one loop: `netconn_accept` with a 20 ms timeout doubles as the
   button-polling tick, so there is no second task and no locking.

On-board LED: blue = starting, orange = pairing, green = done or idle, red = error; in
control mode, it shows the light's colour.

## Build

    zig build -Doptimize=ReleaseSmall                                     # pairing mode
    zig build -Doptimize=ReleaseSmall -Dhue_user=<username>               # list lights
    zig build -Doptimize=ReleaseSmall -Dhue_user=<username> -Dhue_light=3 # toggle light 3

Other options: `-Dhue_ip=` (default `192.168.1.125`), `-Dssid=`, `-Dpassword=` (default
`Wokwi-GUEST`, open). The username is a bridge credential: keep it on the command line, never
in the source.

## Run

Wokwi: open `diagram.json`. The green pushbutton is wired to GPIO9, and the web remote is
forwarded to http://localhost:8080/. The simulated board reaches
the bridge only if Wokwi routes its traffic through your Mac's network; step 1 shows whether it does.

Hardware: `espflash flash --monitor zig-out/firmware/hue.elf` (logs on UART0, 115200 baud),
with `-Dssid`/`-Dpassword` set to your Wi-Fi.
