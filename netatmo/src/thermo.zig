//! The thermostat screen: one room at a time, the whole display painted by its temperature
//! (blue when cold, through teal and amber, to red), its name, the measured temperature in
//! large type, then the setpoint, the mode and whether it is heating. No buttons:
//!
//!   swipe left / right   next / previous room
//!   drag up / down       setpoint in 0.5 °C steps; let go to send it (manual, for the
//!                        home's default duration)
//!   tap                  a room in manual mode goes back to its schedule
//!
//! Every action is an HTTPS request (about a second on the chip, ~9 s in Wokwi): the setpoint
//! line shows SENDING meanwhile. Actions and refreshes go through the root module
//! (`app.refresh_status`, `app.set_room`), so a demo build can swap in offline ones.
const std = @import("std");
const config = @import("config");
const screen = @import("screen");
const energy = @import("energy.zig");
const app = @import("root");

const lcd = screen.lcd;
const Point = screen.Point;
const Rgb = screen.Rgb;

const log = std.log.scoped(.thermo);

pub var touch_ok = false;

// ---- the rooms on screen: those with a thermostat or a valve ----

var index: usize = 0;

fn rooms() []energy.Room {
    return app.current_home().rooms[0..app.current_home().n_rooms];
}

fn count() usize {
    var n: usize = 0;
    for (rooms()) |*r| {
        if (r.in_status) n += 1;
    }
    return n;
}

/// The `i`-th room with a device.
fn nth(i: usize) ?*energy.Room {
    var n: usize = 0;
    for (rooms()) |*r| if (r.in_status) {
        if (n == i) return r;
        n += 1;
    };
    return null;
}

fn current() ?*energy.Room {
    if (count() == 0) return null;
    index = @min(index, count() - 1);
    return nth(index);
}

// ---- gestures ----

const tap_ms = 400;
const swipe_px = 28;
const drag_px = 12;
/// Finger travel per 0.5 °C step.
const step_px = 18;
const min_set = 7.0;
const max_set = 30.0;

const Gesture = struct {
    down: bool = false,
    kind: enum { undecided, swipe, drag } = .undecided,
    start: Point = .{ .x = 0, .y = 0 },
    last: Point = .{ .x = 0, .y = 0 },
    start_t: u64 = 0,
    misses: u8 = 0,
    start_set: f32 = 19,
};
var g: Gesture = .{};
/// The setpoint being dragged to, shown instead of the room's.
var preview: ?f32 = null;
var sending = false;

pub fn tick(t: u64) void {
    if (touch_ok or config.demo) poll(t);
    render();
}

fn poll(t: u64) void {
    const point = read_touch(t) catch return;
    const r = current() orelse return;
    if (point) |p| {
        g.misses = 0;
        if (!g.down) {
            g = .{ .down = true, .start = p, .last = p, .start_t = t, .start_set = r.setpoint orelse 19 };
            return;
        }
        g.last = p;
        const dx = @as(i32, p.x) - g.start.x;
        const dy = @as(i32, p.y) - g.start.y;
        switch (g.kind) {
            .undecided => if (@abs(dx) > swipe_px and @abs(dx) > 2 * @abs(dy)) {
                g.kind = .swipe;
            } else if (@abs(dy) > drag_px and @abs(dy) >= @abs(dx)) {
                g.kind = .drag;
            },
            .drag => {
                // Up is warmer, in 0.5 °C steps.
                const steps: f32 = @floatFromInt(@divTrunc(-dy, step_px));
                preview = std.math.clamp(g.start_set + steps * 0.5, min_set, max_set);
            },
            .swipe => {},
        }
    } else if (g.down) {
        g.misses += 1;
        if (g.misses >= 3) release(r, t);
    }
}

fn release(r: *energy.Room, t: u64) void {
    defer g = .{};
    switch (g.kind) {
        .undecided => if (t - g.start_t < tap_ms + 60 and r.mode.eql("manual")) {
            send(r, null);
        },
        .swipe => {
            const n = count();
            if (n > 1) {
                const dx = @as(i32, g.last.x) - g.start.x;
                index = if (dx < 0) (index + 1) % n else (index + n - 1) % n;
                wipe = if (dx < 0) .from_right else .from_left;
            }
        },
        .drag => if (preview) |p| {
            if (r.setpoint == null or @abs(p - r.setpoint.?) >= 0.25) send(r, p);
            preview = null;
        },
    }
}

/// `temp` null: back to the schedule.
fn send(r: *energy.Room, temp: ?f32) void {
    sending = true;
    render();
    defer sending = false;
    app.set_room(r, temp) catch |err| log.err("sending to `{s}` failed: {t}", .{ r.name.slice(), err });
}

// ---- drawing ----

const Wipe = enum { none, from_left, from_right };
var wipe: Wipe = .none;

const Shown = struct {
    room_id: [16]u8 = @splat(0),
    bg: lcd.Color = 0,
    measured: ?f32 = null,
    setpoint: ?f32 = null,
    mode: [12]u8 = @splat(0),
    heating: bool = false,
    reachable: bool = false,
    previewing: bool = false,
    sending: bool = false,
    index: usize = 0,
    count: usize = 0,
};
var shown: ?Shown = null;

pub fn message(text: []const u8, colour: Rgb) void {
    shown = null;
    const bg = lcd.rgb(16, 16, 20);
    lcd.fill(0, 0, lcd.width, lcd.height, bg);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var y: u16 = 130;
    while (lines.next()) |line| : (y += 30) {
        screen.text_centered(.{ .x = 0, .y = y, .w = lcd.width, .h = 16 }, line, 2, screen.to565(colour), bg);
    }
}

fn render() void {
    const r = current() orelse {
        if (shown == null) return;
        return message("NO THERMOSTAT\nOR VALVE", .{ .r = 255, .g = 180, .b = 60 });
    };
    const setpoint = preview orelse r.setpoint;
    const base = if (r.reachable) temp_colour(r.measured orelse 19) else Rgb{ .r = 70, .g = 70, .b = 78 };
    var now: Shown = .{
        .bg = screen.to565(base),
        .measured = r.measured,
        .setpoint = setpoint,
        .heating = (r.heating orelse 0) > 0,
        .reachable = r.reachable,
        .previewing = preview != null,
        .sending = sending,
        .index = index,
        .count = count(),
    };
    @memcpy(now.room_id[0..r.id.len], r.id.slice());
    @memcpy(now.mode[0..r.mode.len], r.mode.slice());
    if (shown) |old| if (std.meta.eql(old, now)) return;

    const fg = screen.to565(text_on(base));
    const bg = now.bg;
    const same_room = if (shown) |old| std.mem.eql(u8, &old.room_id, &now.room_id) and old.bg == now.bg else false;
    if (!same_room) {
        if (wipe != .none) wipe_to(bg) else lcd.fill(0, 0, lcd.width, lcd.height, bg);
    }

    // Name.
    const name_rect: screen.Rect = .{ .x = 8, .y = 36, .w = lcd.width - 16, .h = 30 };
    if (!same_room) {
        const scale: u16 = for ([_]u16{ 3, 2, 1 }) |sc| {
            if (screen.text_width(r.name.slice(), sc) <= name_rect.w) break sc;
        } else 1;
        screen.text_centered(name_rect, r.name.slice(), scale, fg, bg);
    }

    // Measured temperature, large.
    var buf: [16]u8 = undefined;
    const big: screen.Rect = .{ .x = 0, .y = 86, .w = lcd.width, .h = 64 };
    if (!same_room or !std.meta.eql(shown.?.measured, now.measured)) {
        lcd.fill(big.x, big.y, big.w, big.h, bg);
        const t = if (r.measured) |m| std.fmt.bufPrint(&buf, "{d:.1}°", .{m}) catch "?" else "--";
        screen.text_centered(big, t, 7, fg, bg);
    }

    // Setpoint line: inverted while dragging, SENDING while a request runs.
    const set_rect: screen.Rect = .{ .x = 20, .y = 176, .w = lcd.width - 40, .h = 34 };
    {
        const inv = now.previewing or now.sending;
        const back = if (inv) fg else bg;
        const front = if (inv) bg else fg;
        lcd.fill(set_rect.x, set_rect.y, set_rect.w, set_rect.h, back);
        const s = if (now.sending)
            "SENDING"
        else if (setpoint) |v|
            std.fmt.bufPrint(&buf, "SET {d:.1}°", .{v}) catch "?"
        else
            "SET --";
        screen.text_centered(set_rect, s, 3, front, back);
    }

    // Mode and heating.
    const mode_rect: screen.Rect = .{ .x = 0, .y = 222, .w = lcd.width, .h = 16 };
    lcd.fill(mode_rect.x, mode_rect.y, mode_rect.w, mode_rect.h, bg);
    var mbuf: [32]u8 = undefined;
    const mode_text = std.fmt.bufPrint(&mbuf, "{s}{s}", .{
        if (!r.reachable) "UNREACHABLE" else mode_label(r.mode.slice()),
        if (now.heating) "  HEATING" else "",
    }) catch "";
    screen.text_centered(mode_rect, mode_text, 2, fg, bg);

    // Position dots and the hint.
    if (!same_room or shown.?.count != now.count) {
        draw_dots(now.index, now.count, fg, bg);
        const hint = if (r.mode.eql("manual")) "DRAG: SETPOINT   TAP: SCHEDULE" else "DRAG: SETPOINT   SWIPE: ROOMS";
        screen.text_centered(.{ .x = 0, .y = 300, .w = lcd.width, .h = 10 }, hint, 1, fg, bg);
    }
    shown = now;
}

fn mode_label(mode: []const u8) []const u8 {
    const labels = .{
        .{ "schedule", "SCHEDULE" }, .{ "manual", "MANUAL" }, .{ "home", "SCHEDULE" },
        .{ "away", "AWAY" },         .{ "hg", "FROST GUARD" }, .{ "off", "OFF" },
        .{ "max", "MAX" },
    };
    inline for (labels) |l| if (std.mem.eql(u8, mode, l[0])) return l[1];
    return mode;
}

fn wipe_to(bg: lcd.Color) void {
    defer wipe = .none;
    const bands = 8;
    const w = lcd.width / bands;
    for (0..bands) |i| {
        const b: u16 = @intCast(if (wipe == .from_left) i else bands - 1 - i);
        lcd.fill(b * w, 0, w, lcd.height, bg);
    }
}

fn draw_dots(at: usize, n_total: usize, fg: lcd.Color, bg: lcd.Color) void {
    lcd.fill(0, 264, lcd.width, 16, bg);
    const n: usize = @min(n_total, 16);
    if (n < 2) return;
    const gap = 14;
    const x0: u16 = @intCast((@as(usize, lcd.width) - (n - 1) * gap) / 2);
    for (0..n) |i| {
        const x: u16 = x0 + @as(u16, @intCast(i)) * gap;
        if (i == at) {
            lcd.fill(x - 4, 268, 9, 9, fg);
        } else {
            lcd.fill(x - 2, 270, 5, 5, fg);
            lcd.fill(x - 1, 271, 3, 3, bg);
        }
    }
}

/// Cold to warm: blue at 15 °C and below, teal at 18, amber at 20.5, orange at 22, red at 24
/// and above. Muted a little, so text stays readable on every colour.
pub fn temp_colour(c: f32) Rgb {
    const stops = [_]struct { f32, Rgb }{
        .{ 15.0, .{ .r = 40, .g = 90, .b = 200 } },
        .{ 18.0, .{ .r = 30, .g = 150, .b = 160 } },
        .{ 20.5, .{ .r = 220, .g = 160, .b = 50 } },
        .{ 22.0, .{ .r = 225, .g = 110, .b = 40 } },
        .{ 24.0, .{ .r = 200, .g = 50, .b = 40 } },
    };
    if (c <= stops[0][0]) return stops[0][1];
    for (stops[0 .. stops.len - 1], stops[1..]) |a, b| if (c <= b[0]) {
        const f = (c - a[0]) / (b[0] - a[0]);
        return .{ .r = lerp(a[1].r, b[1].r, f), .g = lerp(a[1].g, b[1].g, f), .b = lerp(a[1].b, b[1].b, f) };
    };
    return stops[stops.len - 1][1];
}

fn lerp(a: u8, b: u8, f: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * f);
}

fn text_on(bg: Rgb) Rgb {
    const luma = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
    return if (luma > 140) .{ .r = 16, .g = 16, .b = 16 } else .{ .r = 245, .g = 245, .b = 245 };
}

// ---- touch: the panel, or a scripted finger for -Ddemo ----

fn read_touch(t: u64) !?Point {
    if (!config.demo) return screen.touch.read();
    return demo_touch(t);
}

const Stroke = struct { from: u32, to: u32, a: Point, b: Point };
const script = [_]Stroke{
    .{ .from = 3000, .to = 3250, .a = .{ .x = 200, .y = 160 }, .b = .{ .x = 40, .y = 160 } }, // next room
    .{ .from = 5000, .to = 6000, .a = .{ .x = 120, .y = 240 }, .b = .{ .x = 120, .y = 150 } }, // drag up: warmer
    .{ .from = 8500, .to = 8600, .a = .{ .x = 120, .y = 120 }, .b = .{ .x = 120, .y = 120 } }, // tap: back to schedule
    .{ .from = 10500, .to = 10750, .a = .{ .x = 200, .y = 160 }, .b = .{ .x = 40, .y = 160 } }, // next room
    .{ .from = 12500, .to = 12750, .a = .{ .x = 40, .y = 160 }, .b = .{ .x = 200, .y = 160 } }, // back
};
var demo_t0: ?u64 = null;

fn demo_touch(t: u64) ?Point {
    const t0 = demo_t0 orelse blk: {
        demo_t0 = t;
        break :blk t;
    };
    const rel = t - t0;
    for (script) |s| if (rel >= s.from and rel < s.to) {
        const f = @as(i64, @intCast(rel - s.from));
        const span = @as(i64, s.to - s.from);
        return .{
            .x = @intCast(s.a.x + @divTrunc((@as(i64, s.b.x) - s.a.x) * f, span)),
            .y = @intCast(s.a.y + @divTrunc((@as(i64, s.b.y) - s.a.y) * f, span)),
        };
    };
    return null;
}
