//! The list UI's pages, drawn and hit-tested. Navigation and touch live in list.zig.
//!
//!   home                      room (or light)           a room's scenes or lights
//!   +----------------------+  +----------------------+  +----------------------+
//!   |  ROOMS   |  LIGHTS   |  | <  Salon             |  | <  Salon      SCENES |
//!   | [=o] Salon         > |  | +------------------+ |  | [#] Relax          * |
//!   | [o ] Bureau        > |  | |       75%        | |  | [#] Read             |
//!   |  :  5 rows a page    |  | | TAP ON/OFF  SLIDE| |  |  :                   |
//!   |                      |  | +------------------+ |  |                      |
//!   |                      |  | [#] COLOUR   ~~~~~ > |  |                      |
//!   |                      |  | SCENES           8 > |  |                      |
//!   |   <     1/2     >    |  | LIGHTS           3 > |  |   <     1/2     >    |
//!   +----------------------+  +----------------------+  +----------------------+
//!
//! A row's switch (left) toggles it; the rest of the row, marked with a chevron, opens it.
//! Each render compares with what is on the glass and redraws only what changed, so the
//! main loop calls it every tick.
const std = @import("std");
const screen = @import("screen");
const lcd = screen.lcd;
const hue = @import("hue.zig");
const Point = screen.Point;
const colour = screen.colour;

pub const Rect = screen.Rect;
pub const Rgb = colour.Rgb;
pub const hsv_to_rgb = colour.hsv_to_rgb;

pub const text_width = screen.text_width;
pub const text_centered = screen.text_centered;
pub const text = screen.text;
pub const to565 = screen.to565;

const bg = lcd.rgb(16, 16, 20);
const panel = lcd.rgb(48, 48, 54);
const pressed_bg = lcd.rgb(70, 70, 82);
const dim_text = lcd.rgb(150, 150, 160);
const faint = lcd.rgb(90, 90, 100);
const bright_text = lcd.rgb(240, 240, 240);
const warn_text = lcd.rgb(255, 90, 70);
pub const warm_white: Rgb = colour.warm_white;

// ---- geometry ----

pub const top_h = 44; // tabs, or the header with `<`
pub const rows_per_page = 5;
const row_h = 48; // about 8.5 mm on a 2.8" panel
const rows_y = 48;
const footer: Rect = .{ .x = 0, .y = rows_y + rows_per_page * row_h, .w = lcd.width, .h = lcd.height - (rows_y + rows_per_page * row_h) };
const prev_button: Rect = .{ .x = 0, .y = footer.y, .w = 80, .h = footer.h };
const next_button: Rect = .{ .x = lcd.width - 80, .y = footer.y, .w = 80, .h = footer.h };
const back_button: Rect = .{ .x = 0, .y = 0, .w = 60, .h = top_h };
/// Left of this, a row's touch toggles it.
const switch_hit_w = 64;
const name_x = 64;
const name_w = lcd.width - name_x - 28;

const tile: Rect = .{ .x = 12, .y = 52, .w = lcd.width - 24, .h = 128 };
const colour_button: Rect = .{ .x = 12, .y = 188, .w = lcd.width - 24, .h = 38 };
const scenes_row: Rect = .{ .x = 0, .y = 232, .w = lcd.width, .h = 44 };
const lights_row: Rect = .{ .x = 0, .y = 276, .w = lcd.width, .h = 44 };

const banner: Rect = .{ .x = 0, .y = lcd.height - 26, .w = lcd.width, .h = 26 };

fn row_rect(r: usize) Rect {
    return .{ .x = 0, .y = @intCast(rows_y + r * row_h), .w = lcd.width, .h = row_h };
}

pub const Tab = enum {
    rooms,
    lights,

    fn label(t: Tab) []const u8 {
        return switch (t) {
            .rooms => "ROOMS",
            .lights => "LIGHTS",
        };
    }

    fn rect(t: Tab) Rect {
        return .{ .x = @as(u16, @intFromEnum(t)) * (lcd.width / 2), .y = 0, .w = lcd.width / 2, .h = top_h };
    }
};

/// What a touch lands on. The same value marks what is drawn pressed.
pub const Hit = union(enum) {
    none,
    tab: Tab,
    back,
    prev,
    next,
    /// A row of the page on screen, 0..rows_per_page.
    row_switch: u8,
    row_open: u8,
    tile,
    colour,
    scenes,
    lights,
    confirm_yes,
    confirm_no,
};

pub fn page_count(entries: usize) u8 {
    return @intCast(@max(1, (entries + rows_per_page - 1) / rows_per_page));
}

// ---- what the glass shows ----

/// Fixed-size copies of strings, so frames compare with `std.meta.eql`.
const Str = struct {
    buf: [32]u8 = @splat(0),
    len: u8 = 0,

    fn of(s: []const u8) Str {
        var r: Str = .{};
        r.len = @intCast(@min(s.len, r.buf.len));
        @memcpy(r.buf[0..r.len], s[0..r.len]);
        return r;
    }

    fn get(s: *const Str) []const u8 {
        return s.buf[0..s.len];
    }
};

const Shown = union(enum) {
    nothing,
    list: ListShown,
    entry: EntryShown,
    confirm: Hit,
    /// The colour field (colourfield.zig) owns the glass.
    other,
};
var shown: Shown = .nothing;
var banner_shown: ?Str = null;
/// Set by any drawing, so the banner is put back on top.
var dirty = false;

/// Forces a full redraw on the next render (after the colour field, for one).
pub fn invalidate() void {
    shown = .other;
    banner_shown = null;
}

/// Full-screen message (boot, pairing, errors), up to two lines split at '\n'.
pub fn message(msg: []const u8, color: lcd.Color) void {
    invalidate();
    lcd.fill(0, 0, lcd.width, lcd.height, bg);
    var lines = std.mem.splitScalar(u8, msg, '\n');
    var y: u16 = 130;
    while (lines.next()) |line| : (y += 30) {
        text_centered(.{ .x = 0, .y = y, .w = lcd.width, .h = 16 }, line, 2, color, bg);
    }
}

/// A strip over the bottom of the page, for what the user should know but can't act on
/// (no bridge, a change that didn't go through). Null takes it away. Call after the page's
/// render, every tick.
pub fn render_banner(msg: ?[]const u8) void {
    if (msg) |m| {
        const now = Str.of(m);
        if (!dirty and banner_shown != null and std.meta.eql(banner_shown.?, now)) return;
        const back = lcd.rgb(150, 30, 20);
        lcd.fill(banner.x, banner.y, banner.w, banner.h, back);
        text_centered(banner, m, if (text_width(m, 2) <= banner.w - 8) 2 else 1, bright_text, back);
        banner_shown = now;
    } else if (banner_shown != null) {
        // What was under it comes back with a full redraw.
        invalidate();
    }
    dirty = false;
}

// ---- lists ----

pub const Header = union(enum) {
    tabs: Tab,
    /// `<`, a title, and a dim label on the right ("SCENES").
    title: struct { name: []const u8, label: []const u8 = "", warn: bool = false },
};

pub const Row = struct {
    name: []const u8,
    lead: Lead,
    trail: Trail = .chevron,

    pub const Lead = union(enum) {
        /// A light or room: a switch, filled with its colour when on.
        toggle: struct { on: bool, reachable: bool = true, rgb: Rgb = warm_white },
        /// A scene: a square of what it looks like.
        swatch: Rgb,
    };
    pub const Trail = enum { none, chevron, mark };
};

pub const ListView = struct {
    header: Header,
    page: u8,
    pages: u8,
    /// This page's rows.
    rows: []const Row,
    empty: []const u8 = "NOTHING HERE",
};

const HeaderShown = union(enum) {
    tabs: Tab,
    title: struct { name: Str, label: Str, warn: bool },

    fn of(h: Header) HeaderShown {
        return switch (h) {
            .tabs => |t| .{ .tabs = t },
            .title => |t| .{ .title = .{ .name = .of(t.name), .label = .of(t.label), .warn = t.warn } },
        };
    }
};

const RowShown = struct {
    present: bool = false,
    name: Str = .{},
    lead: Row.Lead = .{ .swatch = .{ .r = 0, .g = 0, .b = 0 } },
    trail: Row.Trail = .none,
    pressed: bool = false,
};

const ListShown = struct {
    header: HeaderShown,
    page: u8,
    pages: u8,
    rows: [rows_per_page]RowShown,
    /// Pressed in the header or the footer (rows keep theirs).
    pressed: Hit,
};

pub fn list_hit(p: Point, header: Header, page: u8, pages: u8, rows: usize) Hit {
    if (p.y < top_h) return switch (header) {
        .tabs => .{ .tab = if (p.x < lcd.width / 2) .rooms else .lights },
        .title => if (p.x < back_button.w) .back else .none,
    };
    if (pages > 1) {
        if (prev_button.contains(p, 0)) return if (page > 0) .prev else .none;
        if (next_button.contains(p, 0)) return if (page + 1 < pages) .next else .none;
    }
    if (p.y < rows_y) return .none;
    const r = (p.y - rows_y) / row_h;
    if (r >= rows) return .none;
    return if (p.x < switch_hit_w) .{ .row_switch = @intCast(r) } else .{ .row_open = @intCast(r) };
}

pub fn render_list(v: ListView, pressed: Hit) void {
    var now: ListShown = .{
        .header = .of(v.header),
        .page = v.page,
        .pages = v.pages,
        .rows = @splat(.{}),
        .pressed = switch (pressed) {
            .tab, .back, .prev, .next => pressed,
            else => .none,
        },
    };
    for (v.rows, 0..) |row, r| now.rows[r] = .{
        .present = true,
        .name = .of(row.name),
        .lead = row.lead,
        .trail = row.trail,
        .pressed = switch (pressed) {
            .row_switch, .row_open => |i| i == r,
            else => false,
        },
    };

    const old: ?ListShown = if (shown == .list) shown.list else null;
    const full = if (old) |o| !std.meta.eql(o.header, now.header) or o.page != now.page or o.pages != now.pages else true;
    if (full) {
        dirty = true;
        lcd.fill(0, 0, lcd.width, lcd.height, bg);
        if (v.rows.len == 0) text_centered(row_rect(1), v.empty, 2, dim_text, bg);
    }
    if (full or !std.meta.eql(old.?.pressed, now.pressed)) {
        dirty = true;
        draw_header(v.header, now.pressed);
        if (now.pages > 1) draw_footer(now.page, now.pages, now.pressed);
    }
    for (now.rows, 0..) |row, r| {
        if (!full and std.meta.eql(row, old.?.rows[r])) continue;
        if (!full or row.present) draw_row(row_rect(r), row);
    }
    shown = .{ .list = now };
}

fn draw_header(h: Header, pressed: Hit) void {
    switch (h) {
        .tabs => |active| for (std.enums.values(Tab)) |t| {
            const r = t.rect();
            const is_pressed = pressed == .tab and pressed.tab == t;
            const back = if (is_pressed) pressed_bg else if (t == active) panel else bg;
            lcd.fill(r.x, r.y, r.w, r.h, back);
            text_centered(r, t.label(), 2, if (t == active) bright_text else dim_text, back);
            if (t == active) lcd.fill(r.x, r.y + r.h - 3, r.w, 3, to565(warm_white));
        },
        .title => |t| {
            lcd.fill(0, 0, lcd.width, top_h, panel);
            const back = if (pressed == .back) pressed_bg else panel;
            lcd.fill(back_button.x, back_button.y, back_button.w, back_button.h, back);
            draw_chevron(18, top_h / 2, .left, bright_text);
            const label_w = if (t.label.len > 0) text_width(t.label, 1) + 8 else 0;
            const x = back_button.w - 8;
            const avail = lcd.width - x - 8 - label_w;
            const colour_ = if (t.warn) warn_text else bright_text;
            if (text_width(t.name, 2) <= avail)
                text(x, top_h / 2 - 7, t.name, 2, colour_, panel)
            else
                text(x, top_h / 2 - 3, t.name, 1, colour_, panel);
            if (label_w > 0) text(lcd.width - label_w, top_h / 2 - 3, t.label, 1, dim_text, panel);
        },
    }
}

fn draw_footer(page: u8, pages: u8, pressed: Hit) void {
    lcd.fill(footer.x, footer.y, footer.w, footer.h, bg);
    var buf: [8]u8 = undefined;
    text_centered(footer, std.fmt.bufPrint(&buf, "{}/{}", .{ page + 1, pages }) catch unreachable, 2, dim_text, bg);
    for ([_]struct { Rect, Hit, bool, Direction }{
        .{ prev_button, .prev, page > 0, .left },
        .{ next_button, .next, page + 1 < pages, .right },
    }) |b| {
        const back = if (std.meta.eql(pressed, b[1])) pressed_bg else bg;
        lcd.fill(b[0].x, b[0].y, b[0].w, b[0].h, back);
        draw_chevron(b[0].x + b[0].w / 2 - 3, b[0].y + b[0].h / 2, b[3], if (b[2]) bright_text else panel);
    }
}

fn draw_row(rect: Rect, row: RowShown) void {
    const back = if (row.pressed) pressed_bg else bg;
    lcd.fill(rect.x, rect.y, rect.w, rect.h - 1, back);
    lcd.fill(rect.x + 16, rect.y + rect.h - 1, rect.w - 32, 1, panel); // separator
    if (!row.present) return;

    const cy = rect.y + rect.h / 2;
    var name_colour = bright_text;
    switch (row.lead) {
        .toggle => |s| {
            if (!s.reachable) name_colour = warn_text;
            draw_switch(12, cy - 12, s.on, if (!s.reachable) warn_text else to565(s.rgb), back);
        },
        .swatch => |c| rounded(14, cy - 14, 28, 28, to565(c)),
    }
    draw_name(name_x, rect.y, rect.h, name_w, row.name.get(), name_colour, back);
    switch (row.trail) {
        .none => {},
        .chevron => draw_chevron(lcd.width - 18, cy, .right, faint),
        .mark => rounded(lcd.width - 24, cy - 5, 10, 10, to565(warm_white)),
    }
}

/// A 40x24 switch: on, filled with the light's colour and the knob right; off, an outline
/// with the knob left.
fn draw_switch(x: u16, y: u16, on: bool, c: lcd.Color, back: lcd.Color) void {
    const w = 40;
    const h = 24;
    if (on) {
        rounded(x, y, w, h, c);
        rounded(x + w - 20, y + 2, 18, h - 4, bright_text);
    } else {
        rounded(x, y, w, h, faint);
        rounded(x + 2, y + 2, w - 4, h - 4, back);
        rounded(x + 3, y + 3, 16, h - 6, faint);
    }
}

/// A rectangle with its corners cut by two pixels: soft enough at this size.
fn rounded(x: u16, y: u16, w: u16, h: u16, c: lcd.Color) void {
    lcd.fill(x + 2, y, w - 4, h, c);
    lcd.fill(x, y + 2, w, h - 4, c);
    lcd.fill(x + 1, y + 1, w - 2, h - 2, c);
}

const Direction = enum { left, right };

/// A 7x13 chevron centred vertically on `cy`, its point at the `dir` side.
fn draw_chevron(x: u16, cy: u16, dir: Direction, c: lcd.Color) void {
    for (0..7) |i| {
        const d: u16 = @intCast(i);
        const col = if (dir == .right) x + d else x + 6 - d;
        lcd.fill(col, cy - 6 + d, 2, 2, c);
        lcd.fill(col, cy + 6 - d - 1, 2, 2, c);
    }
}

/// A name in the large font, on two lines if it has to (split at a space), else in the
/// small one. "Hue color spot 1" ends in what tells it apart, so nothing is cut short
/// when it can be avoided.
fn draw_name(x: u16, y: u16, h: u16, w: u16, name: []const u8, c: lcd.Color, back: lcd.Color) void {
    if (text_width(name, 2) <= w) return text(x, y + h / 2 - 7, name, 2, c, back);
    var split: ?usize = null;
    for (name, 0..) |ch, i| {
        if (ch != ' ') continue;
        if (text_width(name[0..i], 2) > w) break;
        if (text_width(name[i + 1 ..], 2) <= w) split = i;
    }
    if (split) |i| {
        text(x, y + h / 2 - 16, name[0..i], 2, c, back);
        text(x, y + h / 2 + 2, name[i + 1 ..], 2, c, back);
    } else text(x, y + h / 2 - 3, name, 1, c, back);
}

// ---- a light or room ----

pub const EntryView = struct {
    name: []const u8,
    state: hue.LightState,
    /// A room's scenes and lights; null for a light.
    room: ?struct { scenes: usize, lights: usize } = null,
};

const EntryShown = struct {
    name: Str,
    reachable: bool,
    on: bool,
    bri: ?u8,
    /// The colour the tile is painted in (565), and the button's swatch.
    tint: lcd.Color,
    has_colour: bool,
    room: ?[2]usize,
    pressed: Hit,
};

pub fn entry_hit(p: Point, v: EntryView) Hit {
    if (p.y < top_h) return if (p.x < back_button.w) .back else .none;
    if (tile.contains(p, 4)) return .tile;
    if (v.state.hue != null and colour_button.contains(p, 3)) return .colour;
    if (v.room) |r| {
        if (r.scenes > 0 and scenes_row.contains(p, 0)) return .scenes;
        if (r.lights > 0 and lights_row.contains(p, 0)) return .lights;
    }
    return .none;
}

/// Brightness change for a horizontal drag of `dx` pixels: the tile's width spans it all.
pub fn slide_delta(dx: i32) i32 {
    return @divTrunc(dx * 254, tile.w);
}

pub fn render_entry(v: EntryView, pressed: Hit) void {
    const s = v.state;
    const now: EntryShown = .{
        .name = .of(v.name),
        .reachable = s.reachable,
        .on = s.on,
        .bri = s.bri,
        .tint = to565(tile_colour(s)),
        .has_colour = s.hue != null,
        .room = if (v.room) |r| .{ r.scenes, r.lights } else null,
        .pressed = pressed,
    };
    const old: ?EntryShown = if (shown == .entry) shown.entry else null;
    const full = old == null;
    if (full) {
        dirty = true;
        lcd.fill(0, 0, lcd.width, lcd.height, bg);
    }
    const o = old orelse now;
    if (full or !std.meta.eql(o.name, now.name) or o.reachable != now.reachable or (o.pressed == .back) != (pressed == .back)) {
        dirty = true;
        draw_header(.{ .title = .{ .name = v.name, .warn = !s.reachable } }, pressed);
    }
    if (full or o.on != now.on or !std.meta.eql(o.bri, now.bri) or o.tint != now.tint or o.reachable != now.reachable or (o.pressed == .tile) != (pressed == .tile)) {
        dirty = true;
        draw_tile(s, pressed == .tile);
    }
    if (now.has_colour and (full or o.tint != now.tint or (o.pressed == .colour) != (pressed == .colour))) {
        dirty = true;
        draw_colour_button(s, pressed == .colour);
    }
    if (v.room) |r| if (full or !std.meta.eql(o.room, now.room) or (o.pressed == .scenes) != (pressed == .scenes) or (o.pressed == .lights) != (pressed == .lights)) {
        dirty = true;
        draw_link(scenes_row, "SCENES", r.scenes, pressed == .scenes);
        draw_link(lights_row, "LIGHTS", r.lights, pressed == .lights);
    };
    shown = .{ .entry = now };
}

/// The light's colour, dimmed with its brightness but always recognisable: the tile is a
/// picture of the light. Dark when off.
fn tile_colour(s: hue.LightState) Rgb {
    if (!s.on) return .{ .r = 34, .g = 34, .b = 40 };
    const base = colour_of(s);
    const level: u32 = 70 + @as(u32, s.bri orelse 254) * 185 / 254;
    return .{
        .r = @intCast(@as(u32, base.r) * level / 255),
        .g = @intCast(@as(u32, base.g) * level / 255),
        .b = @intCast(@as(u32, base.b) * level / 255),
    };
}

/// Black text on light colours, white on dark ones.
fn fg_on(c: Rgb) Rgb {
    const luma = (@as(u32, c.r) * 299 + @as(u32, c.g) * 587 + @as(u32, c.b) * 114) / 1000;
    return if (luma > 140) .{ .r = 16, .g = 16, .b = 16 } else .{ .r = 245, .g = 245, .b = 245 };
}

fn draw_tile(s: hue.LightState, is_pressed: bool) void {
    const c = tile_colour(s);
    const back = to565(c);
    const fg = to565(fg_on(c));
    const r = tile;
    lcd.fill(r.x, r.y, r.w, r.h, back);
    if (is_pressed) {
        // A frame while the finger is on it.
        lcd.fill(r.x, r.y, r.w, 3, fg);
        lcd.fill(r.x, r.y + r.h - 3, r.w, 3, fg);
        lcd.fill(r.x, r.y, 3, r.h, fg);
        lcd.fill(r.x + r.w - 3, r.y, 3, r.h, fg);
    }
    var buf: [8]u8 = undefined;
    const big = if (!s.reachable)
        "OFFLINE"
    else if (!s.on)
        "OFF"
    else if (s.bri) |b|
        std.fmt.bufPrint(&buf, "{}%", .{pct(b)}) catch unreachable
    else
        "ON";
    text_centered(.{ .x = r.x, .y = r.y + 14, .w = r.w, .h = 56 }, big, if (big.len > 4) 4 else 6, fg, back);
    const hint = if (s.bri != null) "TAP: ON/OFF   SLIDE: LEVEL" else "TAP: ON/OFF";
    text_centered(.{ .x = r.x, .y = r.y + 80, .w = r.w, .h = 10 }, hint, 1, fg, back);

    // The level as a gauge along the bottom, also when off: where it comes back on.
    if (s.bri) |b| {
        const g: Rect = .{ .x = r.x + 16, .y = r.y + r.h - 26, .w = r.w - 32, .h = 8 };
        const filled: u16 = @intCast(@max(2, @as(u32, b) * g.w / 254));
        const rest = to565(.{ .r = c.r / 2, .g = c.g / 2, .b = c.b / 2 });
        lcd.fill(g.x, g.y, filled, g.h, fg);
        lcd.fill(g.x + filled, g.y, g.w - filled, g.h, rest);
    }
}

fn draw_colour_button(s: hue.LightState, is_pressed: bool) void {
    const r = colour_button;
    const back = if (is_pressed) pressed_bg else panel;
    rounded(r.x, r.y, r.w, r.h, back);
    rounded(r.x + 8, r.y + 7, 24, 24, to565(colour_of(s)));
    text(r.x + 42, r.y + r.h / 2 - 7, "COLOUR", 2, bright_text, back);
    // A rainbow, as a hint of what opens.
    const strip_x = r.x + 124;
    const strip_w = 64;
    for (0..strip_w / 4) |i| {
        const h: u16 = @intCast(i * 65535 / (strip_w / 4));
        lcd.fill(strip_x + @as(u16, @intCast(i)) * 4, r.y + 13, 4, 12, to565(hsv_to_rgb(h, 254)));
    }
    draw_chevron(r.x + r.w - 16, r.y + r.h / 2, .right, faint);
}

/// SCENES or LIGHTS on a room's page: a row leading to the list, or dim without one.
fn draw_link(r: Rect, label: []const u8, count: usize, is_pressed: bool) void {
    const back = if (is_pressed) pressed_bg else bg;
    lcd.fill(r.x, r.y, r.w, r.h, back);
    lcd.fill(r.x + 16, r.y, r.w - 32, 1, panel);
    const live = count > 0;
    text(16, r.y + r.h / 2 - 7, label, 2, if (live) bright_text else faint, back);
    var buf: [8]u8 = undefined;
    const n = std.fmt.bufPrint(&buf, "{}", .{count}) catch unreachable;
    text(lcd.width - 34 - text_width(n, 2), r.y + r.h / 2 - 7, n, 2, if (live) dim_text else faint, back);
    if (live) draw_chevron(lcd.width - 18, r.y + r.h / 2, .right, faint);
}

pub fn pct(bri: u8) u8 {
    return @intCast((@as(u32, bri) * 100 + 127) / 254);
}

/// The light's colour at full value, as switches and swatches show it.
pub fn colour_of(s: hue.LightState) Rgb {
    if (s.hue == null or s.sat == null) return warm_white;
    return hsv_to_rgb(s.hue.?, s.sat.?);
}

// ---- forgetting the bridge ----

const yes_button: Rect = .{ .x = 16, .y = 196, .w = lcd.width - 32, .h = 48 };
const no_button: Rect = .{ .x = 16, .y = 256, .w = lcd.width - 32, .h = 48 };

pub fn confirm_hit(p: Point) Hit {
    if (yes_button.contains(p, 4)) return .confirm_yes;
    if (no_button.contains(p, 4)) return .confirm_no;
    return .none;
}

pub fn render_confirm(pressed: Hit) void {
    const full = shown != .confirm;
    if (!full and std.meta.eql(shown.confirm, pressed)) return;
    dirty = true;
    if (full) {
        lcd.fill(0, 0, lcd.width, lcd.height, bg);
        text_centered(.{ .x = 0, .y = 60, .w = lcd.width, .h = 16 }, "FORGET THE", 2, bright_text, bg);
        text_centered(.{ .x = 0, .y = 86, .w = lcd.width, .h = 16 }, "BRIDGE?", 2, bright_text, bg);
        text_centered(.{ .x = 0, .y = 124, .w = lcd.width, .h = 10 }, "IT WILL HAVE TO BE FOUND", 1, dim_text, bg);
        text_centered(.{ .x = 0, .y = 140, .w = lcd.width, .h = 10 }, "AND PAIRED AGAIN", 1, dim_text, bg);
    }
    const red = if (pressed == .confirm_yes) lcd.rgb(200, 60, 45) else lcd.rgb(150, 30, 20);
    rounded(yes_button.x, yes_button.y, yes_button.w, yes_button.h, red);
    text_centered(yes_button, "FORGET", 2, bright_text, red);
    const grey = if (pressed == .confirm_no) pressed_bg else panel;
    rounded(no_button.x, no_button.y, no_button.w, no_button.h, grey);
    text_centered(no_button, "CANCEL", 2, bright_text, grey);
    shown = .{ .confirm = pressed };
}
