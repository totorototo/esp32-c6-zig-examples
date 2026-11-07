//! hue: toggle a Philips Hue light from the ESP32-C6 through the bridge's local API.
//!
//!   1. Fetches `/api/config` and logs the bridge name (no pairing needed).
//!   2. Without `-Dhue_user`: pairing mode. Press the bridge's link button; the board logs
//!      the username to rebuild with.
//!   3. With `-Dhue_user`: lists the lights.
//!   4. With `-Dhue_light` too, controls that light:
//!      - BOOT button (GPIO9): short press toggles, long press steps the brightness.
//!      - Web remote on port 80: on/off, brightness, colour.
//!      - The on-board LED mirrors the light's colour; state is refreshed every 5 s.
//! Logs go to UART0 (115200 baud).
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");
const net = @import("net.zig");
const hue = @import("hue.zig");
const web = @import("web.zig");
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
const button = gpio.num(9); // BOOT button on the DevKitC-1, active low
const poll_ms = 20;
const refresh_ms = 5000;

const Led = WS2812(.{ .max_led_count = 1, .DatagramDevice = hal.drivers.SPI_Device });
var led: Led = undefined;

var heap: microzig.Allocator = undefined;

pub fn main() !void {
    std.log.info("hue on ESP32-C6, bridge {s}", .{config.hue_ip});
    init_led();
    show(.{ .r = 0, .g = 0, .b = 8 }); // blue: starting up
    button.apply(.{ .input_enable = true, .pull = .up });

    heap = try .init_with_heap(16384);
    try net.up(heap.allocator());

    const bridge = try hue.Bridge.init(config.hue_ip);
    {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        const cfg = hue.get_config(arena.allocator(), bridge) catch |err| {
            std.log.err("bridge at {s} not reachable: {t}", .{ config.hue_ip, err });
            show(.{ .r = 16, .g = 0, .b = 0 });
            return err;
        };
        std.log.info("bridge `{s}` id {s}, API {s}", .{ cfg.name, cfg.bridgeid, cfg.apiversion });
    }

    if (config.hue_user.len == 0) return pair(bridge);

    try list_lights(bridge);
    if (config.hue_light.len == 0) {
        std.log.info("rebuild with -Dhue_light=<id> to control one of these", .{});
        show(.{ .r = 0, .g = 8, .b = 0 });
        return;
    }
    try control(bridge);
}

fn pair(bridge: hue.Bridge) !void {
    std.log.info("pairing: press the round link button on the bridge (trying for 60 s)", .{});
    show(.{ .r = 16, .g = 8, .b = 0 });
    for (0..30) |_| {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        if (try hue.create_user(arena.allocator(), bridge, devicetype)) |user| {
            // The username is a bridge credential: it goes on the build command line only.
            std.log.info("paired. Rebuild with: zig build -Doptimize=ReleaseSmall -Dhue_user={s}", .{user});
            show(.{ .r = 0, .g = 8, .b = 0 });
            return;
        }
        rtos.sleep(.from_ms(2000));
    }
    std.log.err("link button not pressed in time; restart to try again", .{});
    show(.{ .r = 16, .g = 0, .b = 0 });
}

fn list_lights(bridge: hue.Bridge) !void {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    const lights = try hue.get_lights(arena.allocator(), bridge, config.hue_user);
    std.log.info("{} lights:", .{lights.map.count()});
    var it = lights.map.iterator();
    while (it.next()) |e| {
        const s = e.value_ptr.state;
        std.log.info("  {s}: {s} ({s}{s})", .{ e.key_ptr.*, e.value_ptr.name, if (s.on) "on" else "off", if (s.reachable) "" else ", unreachable" });
    }
}

// ---- control: button + web remote + periodic refresh, in one loop ----

const long_press_ms = 600;
const http_port = 80;
const brightness_steps = [_]u8{ 64, 127, 191, 254 };

/// Last known state of the controlled light.
var light: hue.LightState = .{ .on = false };
var light_name_buf: [64]u8 = undefined;
var light_name: []const u8 = "";

fn control(bridge: hue.Bridge) !void {
    try refresh(bridge);
    std.log.info("light {s} `{s}`: {s}, bri {?}, {s}", .{
        config.hue_light, light_name,                                          if (light.on) "on" else "off",
        light.bri,        if (light.hue != null) "colour" else "white only",
    });

    const server = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse
        return error.OutOfMemory;
    try lwip.c_err(lwip.c.netconn_bind(server, null, http_port));
    try lwip.c_err(lwip.c.netconn_listen(server));
    // With LWIP_SO_RCVTIMEO, accept gives up after this long: it doubles as the loop tick,
    // so the button, the web server and the refresh share one task and need no locking.
    server[0].recv_timeout = poll_ms;
    std.log.info("BOOT: short press toggles, long press steps brightness. Web remote: http://{f}:{}/", .{ net.ip(), http_port });

    var raw_prev = false;
    var pressed = false; // debounced
    var press_start: u64 = 0;
    var next_step: u64 = 0; // long press: time of the next brightness step
    var stepped = false; // this press changed brightness, so its release doesn't toggle
    var last_refresh = now_ms();

    while (true) {
        var client: ?*lwip.c.netconn = null;
        if (lwip.c_err(lwip.c.netconn_accept(server, &client))) {
            serve(bridge, client.?) catch |err| std.log.warn("request failed: {t}", .{err});
            _ = lwip.c.netconn_close(client);
            _ = lwip.c.netconn_delete(client);
        } else |err| switch (err) {
            error.Timeout => {},
            else => {
                std.log.err("accept failed: {t}", .{err});
                rtos.sleep(.from_ms(poll_ms));
            },
        }

        // Debounce: the state changes only when two consecutive samples agree.
        const raw = button.read() == 0;
        defer raw_prev = raw;
        const t = now_ms();
        if (raw == raw_prev and raw != pressed) {
            pressed = raw;
            if (pressed) {
                press_start = t;
                next_step = t + long_press_ms;
                stepped = false;
            } else if (!stepped) {
                apply(bridge, .{ .on = !light.on });
            }
        }
        if (pressed and t >= next_step and light.bri != null) {
            next_step = t + long_press_ms;
            stepped = true;
            apply(bridge, .{ .on = true, .bri = next_brightness(if (light.on) light.bri.? else 0) });
        }

        // Pick up changes made from the Hue app or a wall switch.
        if (!pressed and t - last_refresh >= refresh_ms) {
            last_refresh = t;
            const before = light;
            refresh(bridge) catch |err| std.log.warn("refresh failed: {t}", .{err});
            if (before.on != light.on or !std.meta.eql(before.bri, light.bri))
                std.log.info("light changed elsewhere: {s}, bri {?}", .{ if (light.on) "on" else "off", light.bri });
        }
    }
}

fn next_brightness(current: u8) u8 {
    for (brightness_steps) |b| if (b > @as(u16, current) + 8) return b;
    return brightness_steps[0];
}

fn apply(bridge: hue.Bridge, change: hue.Change) void {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    hue.set_state(arena.allocator(), bridge, config.hue_user, config.hue_light, change) catch |err| {
        std.log.err("set state failed: {t}", .{err});
        return;
    };
    if (change.on) |v| light.on = v;
    if (change.bri) |v| light.bri = v;
    if (change.hue) |v| light.hue = v;
    if (change.sat) |v| light.sat = v;
    std.log.info("light {s} -> {s}, bri {?}, hue {?}, sat {?}", .{ config.hue_light, if (light.on) "on" else "off", light.bri, light.hue, light.sat });
    mirror();
}

fn refresh(bridge: hue.Bridge) !void {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    const l = try hue.get_light(arena.allocator(), bridge, config.hue_user, config.hue_light);
    light = l.state;
    const n = @min(l.name.len, light_name_buf.len);
    @memcpy(light_name_buf[0..n], l.name[0..n]);
    light_name = std.mem.trimEnd(u8, light_name_buf[0..n], " ");
    mirror();
}

// ---- web remote ----

const page = @embedFile("page.html");

fn serve(bridge: hue.Bridge, conn: *lwip.c.netconn) !void {
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
        apply(bridge, change);
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

fn respond_state(conn: *lwip.c.netconn) !void {
    var body: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&body, "{f}", .{std.json.fmt(.{
        .name = light_name,
        .on = light.on,
        .reachable = light.reachable,
        .bri = light.bri,
        .hue = light.hue,
        .sat = light.sat,
    }, .{})});
    return web.respond(conn, "200 OK", "application/json", json);
}

// ---- on-board LED: mirrors the light ----

/// Shows the light's colour, dimmed: a WS2812 at full power is blinding.
fn mirror() void {
    if (!light.on) return show(.{ .r = 0, .g = 0, .b = 0 });
    const v: u32 = @max(@as(u32, light.bri orelse 254) * 40 / 254, 2);
    if (light.hue == null or light.sat == null) return show(scale(.{ .r = 255, .g = 160, .b = 60 }, v));
    return show(scale(hsv_to_rgb(light.hue.?, light.sat.?), v));
}

fn scale(c: Color, v: u32) Color {
    return .{
        .r = @intCast(@as(u32, c.r) * v / 255),
        .g = @intCast(@as(u32, c.g) * v / 255),
        .b = @intCast(@as(u32, c.b) * v / 255),
    };
}

/// Hue 0..65535, saturation 0..254, full value.
fn hsv_to_rgb(h: u16, sat: u8) Color {
    const s: u32 = @as(u32, @min(sat, 254)) * 255 / 254;
    const h6: u32 = @as(u32, h) * 6; // 0 .. 6*65535
    const sector = h6 >> 16; // 0..5
    const f: u32 = (h6 & 0xffff) >> 8; // 0..255 within the sector
    const p: u8 = @intCast(255 - s);
    const q: u8 = @intCast(255 - s * f / 255);
    const t: u8 = @intCast(255 - s * (255 - f) / 255);
    return switch (sector) {
        0 => .{ .r = 255, .g = t, .b = p },
        1 => .{ .r = q, .g = 255, .b = p },
        2 => .{ .r = p, .g = 255, .b = t },
        3 => .{ .r = p, .g = q, .b = 255 },
        4 => .{ .r = t, .g = p, .b = 255 },
        else => .{ .r = 255, .g = p, .b = q },
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
    led.write(&.{color}) catch {};
}
