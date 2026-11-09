# weblight — browser-controlled RGB LED on ESP32-C6 in Zig with MicroZig

Joins Wi-Fi and serves a small web page that switches the on-board RGB LED of an
ESP32-C6-DevKitC-1 (WS2812 on GPIO8) on and off and sets its colour.

Fetches MicroZig from the `esp32-c6` branch of
[totorototo/microzig](https://github.com/totorototo/microzig), pinned in `build.zig.zon`, with
its `modules/lwip` and `modules/foundation-libc` (see the top-level README). `src/lwip/` is the
lwIP glue from MicroZig's `tcp_server` example, with `LWIP_SO_RCVTIMEO` turned on.

## Build

    zig build -Doptimize=ReleaseSmall                                   # Wokwi-GUEST (open)
    zig build -Doptimize=ReleaseSmall -Dssid=MyWifi -Dpassword=secret   # your network

Credentials are build options, so they never end up in the source. Needs Zig 0.17.1.

## HTTP API (port 80)

| Request | Effect |
|---|---|
| `GET /` | The control page |
| `GET /state` | `{"on":true,"r":255,"g":96,"b":0}` |
| `POST /set?on=1&r=255&g=0&b=0` | Applies any subset of the parameters, returns the state |

    curl -X POST 'http://localhost:8080/set?on=1&r=0&g=0&b=255'

The server handles one connection at a time and closes it after each response.

## Run

Wokwi: open `diagram.json`, wait for `open http://...` in the serial monitor, then browse to
http://localhost:8080/ (forwarded by `wokwi.toml`).

Hardware: `espflash flash --monitor zig-out/firmware/weblight.elf`, then open the logged
address from a device on the same network. Logs go to UART0 (115200 baud).
