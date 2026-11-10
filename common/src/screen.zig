//! The touch screen shared by the screen examples: a 2.8" ILI9341 240x320 SPI TFT (`lcd`)
//! with an FT6206/FT6236 capacitive touch controller on I2C (`touch`), a 5x7 font that
//! scales up to 8x, colour conversions, and text drawing.
//!
//! An example gets it with `common.add_screen(b, fw)` in its build.zig.
const std = @import("std");
pub const lcd = @import("screen/ili9341.zig");
pub const touch = @import("screen/ft6206.zig");
pub const font = @import("screen/font.zig");
pub const colour = @import("screen/colour.zig");

pub const Point = touch.Point;
pub const Rgb = colour.Rgb;

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    /// Touch targets reach `slack` pixels above and below the drawn area.
    pub fn contains(r: Rect, p: Point, slack: u16) bool {
        return p.x >= r.x and p.x < r.x + r.w and p.y + slack >= r.y and p.y < r.y + r.h + slack;
    }

    /// 0 at the left edge to `max` at the right edge, clamped.
    pub fn position(r: Rect, x: u16, max: u32) u32 {
        const dx: u32 = std.math.clamp(x, r.x, r.x + r.w - 1) - r.x;
        return dx * max / (r.w - 1);
    }
};

pub fn to565(c: Rgb) lcd.Color {
    return lcd.rgb(c.r, c.g, c.b);
}

// ---- text: 5x7 font, each glyph sent as one window with its background ----

const cell_w = font.width + 1;
const cell_h = font.height + 1;

pub fn text_width(s: []const u8, scale: u16) u16 {
    var n: u16 = 0;
    var it: font.Chars = .{ .s = s };
    while (it.next()) |_| n += 1;
    return if (n == 0) 0 else n * cell_w * scale - scale;
}

pub fn text_centered(r: Rect, s: []const u8, scale: u16, fg: lcd.Color, back: lcd.Color) void {
    const w = @min(text_width(s, scale), r.w);
    const h = font.height * scale;
    text(r.x + (r.w - w) / 2, r.y + (r.h -| h) / 2, s, scale, fg, back);
}

/// Draws UTF-8 `s` at (x, y), clipped at the right edge. Lowercase renders as uppercase,
/// accented letters as their base letter, other non-ASCII characters as a box.
pub fn text(x: u16, y: u16, s: []const u8, scale: u16, fg: lcd.Color, back: lcd.Color) void {
    var cx = x;
    var it: font.Chars = .{ .s = s };
    while (it.next()) |c| {
        if (cx + cell_w * scale > lcd.width) return;
        glyph(cx, y, font.glyph(c), scale, fg, back);
        cx += cell_w * scale;
    }
}

fn glyph(x: u16, y: u16, g: font.Glyph, scale: u16, fg: lcd.Color, back: lcd.Color) void {
    var row: [cell_w * 8 * 2]u8 = undefined; // up to scale 8
    std.debug.assert(scale <= 8);
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
