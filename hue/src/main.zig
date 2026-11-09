//! hue: toggle a Philips Hue light from the ESP32-C6 through the bridge's local API.
//!
//!   1. Fetches `/api/config` and logs the bridge name (no pairing needed).
//!   2. Without `-Dhue_user`: pairing mode. Press the bridge's link button; the board logs
//!      the username to rebuild with.
//!   3. With `-Dhue_user`: logs the lights, rooms and zones, then controls them:
//!      - Touch screen (ILI9341 + FT6206, `-Dscreen=true`, the default): a list of lights
//!        and rooms, and a settings page for the one picked (on/off, brightness, colour).
//!        `-Dhue_light` opens on that light. It also shows boot and pairing status.
//!      - Web remote on port 80, on the selected entry: on/off, brightness, colour.
//!      - Without the screen, `-Dhue_light` picks the light and the on-board LED mirrors it.
//!      What's on screen is refreshed every 5 s.
//! Logs go to UART0 (115200 baud).
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");
const net = @import("net");
const hue = @import("hue.zig");
const web = net.web;
const ui = @import("ui.zig");
const catalog = @import("catalog.zig");
const screen = @import("screen.zig");
const ili9341 = @import("ili9341.zig");
const ft6206 = @import("ft6206.zig");
const lwip = net.lwip;

const hal = microzig.hal;
const gpio = hal.gpio;
const rtos = hal.rtos;
const radio = hal.radio;
const WS2812 = microzig.drivers.led.WS2812;
const Color = microzig.drivers.led.ws2812.Color;

comptime {
    _ = net.exports;
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
    .logFn = uart_log,
});

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{ .wifi = .{ .on_packet_received = net.on_packet_received } },
    },
};

var log_mutex: rtos.Mutex = .{};
var log_buf: [256]u8 = undefined;

fn uart_log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&log_buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

const devicetype = "microzig_hue#esp32c6";
const poll_ms = 20;
const refresh_ms = 5000;

// Touch screen wiring. GPIO22/23 match the OLED demo; none of these are strapping, JTAG or
// USB pins. MISO and the touch INT pin stay unconnected; the backlight goes to 3V3.
const screen_pins: ili9341.Pins = .{
    .sck = gpio.num(19),
    .mosi = gpio.num(18),
    .cs = gpio.num(20),
    .dc = gpio.num(21),
    .rst = gpio.num(2),
};
const touch_sda = gpio.num(22);
const touch_scl = gpio.num(23);

const Led = WS2812(.{ .max_led_count = 1, .DatagramDevice = hal.drivers.SPI_Device });
var led: Led = undefined;

var heap: microzig.Allocator = undefined;

pub fn main() !void {
    std.log.info("hue on ESP32-C6, bridge {s}", .{config.hue_ip});
    if (config.screen) {
        ili9341.init(screen_pins);
        if (ft6206.init(touch_sda, touch_scl)) {
            screen.touch_ok = true;
        } else |err| std.log.warn("touch controller not found ({t}): screen is display-only", .{err});
    } else init_led();
    status(.busy, "CONNECTING");

    heap = try .init_with_heap(16384);
    try net.up(heap.allocator());

    const bridge = try hue.Bridge.init(config.hue_ip);
    {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        const cfg = hue.get_config(arena.allocator(), bridge) catch |err| {
            std.log.err("bridge at {s} not reachable: {t}", .{ config.hue_ip, err });
            status(.failed, "BRIDGE NOT\nREACHABLE");
            return err;
        };
        std.log.info("bridge `{s}` id {s}, API {s}", .{ cfg.name, cfg.bridgeid, cfg.apiversion });
    }

    if (config.hue_user.len == 0) return pair(bridge);

    const ctx: catalog.Context = .{ .bridge = bridge, .user = config.hue_user, .allocator = heap.allocator() };
    catalog.refresh(ctx, .light) catch |err| {
        // The common cause: a username from another bridge, or one deleted in the Hue app.
        if (err == error.BridgeError) std.log.err("rebuild without -Dhue_user to pair again", .{});
        status(.failed, "BRIDGE REJECTED\nTHE USERNAME");
        return err;
    };
    catalog.refresh(ctx, .group) catch |err| std.log.warn("rooms and zones not read: {t}", .{err});
    catalog.log_all();

    if (config.hue_light.len > 0) {
        if (!catalog.select_id(.light, config.hue_light)) {
            std.log.err("no light {s} on this bridge", .{config.hue_light});
            status(.failed, "NO SUCH LIGHT\nSEE THE LOG");
            return error.NoSuchLight;
        }
        if (config.screen) screen.open(catalog.selected().?);
    } else if (!config.screen) {
        // Without the screen, nothing else can pick a light.
        std.log.info("rebuild with -Dhue_light=<id> to control one of these", .{});
        status(.ok, "LIGHTS LISTED\nSEE THE LOG");
        return;
    }
    try control(ctx);
}

fn pair(bridge: hue.Bridge) !void {
    std.log.info("pairing: press the round link button on the bridge (trying for 60 s)", .{});
    status(.waiting, "PRESS THE LINK\nBUTTON ON BRIDGE");
    for (0..30) |_| {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        if (try hue.create_user(arena.allocator(), bridge, devicetype)) |user| {
            // The username is a bridge credential: it goes on the build command line only,
            // and not on the screen.
            std.log.info("paired. Rebuild with: zig build -Doptimize=ReleaseSmall -Dhue_user={s}", .{user});
            status(.ok, "PAIRED\nSEE THE LOG");
            return;
        }
        rtos.sleep(.from_ms(2000));
    }
    std.log.err("link button not pressed in time; restart to try again", .{});
    status(.failed, "NO LINK BUTTON\nRESTART TO RETRY");
}

// ---- control: touch screen + web remote + periodic refresh, in one loop ----
//
// The web remote acts on `catalog.selected()`: the light or room open on the screen, or
// -Dhue_light without one. With nothing selected (the screen's list page before any tap),
// it does nothing.

const http_port = 80;

fn control(ctx: catalog.Context) !void {
    const server = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse
        return error.OutOfMemory;
    try lwip.c_err(lwip.c.netconn_bind(server, null, http_port));
    try lwip.c_err(lwip.c.netconn_listen(server));
    // With LWIP_SO_RCVTIMEO, accept gives up after this long: it doubles as the loop tick,
    // so the screen, the web server and the refresh share one task and need no locking.
    server[0].recv_timeout = poll_ms;
    std.log.info("web remote: http://{f}:{}/", .{ net.ip(), http_port });

    var last_refresh = now_ms();
    var mirrored: ?hue.LightState = null;

    while (true) {
        var client: ?*lwip.c.netconn = null;
        if (lwip.c_err(lwip.c.netconn_accept(server, &client))) {
            serve(ctx, client.?) catch |err| std.log.warn("request failed: {t}", .{err});
            _ = lwip.c.netconn_close(client);
            _ = lwip.c.netconn_delete(client);
        } else |err| switch (err) {
            error.Timeout => {},
            else => {
                std.log.err("accept failed: {t}", .{err});
                rtos.sleep(.from_ms(poll_ms));
            },
        }

        const t = now_ms();
        if (config.screen) screen.tick(ctx, t);

        // Pick up changes made from the Hue app or a wall switch, and refresh whatever
        // the screen just navigated to.
        // Check `busy` first: navigation happens with the finger still down, and taking
        // the request then would drop it.
        const idle = !(config.screen and screen.busy());
        if (idle and (t - last_refresh >= refresh_ms or (config.screen and screen.take_refresh_request()))) {
            last_refresh = t;
            const result = if (config.screen)
                screen.refresh(ctx)
            else if (catalog.selected()) |e| catalog.refresh_entry(ctx, e);
            result catch |err| std.log.warn("refresh failed: {t}", .{err});
        }

        if (!config.screen) if (catalog.selected()) |e| {
            if (mirrored == null or !std.meta.eql(mirrored.?, e.state)) mirror(e.state);
            mirrored = e.state;
        };
    }
}

// ---- web remote ----

const page = @embedFile("page.html");

fn serve(ctx: catalog.Context, conn: *lwip.c.netconn) !void {
    conn.recv_timeout = 3000;
    var buf: [1024]u8 = undefined;
    const req = web.read_request(conn, &buf) catch |err| switch (err) {
        error.BadRequest => return web.respond(conn, "400 Bad Request", "text/plain", "bad request\n"),
        else => return err,
    };
    std.log.info("{s} {s}{s}{s}", .{ req.method, req.path, if (req.query.len > 0) "?" else "", req.query });

    if (req.is("GET", "/")) return web.respond(conn, "200 OK", "text/html; charset=utf-8", page);
    if (req.is("GET", "/state")) return respond_state(conn);
    if (req.is("POST", "/set")) {
        const change = parse_change(req.query) catch
            return web.respond(conn, "400 Bad Request", "text/plain", "bad parameter\n");
        const e = catalog.selected() orelse return no_selection(conn);
        catalog.apply(ctx, e, change);
        return respond_state(conn);
    }
    return web.respond(conn, "404 Not Found", "text/plain", "not found\n");
}

fn parse_change(query: []const u8) !hue.Change {
    var change: hue.Change = .{};
    var it = web.params(query);
    while (it.next()) |kv| {
        const key, const value = web.split_param(kv) orelse return error.BadParameter;
        if (std.mem.eql(u8, key, "on")) {
            change.on = (try std.fmt.parseInt(u1, value, 10)) == 1;
        } else if (std.mem.eql(u8, key, "bri")) {
            change.bri = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "hue")) {
            change.hue = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "sat")) {
            change.sat = try std.fmt.parseInt(u8, value, 10);
        } else return error.BadParameter;
    }
    return change;
}

fn no_selection(conn: *lwip.c.netconn) !void {
    return web.respond(conn, "409 Conflict", "text/plain", "pick a light or room on the screen first\n");
}

fn respond_state(conn: *lwip.c.netconn) !void {
    const e = catalog.selected() orelse return no_selection(conn);
    const light = e.state;
    var body: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&body, "{f}", .{std.json.fmt(.{
        .name = e.name(),
        .on = light.on,
        .reachable = light.reachable,
        .bri = light.bri,
        .hue = light.hue,
        .sat = light.sat,
    }, .{})});
    return web.respond(conn, "200 OK", "application/json", json);
}

// ---- status: on the screen, or on the on-board LED ----

const Status = enum { busy, waiting, ok, failed };

fn status(kind: Status, text: []const u8) void {
    if (config.screen) return ui.message(text, switch (kind) {
        .busy => ili9341.rgb(120, 170, 255),
        .waiting => ili9341.rgb(255, 180, 60),
        .ok => ili9341.rgb(110, 230, 120),
        .failed => ili9341.rgb(255, 90, 70),
    });
    show(switch (kind) {
        .busy => .{ .r = 0, .g = 0, .b = 8 },
        .waiting => .{ .r = 16, .g = 8, .b = 0 },
        .ok => .{ .r = 0, .g = 8, .b = 0 },
        .failed => .{ .r = 16, .g = 0, .b = 0 },
    });
}

/// Shows the light's colour on the LED, dimmed: a WS2812 at full power is blinding.
/// With the screen, the screen shows it instead, and SPI2 belongs to it.
fn mirror(light: hue.LightState) void {
    if (config.screen) return;
    if (!light.on) return show(.{ .r = 0, .g = 0, .b = 0 });
    const v: u32 = @max(@as(u32, light.bri orelse 254) * 40 / 254, 2);
    if (light.hue == null or light.sat == null) return show(scale(.{ .r = 255, .g = 160, .b = 60 }, v));
    const c = ui.hsv_to_rgb(light.hue.?, light.sat.?);
    return show(scale(.{ .r = c.r, .g = c.g, .b = c.b }, v));
}

fn scale(c: Color, v: u32) Color {
    return .{
        .r = @intCast(@as(u32, c.r) * v / 255),
        .g = @intCast(@as(u32, c.g) * v / 255),
        .b = @intCast(@as(u32, c.b) * v / 255),
    };
}

fn now_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}

fn init_led() void {
    const pin = gpio.num(8);
    const spi = hal.spi.instance.SPI2;
    pin.apply(.{ .output_enable = true });
    spi.connect_pins(.{ .data = .{ .single_one_wire = pin } });
    spi.apply(.{ .clock_config = hal.clock_config, .baud_rate = 3_000_000, .bit_order = .msb_first });
    led = .init(.init(spi, .single_one_wire, null), hal.drivers.clock_device());
}

fn show(color: Color) void {
    if (config.screen) return;
    led.write(&.{color}) catch {};
}
