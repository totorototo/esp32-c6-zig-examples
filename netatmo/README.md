# netatmo — Netatmo thermostat and valves from an ESP32-C6, in Zig with MicroZig

Talks to Netatmo's Energy API directly, over HTTPS (TLS 1.3, `../common/src/https.zig`): no
cloud relay, no Home Assistant. Netatmo has no local API, so this is the only way.

1. Joins Wi-Fi and gets the time (SNTP, for certificate dates).
2. **OAuth2:** exchanges a refresh token for an access token (`POST /oauth2/token`). Netatmo
   hands back a new refresh token every time and the old one stops working, so the board
   writes the new one to flash (NVS, namespace `netatmo`) *before* using the access token: a
   reset in between can't lose the only valid token.
3. `GET /api/homesdata`: the home, its rooms and modules (relay, thermostat, valves). The
   answer carries the heating schedules and runs to tens of KiB, more than the free RAM, so
   it is parsed while it streams in (`src/energy.zig`).
4. `GET /api/homestatus`: each room's temperature, setpoint, mode and heating demand, each
   module's battery.
5. Optionally `POST /api/setroomthermpoint`: one room set manually for 10 min, read back,
   then returned to its schedule (`mode=home`).

Logs go to UART0 (115200 baud) and end with `netatmo test: PASS` or `netatmo test: FAIL`.

## Credentials

1. On https://dev.netatmo.com, sign in with your Netatmo account, **My apps → Create**:
   any name and description. Note the **client ID** and **client secret**.
2. On the app's page, **Token generator**: tick `read_thermostat` and `write_thermostat`,
   **Generate token**, accept. Note the **refresh token** (the access token isn't needed).

These are credentials for your heating: pass them on the command line in your own terminal,
never in the source, and don't paste them anywhere.

## Build and run

    zig build -Doptimize=ReleaseSmall \
        -Dnetatmo_client_id='<id>' -Dnetatmo_client_secret='<secret>' \
        -Dnetatmo_refresh_token='<refresh token>'
    zig build test      # host tests: Netatmo parsers, HTTP framing, SNTP

Keep the single quotes: Netatmo tokens contain `|`, which an unquoted shell command treats as
a pipe. The token gets cut there, and Netatmo answers `invalid_grant`.

The first run lists the rooms with their ids. To also test writing a setpoint:

    ... -Dnetatmo_test_room=<room id> -Dnetatmo_test_temp=19.5

Wokwi: open `diagram.json` (needs internet). **Wokwi's flash starts blank on every run**, so
the rotated refresh token from one run is gone by the next, and the token you built with is
already spent. Build with `-Dnetatmo_log_token=true`: the log then prints the new refresh
token, to rebuild with before the next run. (On a board, the token lives in flash and none
of this is needed. If a token is refused with `invalid_grant`, generate a new one.)

Expected log:

    [info] (https) time: 1794341450 (Unix seconds) from pool.ntp.org
    [info] access token valid for 180 min
    [info] home `Maison` (5a327cbd...): 4 rooms, 6 modules
    [info]   room 2255031728 `Salon`: 19.6 °C, setpoint 20.0 °C (schedule), heating
    [info]   module 09:00:00:dd:ee:ff NRV `Vanne chambre`, battery high
    [info] netatmo test: PASS

## The screen

With the 2.8" ILI9341 + FT6206 touch screen, wired as in `../hue`, and on by default
(`-Dscreen=false` to go without), the board becomes a thermostat remote after the first
read. One room at a time, the whole display painted by its temperature, cold blue through
teal and amber to red:

- the room's name, the measured temperature in large type, `SET 19.0°`, the mode
  (`SCHEDULE`, `MANUAL`, `AWAY`, `FROST GUARD`...) and `HEATING` when its valves open;
- **swipe** left or right: the next room (rooms without a thermostat or valve are left out);
- **drag** up or down: the setpoint in 0.5 °C steps, shown inverted while you drag. Let go
  and it is sent as a manual setpoint for 3 hours, the Netatmo app's default;
- **tap** a room in manual mode: back to its schedule.

Each action is one HTTPS request, so the setpoint line shows `SENDING` for about a second
(about 9 s in Wokwi). The rooms are re-read every 2 minutes, and the access token is
renewed before it expires (it lasts 3 hours).

To look at the screen without credentials or a network: `-Ddemo=true` (made-up rooms and a
scripted finger that swipes, drags and taps by itself).

## Memory

Same budget as `tls`: the main stack is 160 KiB (`init_with_heap(160 * 1024)` reserves it;
the heap gets the rest, about 76 KiB, for Wi-Fi and lwIP). The home's rooms and modules
(at most 16 and 24) live in a static, not on the stack, which TLS already takes 130 KiB of.
