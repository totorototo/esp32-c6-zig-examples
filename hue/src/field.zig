//! "Field" (`-Dui=field`): an experimental UI with no buttons and no lists. The screen *is*
//! the light: one room fills the whole display in its own colour, at its own brightness.
//!
//!   swipe left / right   next / previous room, with a colour wipe
//!   drag up / down       brightness; the screen dims with you
//!   tap                  on / off
//!   press and hold       the whole screen becomes a colour field (hue across, saturation
//!                        down); slide to a colour, let go to set it
//!
//! Same interface as screen.zig, so main.zig picks one at comptime. Lights are browsed only
//! when the bridge has no rooms.
const std = @import("std");
const config = @import("config");
const hue = @import("hue.zig");
const catalog = @import("catalog.zig");
const ui = @import("ui.zig");
const lcd = @import("ili9341.zig");
const ft6206 = @import("ft6206.zig");
const settings = @import("settings.zig");
const Point = ft6206.Point;

const log = std.log.scoped(.field);

pub var touch_ok = false;
var refresh_wanted = false;

const Mode = enum { room, colour };
var mode: Mode = .room;

// ---- what is browsed ----

fn entries() []catalog.Entry {
    return if (catalog.groups.len > 0) catalog.groups.slice() else catalog.lights.slice();
}

fn index_of(e: *const catalog.Entry) ?usize {
    for (entries(), 0..) |*x, i| if (x == e) return i;
    return null;
}

/// The room on screen: the selection, or the first room.
fn current() ?*catalog.Entry {
    if (catalog.selected()) |e| return e;
    const l = entries();
    if (l.len == 0) return null;
    catalog.select(&l[0]);
    return catalog.selected();
}

pub fn open(e: *const catalog.Entry) void {
    catalog.select(e);
    refresh_wanted = true;
    var buf: [9]u8 = undefined;
    settings.set(.selected, std.fmt.bufPrint(&buf, "{c}{s}", .{ @as(u8, if (e.kind == .light) 'l' else 'g'), e.id() }) catch return);
}

fn step(forward: bool) void {
    const l = entries();
    if (l.len == 0) return;
    const at = if (current()) |e| index_of(e) orelse 0 else 0;
    const next = if (forward) (at + 1) % l.len else (at + l.len - 1) % l.len;
    wipe = if (forward) .from_right else .from_left;
    open(&l[next]);
}

pub fn busy() bool {
    return gesture.down;
}

pub fn take_refresh_request() bool {
    defer refresh_wanted = false;
    return refresh_wanted;
}

pub fn refresh(ctx: catalog.Context) !void {
    if (current()) |e| try catalog.refresh_entry(ctx, e);
}

pub fn tick(ctx: catalog.Context, t: u64) void {
    if (touch_ok or config.demo) poll(ctx, t);
    render();
}

// ---- gestures ----

const tap_ms = 400;
const hold_ms = 600;
const still_px = 12;
const swipe_px = 28;
const dim_px = 16;
/// A drag over this many pixels spans the whole brightness range.
const dim_span_px = 200;
const send_ms = 150;

const Gesture = struct {
    down: bool = false,
    kind: enum { undecided, swipe, dim, hold } = .undecided,
    start: Point = .{ .x = 0, .y = 0 },
    start_t: u64 = 0,
    last: Point = .{ .x = 0, .y = 0 },
    misses: u8 = 0,
    start_bri: i32 = 0,
};
var gesture: Gesture = .{};

/// The latest change not yet sent; also what the screen previews.
var pending: ?hue.Change = null;
var last_send: u64 = 0;

fn poll(ctx: catalog.Context, t: u64) void {
    const e = current() orelse return;
    const point = read_touch(t) catch return;

    if (point) |p| {
        gesture.misses = 0;
        if (!gesture.down) {
            gesture = .{ .down = true, .start = p, .start_t = t, .last = p };
            gesture.start_bri = if (e.state.on) e.state.bri orelse 254 else 0;
            return;
        }
        gesture.last = p;
        const dx = @as(i32, p.x) - gesture.start.x;
        const dy = @as(i32, p.y) - gesture.start.y;
        switch (gesture.kind) {
            .undecided => {
                if (@abs(dx) > swipe_px and @abs(dx) > 2 * @abs(dy)) {
                    gesture.kind = .swipe;
                } else if (@abs(dy) > dim_px and @abs(dy) >= @abs(dx) and e.state.bri != null) {
                    gesture.kind = .dim;
                } else if (t - gesture.start_t >= hold_ms and @abs(dx) < still_px and @abs(dy) < still_px and e.state.hue != null) {
                    gesture.kind = .hold;
                    mode = .colour;
                    pending = colour_at(p);
                }
            },
            .dim => {
                // Up is brighter. Dragging an off room up turns it on from the bottom.
                const bri = std.math.clamp(gesture.start_bri - @divTrunc(dy * 254, dim_span_px), 1, 254);
                pending = .{ .on = true, .bri = @intCast(bri) };
            },
            .hold => pending = colour_at(p),
            .swipe => {},
        }
    } else if (gesture.down) {
        gesture.misses += 1;
        if (gesture.misses >= 3) release(ctx, e, t);
    }

    // While dimming, the bridge follows at most every `send_ms`; colour is sent on release.
    if (gesture.kind == .dim) if (pending) |c| if (t - last_send >= send_ms) {
        catalog.apply(ctx, e, c);
        last_send = t;
    };
}

fn release(ctx: catalog.Context, e: *catalog.Entry, t: u64) void {
    const dx = @as(i32, gesture.last.x) - gesture.start.x;
    switch (gesture.kind) {
        .undecided => if (t - gesture.start_t < tap_ms + 3 * 20) {
            catalog.apply(ctx, e, .{ .on = !e.state.on });
        },
        .swipe => step(dx < 0),
        .dim, .hold => if (pending) |c| catalog.apply(ctx, e, c),
    }
    pending = null;
    mode = .room;
    gesture = .{};
}

// ---- drawing: the room ----

const Wipe = enum { none, from_left, from_right };
var wipe: Wipe = .none;

const RoomShown = struct {
    id_buf: [8]u8 = @splat(0),
    id_len: u8 = 0,
    bg: lcd.Color = 0,
    /// Brightness percent, or null when off.
    pct: ?u8 = null,
    index: usize = 0,
    count: usize = 0,
};
var shown: ?RoomShown = null;
/// Rows of the colour field drawn so far: it's drawn a slice per tick, so touch keeps
/// being read while it fills in.
var field_rows: u16 = 0;
const rows_per_tick = 30;

fn render() void {
    if (mode == .colour) return render_colour();
    field_rows = 0;
    const e = current() orelse return;
    const state = preview(e.state);

    var now: RoomShown = .{ .bg = ui.to565(bg_of(state)), .index = index_of(e) orelse 0, .count = entries().len };
    now.id_len = e.id_len;
    @memcpy(now.id_buf[0..e.id_len], e.id());
    now.pct = if (state.on) @intCast((@as(u32, state.bri orelse 254) * 100 + 127) / 254) else null;
    if (shown) |old| if (std.meta.eql(old, now)) return;

    const fg = ui.to565(fg_on(bg_of(state)));
    const same_room = if (shown) |old| std.mem.eql(u8, old.id_buf[0..old.id_len], now.id_buf[0..now.id_len]) else false;
    if (same_room and wipe == .none) {
        // Same room, new level: repaint everything (the background is the level).
        lcd.fill(0, 0, lcd.width, lcd.height, now.bg);
    } else wipe_to(now.bg);

    draw_name(e.name(), fg, now.bg);
    var buf: [8]u8 = undefined;
    const big = if (now.pct) |pct| std.fmt.bufPrint(&buf, "{}%", .{pct}) catch unreachable else "OFF";
    ui.text_centered(.{ .x = 0, .y = 120, .w = lcd.width, .h = 60 }, big, 7, fg, now.bg);
    draw_dots(now.index, now.count, fg, now.bg);
    ui.text_centered(.{ .x = 0, .y = 302, .w = lcd.width, .h = 10 }, "SWIPE  DRAG  TAP  HOLD", 1, fg, now.bg);
    shown = now;
}

/// A room change slides the new colour in, in bands, from the side the finger went.
fn wipe_to(bg: lcd.Color) void {
    defer wipe = .none;
    const bands = 8;
    const w = lcd.width / bands;
    for (0..bands) |i| {
        const b: u16 = @intCast(if (wipe == .from_left) i else bands - 1 - i);
        lcd.fill(b * w, 0, w, lcd.height, bg);
    }
}

fn draw_name(name: []const u8, fg: lcd.Color, bg: lcd.Color) void {
    const r: ui.Rect = .{ .x = 8, .y = 48, .w = lcd.width - 16, .h = 30 };
    const scale: u16 = for ([_]u16{ 3, 2, 1 }) |sc| {
        if (ui.text_width(name, sc) <= r.w) break sc;
    } else 1;
    ui.text_centered(r, name, scale, fg, bg);
}

fn draw_dots(index: usize, count: usize, fg: lcd.Color, bg: lcd.Color) void {
    const n: usize = @min(count, 16);
    if (n < 2) return;
    const gap = 14;
    const x0: u16 = @intCast((@as(usize, lcd.width) - (n - 1) * gap) / 2);
    for (0..n) |i| {
        const x: u16 = x0 + @as(u16, @intCast(i)) * gap;
        if (i == index) {
            lcd.fill(x - 4, 270, 9, 9, fg);
        } else {
            lcd.fill(x - 2, 272, 5, 5, fg);
            lcd.fill(x - 1, 273, 3, 3, bg);
        }
    }
}

fn preview(state: hue.LightState) hue.LightState {
    var v = state;
    const c = pending orelse return v;
    if (c.on) |x| v.on = x;
    if (c.bri) |x| v.bri = x;
    if (c.hue) |x| v.hue = x;
    if (c.sat) |x| v.sat = x;
    return v;
}

/// The room's colour at its brightness. Even at 1% it stays recognisably that colour: the
/// screen is a picture of the light, not a power meter.
fn bg_of(s: hue.LightState) ui.Rgb {
    if (!s.on) return .{ .r = 14, .g = 14, .b = 18 };
    const base: ui.Rgb = if (s.hue != null and s.sat != null) ui.hsv_to_rgb(s.hue.?, s.sat.?) else .{ .r = 255, .g = 190, .b = 110 };
    const level: u32 = 60 + @as(u32, s.bri orelse 254) * 195 / 254;
    return .{
        .r = @intCast(@as(u32, base.r) * level / 255),
        .g = @intCast(@as(u32, base.g) * level / 255),
        .b = @intCast(@as(u32, base.b) * level / 255),
    };
}

/// Black text on light colours, white on dark ones.
fn fg_on(bg: ui.Rgb) ui.Rgb {
    const luma = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
    return if (luma > 140) .{ .r = 16, .g = 16, .b = 16 } else .{ .r = 245, .g = 245, .b = 245 };
}

// ---- drawing: the colour field ----

const field_h = 300; // below it, a strip with the instruction
var hue_row: [lcd.width]ui.Rgb = undefined;
var cursor: ?Point = null;

fn colour_at(p: Point) hue.Change {
    const x = @min(p.x, lcd.width - 1);
    const y = @min(p.y, field_h - 1);
    return .{
        .on = true,
        .hue = @intCast(@as(u32, x) * 65535 / (lcd.width - 1)),
        .sat = @intCast(254 - @as(u32, y) * 254 / (field_h - 1)),
    };
}

/// Hue across, saturation down: vivid at the top, white at the bottom.
fn field_pixel(x: u16, y: u16) lcd.Color {
    return blend(hue_row[x], row_sat(y));
}

/// Saturation of row `y` as 0..256, for shifts instead of divisions.
fn row_sat(y: u16) u32 {
    return 256 - @as(u32, y) * 256 / (field_h - 1);
}

fn blend(c: ui.Rgb, s: u32) lcd.Color {
    return lcd.rgb(
        @intCast(255 - ((255 - @as(u32, c.r)) * s >> 8)),
        @intCast(255 - ((255 - @as(u32, c.g)) * s >> 8)),
        @intCast(255 - ((255 - @as(u32, c.b)) * s >> 8)),
    );
}

fn render_colour() void {
    if (field_rows < field_h) {
        if (field_rows == 0) {
            // The instruction first, so it shows the moment the hold registers.
            const black = lcd.rgb(0, 0, 0);
            lcd.fill(0, field_h, lcd.width, lcd.height - field_h, black);
            ui.text_centered(.{ .x = 0, .y = field_h, .w = lcd.width, .h = lcd.height - field_h }, "SLIDE, LET GO TO SET", 1, lcd.rgb(240, 240, 240), black);
            for (&hue_row, 0..) |*c, x| c.* = ui.hsv_to_rgb(@intCast(x * 65535 / (lcd.width - 1)), 254);
            shown = null; // the room view repaints in full afterwards
            cursor = null;
        }
        const n = @min(rows_per_tick, field_h - field_rows);
        var row: [lcd.width * 2]u8 = undefined;
        lcd.begin(0, field_rows, lcd.width, n);
        for (field_rows..field_rows + n) |y| {
            const sat = row_sat(@intCast(y));
            for (hue_row, 0..) |c, x| lcd.put(&row, x, blend(c, sat));
            lcd.pixels(&row);
        }
        lcd.end();
        field_rows += n;
        if (field_rows < field_h) return;
    }
    const p = gesture.last;
    const at: Point = .{ .x = @min(p.x, lcd.width - 1), .y = @min(p.y, field_h - 1) };
    if (cursor) |old| {
        if (old.x == at.x and old.y == at.y) return;
        draw_cursor(old, false);
    }
    draw_cursor(at, true);
    cursor = at;
}

const ring = 9; // radius of the cursor's outer edge

/// A white ring with a dark edge, or (`on` false) the field it covers, restored.
fn draw_cursor(c: Point, on: bool) void {
    const x0 = c.x -| ring;
    const y0 = c.y -| ring;
    const x1 = @min(c.x + ring + 1, lcd.width);
    const y1 = @min(c.y + ring + 1, field_h);
    var row: [(2 * ring + 1) * 2]u8 = undefined;
    lcd.begin(x0, y0, x1 - x0, y1 - y0);
    defer lcd.end();
    for (y0..y1) |y| {
        for (x0..x1, 0..) |x, i| {
            const dx = @as(i32, @intCast(x)) - c.x;
            const dy = @as(i32, @intCast(y)) - c.y;
            const d2 = dx * dx + dy * dy;
            const px = if (!on) field_pixel(@intCast(x), @intCast(y)) else if (d2 <= 3 * 3)
                field_pixel(@intCast(x), @intCast(y))
            else if (d2 <= 6 * 6)
                lcd.rgb(255, 255, 255)
            else if (d2 <= ring * ring)
                lcd.rgb(20, 20, 20)
            else
                field_pixel(@intCast(x), @intCast(y));
            lcd.put(&row, i, px);
        }
        lcd.pixels(row[0 .. 2 * (x1 - x0)]);
    }
}

// ---- touch input: the panel, or a scripted demo ----

fn read_touch(t: u64) !?Point {
    if (!config.demo) return ft6206.read();
    return demo_touch(t);
}

/// `-Ddemo=true`: a finger that plays every gesture once, so the UI can be watched (and
/// screenshotted) without a bridge or a hand. Times are from the first poll.
const Stroke = struct { from: u32, to: u32, a: Point, b: Point };
const demo_script = [_]Stroke{
    .{ .from = 2000, .to = 2250, .a = .{ .x = 200, .y = 160 }, .b = .{ .x = 40, .y = 160 } }, // swipe: next room
    .{ .from = 3500, .to = 3600, .a = .{ .x = 120, .y = 170 }, .b = .{ .x = 120, .y = 170 } }, // tap: off
    .{ .from = 5000, .to = 5100, .a = .{ .x = 120, .y = 170 }, .b = .{ .x = 120, .y = 170 } }, // tap: on
    .{ .from = 6000, .to = 6800, .a = .{ .x = 120, .y = 240 }, .b = .{ .x = 120, .y = 60 } }, // drag up: brighter
    .{ .from = 8500, .to = 9300, .a = .{ .x = 60, .y = 150 }, .b = .{ .x = 60, .y = 150 } }, // hold: colour field
    .{ .from = 9300, .to = 12300, .a = .{ .x = 60, .y = 150 }, .b = .{ .x = 190, .y = 70 } }, // slide, then let go
    .{ .from = 14000, .to = 14250, .a = .{ .x = 40, .y = 160 }, .b = .{ .x = 200, .y = 160 } }, // swipe back
};
var demo_t0: ?u64 = null;

fn demo_touch(t: u64) ?Point {
    const t0 = demo_t0 orelse blk: {
        demo_t0 = t;
        break :blk t;
    };
    const rel = t - t0;
    for (demo_script) |s| if (rel >= s.from and rel < s.to) {
        const f = @as(i64, @intCast(rel - s.from));
        const span = @as(i64, s.to - s.from);
        return .{
            .x = @intCast(s.a.x + @divTrunc((@as(i64, s.b.x) - s.a.x) * f, span)),
            .y = @intCast(s.a.y + @divTrunc((@as(i64, s.b.y) - s.a.y) * f, span)),
        };
    };
    return null;
}
