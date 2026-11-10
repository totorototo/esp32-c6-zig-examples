//! Colour conversions for drawing what a Hue light shows: hue/sat (the bridge's HSV),
//! CIE xy (what most scenes store) and colour temperature in mireds. Results are sRGB at
//! full value; brightness is applied separately. Pure, tested on the host.
const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const warm_white: Rgb = .{ .r = 255, .g = 190, .b = 110 };

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

/// The inverse of `hsv_to_rgb`, ignoring value: hue 0..65535 and saturation 0..254.
pub fn rgb_to_hue_sat(c: Rgb) struct { hue: u16, sat: u8 } {
    const max = @max(c.r, c.g, c.b);
    const min = @min(c.r, c.g, c.b);
    if (max == 0 or max == min) return .{ .hue = 0, .sat = 0 };
    const d: i32 = @as(i32, max) - min;
    const sat: u8 = @intCast(@as(u32, @intCast(d)) * 254 / max);
    // Sector 0..6 in 1/65536 steps of the full circle.
    const h6: i32 = if (max == c.r)
        @divTrunc((@as(i32, c.g) - c.b) * 65536, d)
    else if (max == c.g)
        2 * 65536 + @divTrunc((@as(i32, c.b) - c.r) * 65536, d)
    else
        4 * 65536 + @divTrunc((@as(i32, c.r) - c.g) * 65536, d);
    const h = @mod(@divTrunc(h6, 6), 65536);
    return .{ .hue = @intCast(h), .sat = sat };
}

/// CIE 1931 xy to sRGB, normalised so the largest channel is 255 (Philips' published
/// conversion, wide-gamut D65 matrix, sRGB companding).
pub fn xy_to_rgb(x: f32, y: f32) Rgb {
    if (y <= 0.0001) return .{ .r = 255, .g = 255, .b = 255 };
    const Y: f32 = 1.0;
    const X = Y / y * x;
    const Z = Y / y * (1.0 - x - y);
    var rgb = [3]f32{
        X * 1.656492 - Y * 0.354851 - Z * 0.255038,
        -X * 0.707196 + Y * 1.655397 + Z * 0.036152,
        X * 0.051713 - Y * 0.121364 + Z * 1.011530,
    };
    var max: f32 = 0;
    for (&rgb) |*c| {
        c.* = @max(c.*, 0);
        c.* = if (c.* <= 0.0031308) 12.92 * c.* else 1.055 * std.math.pow(f32, c.*, 1.0 / 2.4) - 0.055;
        max = @max(max, c.*);
    }
    if (max <= 0) return .{ .r = 255, .g = 255, .b = 255 };
    return .{
        .r = @intFromFloat(@round(rgb[0] / max * 255)),
        .g = @intFromFloat(@round(rgb[1] / max * 255)),
        .b = @intFromFloat(@round(rgb[2] / max * 255)),
    };
}

/// Colour temperature in mireds (153 = 6500 K cool, 500 = 2000 K warm), between two
/// measured white points. Close enough for a swatch.
pub fn ct_to_rgb(mired: u16) Rgb {
    const cool: Rgb = .{ .r = 230, .g = 240, .b = 255 };
    const warm: Rgb = .{ .r = 255, .g = 147, .b = 44 };
    const m: u32 = std.math.clamp(mired, 153, 500) - 153;
    const span = 500 - 153;
    return .{
        .r = @intCast((@as(u32, cool.r) * (span - m) + @as(u32, warm.r) * m) / span),
        .g = @intCast((@as(u32, cool.g) * (span - m) + @as(u32, warm.g) * m) / span),
        .b = @intCast((@as(u32, cool.b) * (span - m) + @as(u32, warm.b) * m) / span),
    };
}

/// Averages colours channel by channel.
pub const Mix = struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    bri: u32 = 0,
    n: u32 = 0,

    pub fn add(m: *Mix, c: Rgb, bri: u8) void {
        m.r += c.r;
        m.g += c.g;
        m.b += c.b;
        m.bri += bri;
        m.n += 1;
    }

    pub fn colour(m: Mix) ?Rgb {
        if (m.n == 0) return null;
        return .{ .r = @intCast(m.r / m.n), .g = @intCast(m.g / m.n), .b = @intCast(m.b / m.n) };
    }

    pub fn brightness(m: Mix) u8 {
        return if (m.n == 0) 0 else @intCast(m.bri / m.n);
    }
};

const testing = std.testing;

test "xy: the white point is white, the gamut corners are their primaries" {
    const white = xy_to_rgb(0.3127, 0.3290);
    try testing.expect(white.r > 230 and white.g > 230 and white.b > 230);
    const red = xy_to_rgb(0.700, 0.299);
    try testing.expect(red.r == 255 and red.g < 60 and red.b < 60);
    const green = xy_to_rgb(0.172, 0.747);
    try testing.expect(green.g == 255 and green.r < 120 and green.b < 120);
    const blue = xy_to_rgb(0.135, 0.039);
    try testing.expect(blue.b == 255 and blue.r < 120 and blue.g < 60);
    // A Hue "Relax" warm white.
    const relax = xy_to_rgb(0.5019, 0.4152);
    try testing.expect(relax.r == 255 and relax.g > 130 and relax.g < 220 and relax.b < 110);
}

test "ct: ends and middle" {
    try testing.expectEqual(Rgb{ .r = 230, .g = 240, .b = 255 }, ct_to_rgb(153));
    try testing.expectEqual(Rgb{ .r = 255, .g = 147, .b = 44 }, ct_to_rgb(500));
    try testing.expectEqual(ct_to_rgb(500), ct_to_rgb(600)); // clamped
    const mid = ct_to_rgb(326);
    try testing.expect(mid.r > 240 and mid.b > 120 and mid.b < 170);
}

test "rgb to hue/sat round-trips through hsv" {
    for ([_]u16{ 0, 5000, 12000, 21845, 30000, 43690, 50000, 60000 }) |h| {
        const back = rgb_to_hue_sat(hsv_to_rgb(h, 254));
        try testing.expect(@abs(@as(i32, back.hue) - h) < 400);
        try testing.expect(back.sat >= 250);
    }
    try testing.expectEqual(@as(u8, 0), rgb_to_hue_sat(.{ .r = 90, .g = 90, .b = 90 }).sat);
}

test "mix" {
    var m: Mix = .{};
    try testing.expectEqual(null, m.colour());
    m.add(.{ .r = 255, .g = 0, .b = 0 }, 200);
    m.add(.{ .r = 0, .g = 0, .b = 255 }, 100);
    try testing.expectEqual(Rgb{ .r = 127, .g = 0, .b = 127 }, m.colour().?);
    try testing.expectEqual(@as(u8, 150), m.brightness());
}
