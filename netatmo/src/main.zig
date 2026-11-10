//! Netatmo thermostat and valves from the ESP32-C6: OAuth2 and the Energy API over HTTPS
//! (../common's `https` module), the second step towards a thermostat remote.
//!
//!   1. Joins Wi-Fi, gets the time (SNTP).
//!   2. Exchanges the refresh token (flash, or `-Dnetatmo_refresh_token` the first time) for
//!      an access token. Netatmo replaces the refresh token every time, so the new one is
//!      written to flash before anything else happens.
//!   3. `homesdata`: the home, its rooms and modules (streamed: the answer carries the heating
//!      schedules and runs to tens of KiB).
//!   4. `homestatus`: each room's temperature, setpoint and mode, each module's battery.
//!   5. With `-Dnetatmo_test_room=<id> -Dnetatmo_test_temp=<°C>`: sets that room manually for
//!      10 minutes, reads it back, then returns it to the schedule.
//!
//! Logs go to UART0 (115200 baud) and end with `netatmo test: PASS` or `netatmo test: FAIL`.
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");
const net = @import("net");
const https = @import("https");
const energy = @import("energy.zig");
const settings = @import("settings.zig");

const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;

comptime {
    _ = net.exports;
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;

pub const std_options: std.Options = with_page_size(microzig.std_options(.{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
    .logFn = uart_log,
}));

/// The TLS client's certificate-bundle lock wants an `std.Io`; `std.Io.failing` references
/// file memory maps, which need a page size. Freestanding has none. Never actually used.
fn with_page_size(o: std.Options) std.Options {
    var with = o;
    with.page_size_min = 4096;
    with.page_size_max = 4096;
    return with;
}

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
    // In a trap or a panic (interrupts off) the RTOS mutex can't be taken: write unlocked.
    const mstatus = asm volatile ("csrr %[r], mstatus"
        : [r] "=r" (-> u32),
    );
    const locked = mstatus & 0x8 != 0;
    if (locked) log_mutex.lock();
    defer if (locked) log_mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&log_buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

const api = "api.netatmo.com";

pub fn main() !void {
    std.log.info("netatmo on ESP32-C6", .{});
    // What the heap leaves for the main task's stack (not the heap's size): HTTPS needs
    // 160 KiB, see ../common/src/https.zig.
    var heap: microzig.Allocator = try .init_with_heap(160 * 1024);
    settings.init();
    try net.up(heap.allocator());

    run() catch |err| {
        std.log.err("netatmo test: FAIL ({t})", .{err});
        return;
    };
}

fn run() !void {
    try https.sync_time();

    // ---- OAuth: a fresh access token, and the next refresh token saved first ----
    var token_buf: [128]u8 = undefined;
    const access = try refresh_access_token(&token_buf);

    var auth_buf: [160]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{access});
    const headers = [_]https.Header{.{ .name = "Authorization", .value = auth }};

    // ---- homesdata ----
    const home = &home_state;
    home.* = .{};
    {
        var id_buf: [32]u8 = undefined;
        const want = settings.get(.home_id, &id_buf);
        var stream = try https.open(api, "GET", "/api/homesdata", &headers, "");
        defer stream.close();
        try expect_ok(&stream);
        var src = json_reader(stream.body);
        if (!try energy.read_homesdata(&src, scratch(), want, home)) {
            std.log.err("no home{s} on this account", .{if (want != null) " with the saved id" else ""});
            if (want != null) settings.erase(.home_id);
            return error.NoHome;
        }
    }
    _ = settings.set(.home_id, home.id.slice());
    std.log.info("home `{s}` ({s}): {} rooms, {} modules", .{ home.name.slice(), home.id.slice(), home.n_rooms, home.n_modules });

    // ---- homestatus ----
    try read_status(home, &headers);
    log_home(home);

    // ---- optional write test ----
    if (config.test_room.len > 0 and config.test_temp.len > 0) try setpoint_test(home, &headers);

    std.log.info("netatmo test: PASS", .{});
}

/// Exchanges the stored (or first) refresh token for an access token, written into `buf`.
fn refresh_access_token(buf: []u8) ![]const u8 {
    if (config.client_id.len == 0 or config.client_secret.len == 0) {
        std.log.err("no Netatmo app: rebuild with -Dnetatmo_client_id=... -Dnetatmo_client_secret=... (see README)", .{});
        return error.NoCredentials;
    }
    var stored_buf: [128]u8 = undefined;
    const refresh = settings.get(.refresh, &stored_buf) orelse if (config.refresh_token.len > 0) config.refresh_token else {
        std.log.err("no refresh token: rebuild with -Dnetatmo_refresh_token=... (see README)", .{});
        return error.NoCredentials;
    };

    var form_buf: [512]u8 = undefined;
    var form: std.Io.Writer = .fixed(&form_buf);
    try form.writeAll("grant_type=refresh_token&refresh_token=");
    try energy.percent_encode(&form, refresh);
    try form.writeAll("&client_id=");
    try energy.percent_encode(&form, config.client_id);
    try form.writeAll("&client_secret=");
    try energy.percent_encode(&form, config.client_secret);

    var resp_buf: [1024]u8 = undefined;
    const resp = try https.request(api, "POST", "/oauth2/token", &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded;charset=UTF-8" },
    }, form.buffered(), &resp_buf);

    var arena_mem: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_mem);
    if (resp.status != 200) {
        const why = energy.error_text(fba.allocator(), resp.body);
        std.log.err("token refresh refused (HTTP {}): {s}", .{ resp.status, why });
        if (std.mem.eql(u8, why, "invalid_grant")) {
            // The token is spent or revoked: keeping it would fail the same way every boot.
            settings.erase(.refresh);
            std.log.err("get a new refresh token (dev.netatmo.com token generator) and rebuild with -Dnetatmo_refresh_token=...", .{});
        }
        return error.TokenRefused;
    }
    const t = try energy.parse_token(fba.allocator(), resp.body);

    // The old refresh token is now dead: the new one goes to flash before anything else.
    if (!settings.set(.refresh, t.refresh_token)) {
        std.log.warn("new refresh token NOT saved: the next boot will need a new one", .{});
    }
    if (config.log_token) std.log.info("new refresh token (rebuild with it in Wokwi): -Dnetatmo_refresh_token={s}", .{t.refresh_token});
    std.log.info("access token valid for {} min", .{t.expires_in / 60});

    if (t.access_token.len > buf.len) return error.TokenTooLong;
    @memcpy(buf[0..t.access_token.len], t.access_token);
    return buf[0..t.access_token.len];
}

fn read_status(home: *energy.Home, headers: []const https.Header) !void {
    var target_buf: [96]u8 = undefined;
    var target: std.Io.Writer = .fixed(&target_buf);
    try target.writeAll("/api/homestatus?home_id=");
    try energy.percent_encode(&target, home.id.slice());
    var stream = try https.open(api, "GET", target.buffered(), headers, "");
    defer stream.close();
    try expect_ok(&stream);
    var src = json_reader(stream.body);
    try energy.read_homestatus(&src, scratch(), home);
}

fn setpoint_test(home: *energy.Home, headers: []const https.Header) !void {
    const room = home.room(config.test_room) orelse {
        std.log.err("no room {s} in `{s}` (see the room ids above)", .{ config.test_room, home.name.slice() });
        return error.NoSuchRoom;
    };
    const temp = std.fmt.parseFloat(f32, config.test_temp) catch return error.BadTestTemp;
    const end = (https.now() orelse return error.NoTime) + 10 * 60;

    std.log.info("setting `{s}` to {d:.1} °C for 10 min", .{ room.name.slice(), temp });
    try set_room(home, headers, config.test_room, "manual", config.test_temp, end);
    try read_status(home, headers);
    const now_set = home.room(config.test_room).?.setpoint orelse return error.NoSetpoint;
    std.log.info("`{s}` now: setpoint {d:.1} °C, mode {s}", .{ room.name.slice(), now_set, room.mode.slice() });
    const ok = @abs(now_set - temp) < 0.05 and room.mode.eql("manual");

    // Back to the schedule either way.
    try set_room(home, headers, config.test_room, "home", null, null);
    std.log.info("`{s}` back to its schedule", .{room.name.slice()});
    if (!ok) return error.SetpointNotApplied;
}

/// POST /api/setroomthermpoint: `mode` "manual" (with `temp` and `endtime`) or "home" (back to
/// the schedule).
fn set_room(home: *energy.Home, headers: []const https.Header, room_id: []const u8, mode: []const u8, temp: ?[]const u8, endtime: ?i64) !void {
    var form_buf: [192]u8 = undefined;
    var form: std.Io.Writer = .fixed(&form_buf);
    try form.writeAll("home_id=");
    try energy.percent_encode(&form, home.id.slice());
    try form.writeAll("&room_id=");
    try energy.percent_encode(&form, room_id);
    try form.print("&mode={s}", .{mode});
    if (temp) |t| try form.print("&temp={s}", .{t});
    if (endtime) |e| try form.print("&endtime={}", .{e});

    var all: [2]https.Header = .{ headers[0], .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded;charset=UTF-8" } };
    var resp_buf: [512]u8 = undefined;
    const resp = try https.request(api, "POST", "/api/setroomthermpoint", &all, form.buffered(), &resp_buf);
    if (resp.status != 200 or std.mem.indexOf(u8, resp.body, "\"ok\"") == null) {
        var arena_mem: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&arena_mem);
        std.log.err("setroomthermpoint refused (HTTP {}): {s}", .{ resp.status, energy.error_text(fba.allocator(), resp.body) });
        return error.SetpointRefused;
    }
}

fn log_home(home: *energy.Home) void {
    for (home.rooms[0..home.n_rooms]) |*r| {
        if (!r.in_status) {
            std.log.info("  room {s} `{s}`: no thermostat or valve", .{ r.id.slice(), r.name.slice() });
            continue;
        }
        var m: [8]u8 = undefined;
        var s: [8]u8 = undefined;
        std.log.info("  room {s} `{s}`: {s} °C, setpoint {s} °C ({s}){s}{s}", .{
            r.id.slice(),
            r.name.slice(),
            if (r.measured) |v| std.fmt.bufPrint(&m, "{d:.1}", .{v}) catch "?" else "-",
            if (r.setpoint) |v| std.fmt.bufPrint(&s, "{d:.1}", .{v}) catch "?" else "-",
            r.mode.slice(),
            if (r.heating != null and r.heating.? > 0) ", heating" else "",
            if (r.reachable) "" else ", unreachable",
        });
    }
    for (home.modules[0..home.n_modules]) |*mo| {
        std.log.info("  module {s} {s} `{s}`{s}{s}{s}", .{
            mo.id.slice(),
            mo.type.slice(),
            mo.name.slice(),
            if (mo.battery.len > 0) ", battery " else "",
            mo.battery.slice(),
            if (mo.reachable or mo.battery.len == 0) "" else ", unreachable",
        });
    }
}

/// A non-200 answer: log Netatmo's error message and fail.
fn expect_ok(stream: *https.Stream) !void {
    if (stream.status == 200) return;
    var buf: [512]u8 = undefined;
    const n = stream.body.readSliceShort(&buf) catch 0;
    var arena_mem: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_mem);
    std.log.err("HTTP {}: {s}", .{ stream.status, energy.error_text(fba.allocator(), buf[0..n]) });
    return error.ApiError;
}

/// A static, not a local: ~4 KiB, and the stack is busy enough with TLS.
var home_state: energy.Home = .{};

// The streaming JSON reader's nesting stack and any string split across TLS records.
var scratch_mem: [4096]u8 = undefined;
var scratch_fba: std.heap.FixedBufferAllocator = undefined;

fn scratch() std.mem.Allocator {
    return scratch_fba.allocator();
}

fn json_reader(body: *std.Io.Reader) std.json.Reader {
    scratch_fba = .init(&scratch_mem);
    return .init(scratch_fba.allocator(), body);
}
