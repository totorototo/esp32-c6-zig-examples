//! The touch screen's two pages, drawn and hit-tested. Navigation lives in screen.zig.
//!
//!   list                          settings
//!   +------------------------+    +------------------------+
//!   | LIGHTS | ROOMS | SCENES|    | < LIGHT NAME           |  back
//!   | [#] Hue color spot 1   |    | [        ON          ] |  tap to toggle
//!   | [ ] Bureau             |    | BRIGHTNESS 75%         |
//!   |  :   (6 rows a page)   |    | [#########-----------] |  drag
//!   |                        |    | COLOUR                 |
//!   |                        |    | [rainbow strip    |  ] |  drag (colour only)
//!   |   <      1/2      >    |    | [        WHITE       ] |  tap: saturation 0
//!   +------------------------+    +------------------------+
//!   swatch: tap toggles, name: tap opens settings; on SCENES, a tap recalls the scene
//!
//! Both renderers redraw only what changed since the last call, so the main loop can call
//! them every tick.
const std = @import("std");
const lcd = @import("ili9341.zig");
const font = @import("font.zig");
const hue = @import("hue.zig");
const catalog = @import("catalog.zig");
const Point = @import("ft6206.zig").Point;

const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    /// Touch targets reach `slack` pixels above and below the drawn area.
    fn contains(r: Rect, p: Point, slack: u16) bool {
        return p.x >= r.x and p.x < r.x + r.w and p.y + slack >= r.y and p.y < r.y + r.h + slack;
    }

    /// 0 at the left edge to `max` at the right edge, clamped.
    fn position(r: Rect, x: u16, max: u32) u32 {
        const dx: u32 = std.math.clamp(x, r.x, r.x + r.w - 1) - r.x;
        return dx * max / (r.w - 1);
    }
};

const margin = 16;
const inner_w = lcd.width - 2 * margin;

const bg = lcd.rgb(16, 16, 20);
const panel = lcd.rgb(48, 48, 54);
const dim_text = lcd.rgb(150, 150, 160);
const bright_text = lcd.rgb(240, 240, 240);
const warn_text = lcd.rgb(255, 90, 70);
const black = lcd.rgb(0, 0, 0);
const warm_white: Rgb = .{ .r = 255, .g = 190, .b = 110 };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// What the screen currently shows. Anything but the page being rendered forces a full
/// redraw of that page.
const Shown = union(enum) {
    nothing,
    list: ListShown,
    settings: hue.LightState,
};
var shown: Shown = .nothing;

/// Full-screen message (boot, pairing, errors), up to two lines split at '\n'.
pub fn message(msg: []const u8, color: lcd.Color) void {
    shown = .nothing;
    lcd.fill(0, 0, lcd.width, lcd.height, bg);
    var lines = std.mem.splitScalar(u8, msg, '\n');
    var y: u16 = 130;
    while (lines.next()) |line| : (y += 30) {
        text_centered(.{ .x = 0, .y = y, .w = lcd.width, .h = 16 }, line, 2, color, bg);
    }
}

// ---- list page ----

pub const Tab = enum {
    lights,
    rooms,
    scenes,

    fn label(t: Tab) []const u8 {
        return switch (t) {
            .lights => "LIGHTS",
            .rooms => "ROOMS",
            .scenes => "SCENES",
        };
    }
};

pub const rows_per_page = 6;
const tab_h = 40;
const row_h = 40;
const rows_y = 44;
const swatch_hit_w = 56; // the swatch's touch target: everything left of the name
const footer: Rect = .{ .x = 0, .y = rows_y + rows_per_page * row_h + 4, .w = lcd.width, .h = lcd.height - (rows_y + rows_per_page * row_h + 4) };
const prev_button: Rect = .{ .x = 0, .y = footer.y, .w = 80, .h = footer.h };
const next_button: Rect = .{ .x = lcd.width - 80, .y = footer.y, .w = 80, .h = footer.h };

fn tab_rect(t: Tab) Rect {
    const w = lcd.width / 3;
    return .{ .x = @as(u16, @intFromEnum(t)) * w, .y = 0, .w = w, .h = tab_h };
}

fn row_rect(r: usize) Rect {
    return .{ .x = 0, .y = @intCast(rows_y + r * row_h), .w = lcd.width, .h = row_h };
}

/// Rows of entries per page: the SCENES tab gives its first row to the room filter.
pub fn rows_for(tab: Tab) u8 {
    return if (tab == .scenes) rows_per_page - 1 else rows_per_page;
}

pub fn page_count(tab: Tab, entries: usize) u8 {
    const per = rows_for(tab);
    return @intCast(@max(1, (entries + per - 1) / per));
}

pub const ListHit = union(enum) {
    none,
    tab: Tab,
    /// The room filter's arrows (SCENES tab).
    filter_prev,
    filter_next,
    /// Indices into the tab's entries.
    toggle: usize,
    open: usize,
    prev,
    next,
};

pub fn list_hit(p: Point, tab: Tab, page: u8, entries: usize) ListHit {
    if (p.y < tab_h) return .{ .tab = @enumFromInt(@min(p.x / (lcd.width / 3), 2)) };
    if (prev_button.contains(p, 0)) return .prev;
    if (next_button.contains(p, 0)) return .next;
    if (p.y < rows_y) return .none;
    var r = (p.y - rows_y) / row_h;
    if (r >= rows_per_page) return .none;
    if (tab == .scenes) {
        if (r == 0) return if (p.x < lcd.width / 2) .filter_prev else .filter_next;
        r -= 1;
    }
    const i = @as(usize, page) * rows_for(tab) + r;
    if (i >= entries) return .none;
    return if (p.x < swatch_hit_w) .{ .toggle = i } else .{ .open = i };
}

/// One row of a list, whatever it lists.
pub const Row = struct {
    name: []const u8,
    /// A second, smaller line (a scene's room); empty for none.
    sub: []const u8 = "",
    swatch: Swatch,

    pub const Swatch = union(enum) {
        on: Rgb,
        off,
        unreachable_,
        /// A scene: a play mark, filled for the one last recalled.
        scene: bool,
    };

    pub fn of_entry(e: *const catalog.Entry) Row {
        return .{ .name = e.name(), .swatch = if (!e.state.reachable)
            .unreachable_
        else if (e.state.on)
            .{ .on = colour_of(e.state) }
        else
            .off };
    }

    pub fn of_scene(sc: *const catalog.Scene) Row {
        return .{ .name = sc.name(), .sub = sc.room(), .swatch = .{ .scene = catalog.is_recalled(sc) } };
    }
};

/// A copy of what a row shows, comparable from one frame to the next.
const RowShown = struct {
    present: bool = false,
    name_buf: [32]u8 = @splat(0),
    name_len: u8 = 0,
    sub_buf: [32]u8 = @splat(0),
    sub_len: u8 = 0,
    swatch: Row.Swatch = .off,

    fn of(row: Row) RowShown {
        var r: RowShown = .{ .present = true, .swatch = row.swatch };
        r.name_len = @intCast(@min(row.name.len, r.name_buf.len));
        @memcpy(r.name_buf[0..r.name_len], row.name[0..r.name_len]);
        r.sub_len = @intCast(@min(row.sub.len, r.sub_buf.len));
        @memcpy(r.sub_buf[0..r.sub_len], row.sub[0..r.sub_len]);
        return r;
    }
};

const ListShown = struct {
    tab: Tab,
    page: u8,
    pages: u8,
    filter_buf: [32]u8 = @splat(0),
    filter_len: u8 = 0,
    rows: [rows_per_page]RowShown,
};

/// Draws page `page` of `pages`. `rows` are that page's rows (at most `rows_for(tab)`).
/// On the SCENES tab, `filter` labels the room filter drawn in the first row.
pub fn render_list(tab: Tab, page: u8, pages: u8, rows: []const Row, filter: []const u8) void {
    var now: ListShown = .{ .tab = tab, .page = page, .pages = pages, .rows = @splat(.{}) };
    const first_row: usize = if (tab == .scenes) 1 else 0;
    for (rows, first_row..) |row, r| now.rows[r] = .of(row);
    if (tab == .scenes) {
        now.filter_len = @intCast(@min(filter.len, now.filter_buf.len));
        @memcpy(now.filter_buf[0..now.filter_len], filter[0..now.filter_len]);
    }

    const full = switch (shown) {
        .list => |old| old.tab != tab or old.page != page or old.pages != now.pages or
            !std.mem.eql(u8, old.filter_buf[0..old.filter_len], now.filter_buf[0..now.filter_len]),
        else => true,
    };
    if (full) {
        lcd.fill(0, 0, lcd.width, lcd.height, bg);
        for (std.enums.values(Tab)) |t| draw_tab(t, t == tab);
        if (tab == .scenes) draw_filter(now.filter_buf[0..now.filter_len]);
        if (now.pages > 1) draw_footer(page, now.pages);
        if (rows.len == 0) text_centered(row_rect(2), "NOTHING HERE", 2, dim_text, bg);
    }
    for (now.rows[first_row..], first_row..) |row, r| {
        if (!full and std.meta.eql(row, shown.list.rows[r])) continue;
        draw_row(r, row);
    }
    shown = .{ .list = now };
}

/// The SCENES tab's first row: `<  ROOM  >`, tap either half to step through the rooms.
fn draw_filter(label: []const u8) void {
    const rect = row_rect(0);
    lcd.fill(rect.x, rect.y, rect.w, rect.h - 1, panel);
    text(margin, rect.y + 11, "<", 2, bright_text, panel);
    text(lcd.width - margin - 10, rect.y + 11, ">", 2, bright_text, panel);
    const inner: Rect = .{ .x = 36, .y = rect.y, .w = lcd.width - 72, .h = rect.h };
    if (text_width(label, 2) <= inner.w)
        text_centered(inner, label, 2, bright_text, panel)
    else
        text_centered(inner, label, 1, bright_text, panel);
}

fn draw_tab(t: Tab, active: bool) void {
    const r = tab_rect(t);
    const back = if (active) panel else bg;
    lcd.fill(r.x, r.y, r.w, r.h, back);
    text_centered(r, t.label(), 2, if (active) bright_text else dim_text, back);
    if (active) lcd.fill(r.x, r.y + r.h - 3, r.w, 3, to565(warm_white));
}

fn draw_row(r: usize, row: RowShown) void {
    const rect = row_rect(r);
    lcd.fill(rect.x, rect.y, rect.w, rect.h - 1, bg);
    lcd.fill(rect.x + margin, rect.y + rect.h - 1, rect.w - 2 * margin, 1, panel); // separator
    if (!row.present) return;

    // Swatch: filled with the colour when on, hollow when off, red when unreachable.
    const sx = 14;
    const sy = rect.y + 6;
    const size = 28;
    switch (row.swatch) {
        .on => |c| lcd.fill(sx, sy, size, size, to565(c)),
        .off, .unreachable_ => {
            lcd.fill(sx, sy, size, size, if (row.swatch == .off) dim_text else warn_text);
            lcd.fill(sx + 2, sy + 2, size - 4, size - 4, bg);
        },
        .scene => |recalled| draw_play(sx, sy, size, if (recalled) to565(warm_white) else dim_text),
    }
    const name_colour = if (row.swatch == .unreachable_) warn_text else bright_text;
    const name = row.name_buf[0..row.name_len];
    // Names too long for the large font ("Hue color spot 1" ends in what tells it apart)
    // drop to the small one, which fits 30 characters.
    const avail = lcd.width - swatch_hit_w - 4;
    const big = text_width(name, 2) <= avail;
    if (row.sub_len == 0) {
        if (big) text(swatch_hit_w, rect.y + 13, name, 2, name_colour, bg) else text(swatch_hit_w, rect.y + 16, name, 1, name_colour, bg);
    } else {
        if (big) text(swatch_hit_w, rect.y + 5, name, 2, name_colour, bg) else text(swatch_hit_w, rect.y + 9, name, 1, name_colour, bg);
        text(swatch_hit_w, rect.y + 25, row.sub_buf[0..row.sub_len], 1, dim_text, bg);
    }
}

/// A right-pointing triangle, one column at a time.
fn draw_play(x: u16, y: u16, size: u16, c: lcd.Color) void {
    const inset = 4;
    const h = size - 2 * inset;
    for (0..h / 2 + 1) |i| {
        const col: u16 = @intCast(i * 2);
        const half: u16 = @intCast(h / 2 - i);
        // Two pixels wide per step, so the triangle is as wide as it is tall.
        lcd.fill(x + inset + col, y + inset + (h / 2 - half), 2, 2 * half + 1, c);
    }
}

fn draw_footer(page: u8, pages: u8) void {
    var buf: [8]u8 = undefined;
    text_centered(footer, std.fmt.bufPrint(&buf, "{}/{}", .{ page + 1, pages }) catch unreachable, 2, dim_text, bg);
    text_centered(prev_button, "<", 3, if (page > 0) bright_text else panel, bg);
    text_centered(next_button, ">", 3, if (page + 1 < pages) bright_text else panel, bg);
}

// ---- settings page ----

const header: Rect = .{ .x = 0, .y = 0, .w = lcd.width, .h = 36 };
const back_button: Rect = .{ .x = 0, .y = 0, .w = 56, .h = 40 };
const power: Rect = .{ .x = margin, .y = 48, .w = inner_w, .h = 80 };
const bri_label: Rect = .{ .x = margin, .y = 140, .w = inner_w, .h = 8 };
const bri_bar: Rect = .{ .x = margin, .y = 154, .w = inner_w, .h = 40 };
const hue_label: Rect = .{ .x = margin, .y = 206, .w = inner_w, .h = 8 };
const hue_bar: Rect = .{ .x = margin, .y = 220, .w = inner_w, .h = 40 };
const white: Rect = .{ .x = margin, .y = 272, .w = inner_w, .h = 36 };

pub const Control = enum { none, back, power, brightness, hue, white };

/// Which control a touch starts on. Drags stay on that control until release.
pub fn control_at(p: Point, light: hue.LightState) Control {
    if (back_button.contains(p, 0)) return .back;
    if (power.contains(p, 6)) return .power;
    if (light.bri != null and bri_bar.contains(p, 10)) return .brightness;
    if (light.hue != null and hue_bar.contains(p, 10)) return .hue;
    if (light.hue != null and white.contains(p, 4)) return .white;
    return .none;
}

/// Brightness 1..254 under `x` on the brightness bar.
pub fn brightness_at(x: u16) u8 {
    return @intCast(1 + bri_bar.position(x, 253));
}

/// Hue 0..65535 under `x` on the colour strip.
pub fn hue_at(x: u16) u16 {
    return @intCast(hue_bar.position(x, 65535));
}

var shown_name_buf: [32]u8 = undefined;
var shown_name: []const u8 = "";

pub fn render_settings(name: []const u8, light: hue.LightState) void {
    const first = shown != .settings;
    const old = if (shown == .settings) shown.settings else light;
    if (first) lcd.fill(0, 0, lcd.width, lcd.height, bg);

    if (first or !std.mem.eql(u8, name, shown_name) or old.reachable != light.reachable) {
        lcd.fill(header.x, header.y, header.w, header.h, panel);
        text(14, 11, "<", 2, bright_text, panel);
        const name_x = back_button.w - 16;
        const name_colour = if (light.reachable) bright_text else warn_text;
        if (text_width(name, 2) <= lcd.width - name_x - 4)
            text(name_x, 14, name, 2, name_colour, panel)
        else
            text(name_x, 15, name, 1, name_colour, panel);
        const n = @min(name.len, shown_name_buf.len);
        @memcpy(shown_name_buf[0..n], name[0..n]);
        shown_name = shown_name_buf[0..n];
    }

    if (first or old.on != light.on or !std.meta.eql(old.hue, light.hue) or !std.meta.eql(old.sat, light.sat)) {
        const fill = if (light.on) to565(colour_of(light)) else panel;
        lcd.fill(power.x, power.y, power.w, power.h, fill);
        text_centered(power, if (light.on) "ON" else "OFF", 4, if (light.on) black else dim_text, fill);
    }

    if (light.bri) |bri| {
        if (first or old.on != light.on or !std.meta.eql(old.bri, light.bri)) {
            var buf: [16]u8 = undefined;
            const pct = (@as(u32, bri) * 100 + 127) / 254;
            label_row(bri_label, std.fmt.bufPrint(&buf, "BRIGHTNESS {}%", .{pct}) catch unreachable);
            const filled: u16 = @intCast(@as(u32, bri) * bri_bar.w / 254);
            const level = if (light.on) to565(warm_white) else lcd.rgb(110, 110, 110);
            lcd.fill(bri_bar.x, bri_bar.y, filled, bri_bar.h, level);
            lcd.fill(bri_bar.x + filled, bri_bar.y, bri_bar.w - filled, bri_bar.h, panel);
        }
    }

    if (light.hue != null and (first or !std.meta.eql(old.hue, light.hue) or !std.meta.eql(old.sat, light.sat))) {
        label_row(hue_label, "COLOUR");
        draw_hue_strip(light);
        const is_white = (light.sat orelse 0) < 64;
        const fill = if (is_white) to565(warm_white) else panel;
        lcd.fill(white.x, white.y, white.w, white.h, fill);
        text_centered(white, "WHITE", 2, if (is_white) black else dim_text, fill);
    }

    shown = .{ .settings = light };
}

fn draw_hue_strip(light: hue.LightState) void {
    // One row, computed once, sent `h` times: the strip only varies along x.
    var row: [inner_w * 2]u8 = undefined;
    const marker: ?u16 = if ((light.sat orelse 0) >= 64) @intCast(@as(u32, light.hue.?) * (hue_bar.w - 1) / 65535) else null;
    for (0..hue_bar.w) |i| {
        const c: lcd.Color = if (marker) |m| blk: {
            const d = @abs(@as(i32, @intCast(i)) - m);
            break :blk if (d <= 1) black else if (d == 2) bright_text else to565(hsv_to_rgb(hue_at(hue_bar.x + @as(u16, @intCast(i))), 254));
        } else to565(hsv_to_rgb(hue_at(hue_bar.x + @as(u16, @intCast(i))), 254));
        lcd.put(&row, i, c);
    }
    lcd.begin(hue_bar.x, hue_bar.y, hue_bar.w, hue_bar.h);
    defer lcd.end();
    for (0..hue_bar.h) |_| lcd.pixels(&row);
}

/// The light's colour at full value, as the power button shows it.
fn colour_of(light: hue.LightState) Rgb {
    if (light.hue == null or light.sat == null) return warm_white;
    return hsv_to_rgb(light.hue.?, light.sat.?);
}

fn label_row(r: Rect, s: []const u8) void {
    lcd.fill(r.x, r.y, r.w, r.h, bg);
    text(r.x, r.y, s, 1, dim_text, bg);
}

// ---- text: 5x7 font, each glyph sent as one window with its background ----

const cell_w = font.width + 1;
const cell_h = font.height + 1;

fn text_width(s: []const u8, scale: u16) u16 {
    var n: u16 = 0;
    var it: font.Chars = .{ .s = s };
    while (it.next()) |_| n += 1;
    return if (n == 0) 0 else n * cell_w * scale - scale;
}

fn text_centered(r: Rect, s: []const u8, scale: u16, fg: lcd.Color, back: lcd.Color) void {
    const w = @min(text_width(s, scale), r.w);
    const h = font.height * scale;
    text(r.x + (r.w - w) / 2, r.y + (r.h -| h) / 2, s, scale, fg, back);
}

/// Draws UTF-8 `s` at (x, y), clipped at the right edge. Lowercase renders as uppercase,
/// accented letters as their base letter, other non-ASCII characters as a box.
fn text(x: u16, y: u16, s: []const u8, scale: u16, fg: lcd.Color, back: lcd.Color) void {
    var cx = x;
    var it: font.Chars = .{ .s = s };
    while (it.next()) |c| {
        if (cx + cell_w * scale > lcd.width) return;
        glyph(cx, y, font.glyph(c), scale, fg, back);
        cx += cell_w * scale;
    }
}

fn glyph(x: u16, y: u16, g: font.Glyph, scale: u16, fg: lcd.Color, back: lcd.Color) void {
    var row: [cell_w * 4 * 2]u8 = undefined; // up to scale 4
    std.debug.assert(scale <= 4);
    const w = cell_w * scale;
    const h = cell_h * scale;
    lcd.begin(x, y, w, h);
    defer lcd.end();
    for (0..h) |py| {
        const gy = py / scale;
        for (0..w) |px| {
            const gx = px / scale;
            const on = gx < font.width and gy < font.height and g[gx] & (@as(u8, 1) << @intCast(gy)) != 0;
            lcd.put(&row, px, if (on) fg else back);
        }
        lcd.pixels(row[0 .. 2 * w]);
    }
}

// ---- colour ----

fn to565(c: Rgb) lcd.Color {
    return lcd.rgb(c.r, c.g, c.b);
}

/// Hue 0..65535, saturation 0..254, full value.
pub fn hsv_to_rgb(h: u16, sat: u8) Rgb {
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
