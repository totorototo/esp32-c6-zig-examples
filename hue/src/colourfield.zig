//! The colour field, shared by both UIs: the screen becomes a hue x saturation picker (hue
//! across, vivid at the top, white at the bottom) above a strip that explains what letting
//! go does. Letting go on the strip cancels.
//!
//! It takes about 150 KiB of SPI writes to fill, so `render` draws a slice per call: touch
//! keeps being read while it fills in.
const std = @import("std");
const screen = @import("screen");
const lcd = screen.lcd;
const colour = screen.colour;
const hue = @import("hue.zig");
const Point = screen.Point;

pub const field_h = 280;
const strip: screen.Rect = .{ .x = 0, .y = field_h, .w = lcd.width, .h = lcd.height - field_h };

var hue_row: [lcd.width]colour.Rgb = undefined;
var rows_drawn: u16 = 0;
var cursor: ?Point = null;
var strip_shown: ?Strip = null;

/// What the strip says.
pub const Strip = enum {
    /// Opened by a tap, nothing touched yet.
    pick,
    /// A finger on the field.
    set,
    /// A finger on the strip.
    cancel,
};

/// Call when the field leaves the screen, so the next `render` starts from scratch.
pub fn reset() void {
    rows_drawn = 0;
    cursor = null;
    strip_shown = null;
}

pub fn on_strip(p: Point) bool {
    return p.y >= field_h;
}

pub fn colour_at(p: Point) hue.Change {
    const x = @min(p.x, lcd.width - 1);
    const y = @min(p.y, field_h - 1);
    return .{
        .on = true,
        .hue = @intCast(@as(u32, x) * 65535 / (lcd.width - 1)),
        .sat = @intCast(254 - @as(u32, y) * 254 / (field_h - 1)),
    };
}

/// Draws the next slice of the field, the strip, and the ring at `finger` (null: none).
pub fn render(finger: ?Point) void {
    const label: Strip = if (finger) |p| (if (on_strip(p)) .cancel else .set) else .pick;
    if (strip_shown != label) {
        // The strip first, so it shows the moment the field opens.
        const back = if (label == .cancel) lcd.rgb(150, 30, 20) else lcd.rgb(0, 0, 0);
        lcd.fill(strip.x, strip.y, strip.w, strip.h, back);
        screen.text_centered(strip, switch (label) {
            .pick => "HERE: CANCEL",
            .set => "LET GO TO SET",
            .cancel => "LET GO: CANCEL",
        }, 2, lcd.rgb(240, 240, 240), back);
        strip_shown = label;
    }

    if (rows_drawn < field_h) {
        if (rows_drawn == 0) {
            for (&hue_row, 0..) |*c, x| c.* = colour.hsv_to_rgb(@intCast(x * 65535 / (lcd.width - 1)), 254);
        }
        const rows_per_call = 30;
        const n = @min(rows_per_call, field_h - rows_drawn);
        var row: [lcd.width * 2]u8 = undefined;
        lcd.begin(0, rows_drawn, lcd.width, n);
        for (rows_drawn..rows_drawn + n) |y| {
            const sat = row_sat(@intCast(y));
            for (hue_row, 0..) |c, x| lcd.put(&row, x, blend(c, sat));
            lcd.pixels(&row);
        }
        lcd.end();
        rows_drawn += n;
        if (rows_drawn < field_h) return;
    }

    const at: ?Point = if (finger) |p| (if (on_strip(p)) null else .{ .x = @min(p.x, lcd.width - 1), .y = p.y }) else null;
    if (cursor) |old| {
        if (at) |a| if (old.x == a.x and old.y == a.y) return;
        draw_cursor(old, false);
    }
    if (at) |a| draw_cursor(a, true);
    cursor = at;
}

fn field_pixel(x: u16, y: u16) lcd.Color {
    return blend(hue_row[x], row_sat(y));
}

/// Saturation of row `y` as 0..256, for shifts instead of divisions.
fn row_sat(y: u16) u32 {
    return 256 - @as(u32, y) * 256 / (field_h - 1);
}

fn blend(c: colour.Rgb, s: u32) lcd.Color {
    return lcd.rgb(
        @intCast(255 - ((255 - @as(u32, c.r)) * s >> 8)),
        @intCast(255 - ((255 - @as(u32, c.g)) * s >> 8)),
        @intCast(255 - ((255 - @as(u32, c.b)) * s >> 8)),
    );
}

const ring = 9; // radius of the cursor's outer edge

/// A white ring with a dark edge, or (`on` false) the field it covers, restored.
fn draw_cursor(c: Point, on: bool) void {
    const x0 = c.x -| ring;
    const y0 = c.y -| ring;
    const x1 = @min(c.x + ring + 1, lcd.width);
    const y1 = @min(c.y + ring + 1, field_h);
    if (x1 <= x0 or y1 <= y0) return;
    var row: [(2 * ring + 1) * 2]u8 = undefined;
    lcd.begin(x0, y0, x1 - x0, y1 - y0);
    defer lcd.end();
    for (y0..y1) |y| {
        for (x0..x1, 0..) |x, i| {
            const dx = @as(i32, @intCast(x)) - c.x;
            const dy = @as(i32, @intCast(y)) - c.y;
            const d2 = dx * dx + dy * dy;
            const px = if (on and d2 > 3 * 3 and d2 <= 6 * 6)
                lcd.rgb(255, 255, 255)
            else if (on and d2 > 6 * 6 and d2 <= ring * ring)
                lcd.rgb(20, 20, 20)
            else
                field_pixel(@intCast(x), @intCast(y));
            lcd.put(&row, i, px);
        }
        lcd.pixels(row[0 .. 2 * (x1 - x0)]);
    }
}
