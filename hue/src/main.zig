//! hue: a Philips Hue remote on the ESP32-C6, through the bridge's local API.
//!
//!   1. Finds the bridge: `-Dhue_ip`, else the address saved in flash, else an mDNS search.
//!      Fetches `/api/config` and logs the bridge name (no pairing needed).
//!   2. Gets a username: `-Dhue_user`, else the one saved in flash, else pairing (press the
//!      bridge's link button). A paired username is saved, so pairing happens once.
//!   3. Logs the lights, rooms, zones and scenes, then controls them:
//!      - Touch screen (ILI9341 + FT6206, `-Dscreen=true`, the default): rooms first, each
//!        with its brightness, colour, scenes and lights (screen.zig), and every light. It
//!        reopens on the last one open (or `-Dhue_light`), and dims when left alone.
//!      - Web remote on port 80, on the selected entry: on/off, brightness, colour.
//!      - The on-board LED (RMT, GPIO8) shows the status, then mirrors the selected entry.
//!      What's on screen is refreshed every 5 s.
//!   The BOOT button: a short press turns every light off. Held 3 s, the screen asks
//!   whether to forget the bridge and the username (held 10 s, or `POST /forget`, it just
//!   does), then restarts.
//! Logs go to UART0 (115200 baud).
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");
const net = @import("net");
const hue = @import("hue.zig");
const web = net.web;
const ui = @import("ui.zig");
const catalog = @import("catalog.zig");
/// The touch UI: rooms and lights with a page each (`-Dui=list`), or the gesture-only experiment
/// (`-Dui=field`). Both have the same interface.
const screen = switch (config.ui) {
    .list => @import("screen.zig"),
    .field => @import("field.zig"),
};
const ili9341 = @import("screen").lcd;
const ft6206 = @import("screen").touch;
const settings = @import("settings.zig");
const backlight = @import("backlight.zig");
const lwip = net.lwip;

const hal = microzig.hal;
const gpio = hal.gpio;
const rtos = hal.rtos;
const radio = hal.radio;
const rmt = hal.rmt;
const WS2812 = hal.drivers.WS2812_RMT;
const Color = WS2812.Color;

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
// USB pins. MISO and the touch INT pin stay unconnected; the backlight (LED) is on GPIO3,
// dimmed by PWM (backlight.zig).
const screen_pins: ili9341.Pins = .{
    .sck = gpio.num(19),
    .mosi = gpio.num(18),
    .cs = gpio.num(20),
    .dc = gpio.num(21),
    .rst = gpio.num(2),
};
const touch_sda = gpio.num(22);
const touch_scl = gpio.num(23);

// The on-board WS2812 through RMT, so it works next to the screen (which takes SPI2).
const led_pin = gpio.num(8);
const led_channel = rmt.instance.TX0;
const rmt_config: rmt.Config = .{ .clock_config = hal.clock_config };
const led_channel_config: rmt.Tx.Config = .{};
var led: WS2812 = undefined;

/// The BOOT button: low while pressed (pulled up on the board). A short press turns all
/// lights off; held, it forgets the saved bridge and username.
const boot_button = gpio.num(9);
/// Released before this: all off.
const short_press_ms = 800;
/// Held this long: the screen asks (FORGET / CANCEL).
const ask_hold_ms = 3000;
/// Held this long: forgotten without asking (no screen, the field UI, or before the UI runs).
const forget_hold_ms = 10_000;

var heap: microzig.Allocator = undefined;

var user_buf: [64]u8 = undefined;

pub fn main() !void {
    std.log.info("hue on ESP32-C6", .{});
    init_led();
    if (config.screen) {
        backlight.init();
        ili9341.init(screen_pins);
        if (ft6206.init(touch_sda, touch_scl)) {
            screen.touch_ok = true;
        } else |err| std.log.warn("touch controller not found ({t}): screen is display-only", .{err});
    }
    boot_button.apply(.{ .input_enable = true, .pull = .up });
    settings.init();
    status(.busy, "CONNECTING");

    heap = try .init_with_heap(16384);
    // Decided at runtime on purpose: with a comptime `if`, the rest of main would be dead
    // code, and lwIP's allocator (set up through net.up) would be dropped at link time.
    var demo_mode = config.demo;
    _ = &demo_mode;
    if (demo_mode) demo();
    try net.up(heap.allocator());

    const bridge = try find_bridge();

    var from_flash = false;
    const user: []const u8 = if (config.hue_user.len > 0) config.hue_user else if (settings.get(.user, &user_buf)) |u| blk: {
        from_flash = true;
        break :blk u;
    } else try pair(bridge);

    const ctx: catalog.Context = .{ .bridge = bridge, .user = user, .allocator = heap.allocator() };
    while (true) {
        if (catalog.refresh(ctx, .light)) |_| break else |err| {
            // The common cause: a username from another bridge, or one deleted in the Hue app.
            if (err == error.BridgeError) {
                if (from_flash) {
                    std.log.err("the bridge rejected the saved username: forgetting it, pairing again", .{});
                    settings.erase(.user);
                    restart();
                }
                std.log.err("the bridge rejected -Dhue_user: rebuild without it to pair again", .{});
                halt(.failed, "BRIDGE REJECTED\nTHE USERNAME");
            }
            // Anything else (a timeout, a bridge busy rebooting) can pass: try again.
            std.log.warn("lights not read ({t}): retrying in {} s", .{ err, retry_ms / 1000 });
            status(.failed, "BRIDGE NOT\nRESPONDING");
            wait_or_forget(retry_ms);
        }
    }
    catalog.refresh(ctx, .group) catch |err| std.log.warn("rooms and zones not read: {t}", .{err});
    catalog.refresh_scenes(ctx) catch |err| std.log.warn("scenes not read: {t}", .{err});
    catalog.log_all();

    if (config.hue_light.len > 0) {
        if (!catalog.select_id(.light, config.hue_light)) {
            std.log.err("no light {s} on this bridge: rebuild with another -Dhue_light", .{config.hue_light});
            halt(.failed, "NO SUCH LIGHT\nSEE THE LOG");
        }
    } else {
        // The light or room last opened, if it still exists.
        var buf: [16]u8 = undefined;
        if (settings.get(.selected, &buf)) |sel| if (sel.len > 1) {
            const kind: hue.Kind = if (sel[0] == 'g') .group else .light;
            _ = catalog.select_id(kind, sel[1..]);
        };
    }
    if (catalog.selected()) |e| {
        if (config.screen) screen.open(e);
    } else if (!config.screen) {
        // Without the screen, nothing else can pick a light.
        std.log.info("rebuild with -Dhue_light=<id> to control one of these", .{});
        halt(.ok, "LIGHTS LISTED\nSEE THE LOG");
    }
    try control(ctx);
}

/// The bridge to talk to: `-Dhue_ip`, else the saved address if the bridge still answers
/// there, else the first one found by mDNS. The one that answers is saved.
///
/// Never gives up: after a power cut the board boots faster than the bridge, and a remote
/// that stopped at "no bridge" would stay dead until someone resets it. Holding BOOT while
/// it waits forgets the saved address.
fn find_bridge() !hue.Bridge {
    const fixed: ?hue.Bridge = if (config.hue_ip.len > 0) try hue.Bridge.init(config.hue_ip) else null;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        if (try_bridge(fixed)) |b| return b;
        if (attempt == 0) {
            if (fixed) |b| {
                std.log.err("no bridge answering at {s} (-Dhue_ip): retrying every {} s", .{ b.host(), retry_ms / 1000 });
            } else {
                std.log.err("no Hue bridge found on this network: retrying every {} s. " ++
                    "Where mDNS can't reach the LAN (Wokwi), rebuild with -Dhue_ip=<address>", .{retry_ms / 1000});
            }
        }
        status(.failed, if (fixed != null) "BRIDGE NOT\nREACHABLE" else "NO BRIDGE FOUND\nRETRYING");
        wait_or_forget(retry_ms);
    }
}

const retry_ms = 10_000;

fn try_bridge(fixed: ?hue.Bridge) ?hue.Bridge {
    if (fixed) |b| {
        if (!reach(b)) return null;
        settings.set(.bridge_ip, b.host());
        return b;
    }

    var buf: [16]u8 = undefined;
    if (settings.get(.bridge_ip, &buf)) |ip| {
        if (hue.Bridge.init(ip)) |b| {
            if (reach(b)) return b;
            std.log.warn("no bridge at the saved address {s}: searching", .{ip});
        } else |_| settings.erase(.bridge_ip);
    }

    status(.busy, "SEARCHING\nFOR THE BRIDGE");
    std.log.info("searching for a Hue bridge (mDNS _hue._tcp.local)", .{});
    const found = hue.discover(3) catch |err| {
        std.log.warn("mDNS search failed: {t}", .{err});
        return null;
    } orelse return null;
    std.log.info("found a bridge at {s}", .{found.host()});
    if (!reach(found)) return null;
    settings.set(.bridge_ip, found.host());
    return found;
}

/// Sleeps `ms`, restarting from scratch if BOOT is held for `forget_hold_ms` meanwhile.
fn wait_or_forget(ms: u32) void {
    const step = 100;
    var held: u32 = 0;
    for (0..ms / step) |_| {
        rtos.sleep(.from_ms(step));
        held = if (boot_button.read() == 0) held + step else 0;
        if (held >= forget_hold_ms) forget();
    }
}

/// Fetches `/api/config` (no username needed) and logs who answered.
fn reach(b: hue.Bridge) bool {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    const cfg = hue.get_config(arena.allocator(), b) catch |err| {
        std.log.warn("no bridge answering at {s}: {t}", .{ b.host(), err });
        return false;
    };
    std.log.info("bridge `{s}` at {s}, id {s}, API {s}", .{ cfg.name, b.host(), cfg.bridgeid, cfg.apiversion });
    return true;
}

/// Pairs with the bridge and saves the username. Waits for the link button as long as it
/// takes: someone setting the remote up may be anywhere in the house.
fn pair(bridge: hue.Bridge) ![]const u8 {
    std.log.info("pairing: press the round link button on the bridge", .{});
    status(.waiting, "PRESS THE LINK\nBUTTON ON BRIDGE");
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        if (try hue.create_user(arena.allocator(), bridge, devicetype)) |user| {
            if (user.len > user_buf.len) return error.BadResponse;
            @memcpy(user_buf[0..user.len], user);
            // A bridge credential: saved in flash and logged once, never shown on screen.
            // The log line is for Wokwi, whose flash starts blank on every run.
            settings.set(.user, user);
            std.log.info("paired, username saved. To skip pairing where flash isn't kept (Wokwi): -Dhue_user={s}", .{user});
            status(.ok, "PAIRED");
            return user_buf[0..user.len];
        }
        wait_or_forget(2000);
    }
}

/// For what the board can't fix by itself (a build option that doesn't match the bridge):
/// shows `text` and stays there. Holding BOOT still forgets the settings and restarts.
fn halt(kind: Status, text: []const u8) noreturn {
    status(kind, text);
    while (true) wait_or_forget(60_000);
}

/// Forgets what pairing and discovery saved, then restarts.
fn forget() noreturn {
    std.log.info("forgetting the bridge and the username", .{});
    settings.erase(.user);
    settings.erase(.bridge_ip);
    settings.erase(.selected);
    status(.waiting, "FORGOTTEN\nRESTARTING");
    restart();
}

fn restart() noreturn {
    rtos.sleep(.from_ms(500)); // let the log and the screen catch up
    // A CPU reset reboots through the ROM like a system reset, and also works in Wokwi.
    hal.rom.software_reset_cpu();
}

// ---- demo: no Wi-Fi, no bridge, made-up rooms (-Ddemo=true) ----

/// Runs the touch UI on made-up rooms, for looking at it in a simulator. The field UI also
/// plays its gestures by itself, so it can be watched without a hand.
fn demo() noreturn {
    std.log.info("demo: made-up rooms, no bridge", .{});
    catalog.offline = true;
    const rooms = [_]struct { []const u8, []const u8, hue.LightState }{
        .{ "1", "Salon", .{ .on = true, .bri = 200, .hue = 7000, .sat = 160 } },
        .{ "3", "Bureau", .{ .on = true, .bri = 110, .hue = 46000, .sat = 200 } },
        .{ "5", "Chambre Aloïse", .{ .on = false, .bri = 90, .hue = 56000, .sat = 230 } },
        .{ "2", "Salle à manger", .{ .on = true, .bri = 254 } },
        .{ "83", "Séjour", .{ .on = true, .bri = 40, .hue = 1000, .sat = 254 } },
    };
    for (rooms) |r| catalog.add(&catalog.groups, .group, r[0], r[1], r[2]);
    const lights = [_]struct { []const u8, []const u8, hue.LightState }{
        .{ "2", "Hue color spot 1", .{ .on = true, .bri = 200, .hue = 7000, .sat = 160 } },
        .{ "4", "Hue color spot 2", .{ .on = true, .bri = 200, .hue = 7000, .sat = 160 } },
        .{ "6", "Lampadaire", .{ .on = false, .bri = 120 } },
        .{ "3", "Étoile", .{ .on = false, .bri = 120 } },
        .{ "7", "Bureau", .{ .on = true, .bri = 110, .hue = 46000, .sat = 200 } },
        .{ "8", "Veilleuse", .{ .on = false, .bri = 90, .hue = 56000, .sat = 230 } },
        .{ "9", "Prise café", .{ .on = false, .reachable = false } },
    };
    for (lights) |l| catalog.add(&catalog.lights, .light, l[0], l[1], l[2]);
    catalog.groups.items[0].set_members(&.{ "2", "4", "6", "9" }); // Salon
    catalog.groups.items[1].set_members(&.{"7"}); // Bureau
    catalog.groups.items[2].set_members(&.{ "3", "8" }); // Chambre
    const scenes = [_]struct { []const u8, []const u8, []const u8, @import("screen").Rgb, u8 }{
        .{ "s1", "Détente", "1", .{ .r = 255, .g = 160, .b = 80 }, 150 },
        .{ "s2", "Lecture", "1", .{ .r = 255, .g = 225, .b = 180 }, 254 },
        .{ "s3", "Horizon", "1", .{ .r = 255, .g = 110, .b = 60 }, 190 },
        .{ "s4", "Explosion de couleurs", "1", .{ .r = 190, .g = 60, .b = 255 }, 220 },
        .{ "s5", "Vent de montagne", "1", .{ .r = 110, .g = 200, .b = 255 }, 200 },
        .{ "s6", "Nuit", "1", .{ .r = 70, .g = 40, .b = 160 }, 30 },
        .{ "s7", "Repos", "1", .{ .r = 255, .g = 140, .b = 60 }, 90 },
        .{ "s8", "Concentration", "3", .{ .r = 230, .g = 240, .b = 255 }, 254 },
    };
    for (scenes) |sc| {
        catalog.scenes.add(.{ .id = sc[0], .name = sc[1], .group = sc[2], .recycle = false });
        catalog.scenes.items[catalog.scenes.len - 1].look = .{ .lit = .{ .rgb = sc[3], .bri = sc[4] } };
    }
    catalog.select(&catalog.groups.items[0]);

    const ctx: catalog.Context = .{ .bridge = hue.Bridge.from_octets(.{ 0, 0, 0, 0 }), .user = "", .allocator = heap.allocator() };
    var mirrored: ?hue.LightState = null;
    while (true) {
        const t = now_ms();
        if (config.screen) {
            screen.tick(ctx, t);
            if (!config.demo or config.ui == .list) backlight.tick(t);
        }
        if (catalog.selected()) |e| {
            if (mirrored == null or !std.meta.eql(mirrored.?, e.state)) mirror(e.state);
            mirrored = e.state;
        }
        rtos.sleep(.from_ms(poll_ms));
    }
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
    var button_down_since: ?u64 = null;
    var asked = false;

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
        if (config.screen) {
            screen.tick(ctx, t);
            backlight.tick(t);
        }

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
            if (result) |_| {
                if (config.screen) screen.report_refresh(true);
            } else |err| {
                std.log.warn("refresh failed: {t}", .{err});
                if (config.screen) screen.report_refresh(false);
            }
        }

        if (catalog.selected()) |e| {
            if (mirrored == null or !std.meta.eql(mirrored.?, e.state)) mirror(e.state);
            mirrored = e.state;
        } else if (mirrored != null) {
            show(.{ .r = 0, .g = 0, .b = 0 });
            mirrored = null;
        }

        if (boot_button.read() == 0) {
            const since = button_down_since orelse t;
            button_down_since = since;
            if (config.screen) _ = backlight.wake(t);
            const held = t - since;
            if (held >= forget_hold_ms) forget();
            if (held >= ask_hold_ms and !asked and config.screen and screen.can_confirm and screen.touch_ok) {
                screen.ask_forget();
                asked = true;
            }
        } else if (button_down_since) |since| {
            if (t - since < short_press_ms) _ = catalog.all_off(ctx);
            button_down_since = null;
            asked = false;
        }
        if (config.screen and screen.take_forget()) forget();
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
    if (req.is("POST", "/forget")) {
        try web.respond(conn, "200 OK", "text/plain", "forgetting the bridge and the username, restarting\n");
        _ = lwip.c.netconn_close(conn);
        forget();
    }
    if (req.is("POST", "/set")) {
        const change = parse_change(req.query) catch
            return web.respond(conn, "400 Bad Request", "text/plain", "bad parameter\n");
        const e = catalog.selected() orelse return no_selection(conn);
        if (!catalog.apply(ctx, e, change))
            return web.respond(conn, "502 Bad Gateway", "text/plain", "the bridge didn't take it\n");
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

// ---- status: on the screen and the on-board LED ----

const Status = enum { busy, waiting, ok, failed };

fn status(kind: Status, text: []const u8) void {
    if (config.screen) ui.message(text, switch (kind) {
        .busy => ili9341.rgb(120, 170, 255),
        .waiting => ili9341.rgb(255, 180, 60),
        .ok => ili9341.rgb(110, 230, 120),
        .failed => ili9341.rgb(255, 90, 70),
    });
    // Blue = starting, orange = waiting for you, green = done, red = error.
    show(scale(switch (kind) {
        .busy => .{ .r = 0, .g = 0, .b = 255 },
        .waiting => .{ .r = 255, .g = 128, .b = 0 },
        .ok => .{ .r = 0, .g = 255, .b = 0 },
        .failed => .{ .r = 255, .g = 0, .b = 0 },
    }, config.led_level / 2 + 1));
}

/// Shows the light's colour on the LED, scaled by its brightness and `-Dled_level`.
fn mirror(light: hue.LightState) void {
    if (!light.on) return show(.{ .r = 0, .g = 0, .b = 0 });
    const v: u32 = @max(@as(u32, light.bri orelse 254) * config.led_level / 254, 2);
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
    rmt.apply(rmt_config);
    led_channel.apply(led_channel_config);
    led_channel.connect_pin(led_pin);
    led = .init(led_channel, comptime led_channel_config.tick_freq(rmt_config), .{});
}

fn show(color: Color) void {
    led.write(&.{color}) catch |err| std.log.warn("LED write failed: {t}", .{err});
}
