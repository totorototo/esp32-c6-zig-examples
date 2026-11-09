//! ILI9341 240x320 TFT over 4-wire SPI (SCK, MOSI, CS, D/C), write-only, portrait.
//!
//! No framebuffer: callers draw rectangles and pixel runs straight into the panel's RAM.
//! A full 240x320x16-bit buffer would take 150 KiB of the C6's SRAM, next to Wi-Fi and lwIP.
const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const gpio = hal.gpio;

pub const width = 240;
pub const height = 320;

/// RGB565.
pub const Color = u16;

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return @as(u16, r >> 3) << 11 | @as(u16, g >> 2) << 5 | b >> 3;
}

pub const Pins = struct {
    sck: gpio.Pin,
    mosi: gpio.Pin,
    cs: gpio.Pin,
    dc: gpio.Pin,
    rst: gpio.Pin,
};

/// The C6's only general-purpose SPI. `init` takes it over, so the WS2812 LED loses it.
const spi = hal.spi.instance.SPI2;
const baud_rate = 40_000_000;
var pins: Pins = undefined;

pub fn init(p: Pins) void {
    pins = p;
    // apply() routes each pin to plain GPIO first, which also detaches the LED's data pin
    // if the caller re-applies it.
    inline for (.{ p.sck, p.mosi, p.cs, p.dc, p.rst }) |pin| pin.apply(.{ .output_enable = true });
    p.cs.put(1);
    p.dc.put(1);
    spi.connect_pins(.{ .data = .{ .single_two_wires = .{ .mosi = p.mosi } }, .clk = p.sck });
    spi.apply(.{ .clock_config = hal.clock_config, .baud_rate = baud_rate, .bit_order = .msb_first });

    p.rst.put(1);
    hal.time.sleep_ms(5);
    p.rst.put(0);
    hal.time.sleep_ms(20);
    p.rst.put(1);
    hal.time.sleep_ms(150);

    for (init_sequence) |step| {
        command(step.cmd, step.data);
        if (step.delay_ms > 0) hal.time.sleep_ms(step.delay_ms);
    }
}

const Step = struct { cmd: u8, data: []const u8 = &.{}, delay_ms: u32 = 0 };

/// From Adafruit_ILI9341: power, VCOM and gamma settings real panels need. Wokwi only
/// cares about MADCTL, COLMOD, SLPOUT and DISPON.
const init_sequence = [_]Step{
    .{ .cmd = 0x01, .delay_ms = 150 }, // SWRESET
    .{ .cmd = 0xEF, .data = &.{ 0x03, 0x80, 0x02 } },
    .{ .cmd = 0xCF, .data = &.{ 0x00, 0xC1, 0x30 } },
    .{ .cmd = 0xED, .data = &.{ 0x64, 0x03, 0x12, 0x81 } },
    .{ .cmd = 0xE8, .data = &.{ 0x85, 0x00, 0x78 } },
    .{ .cmd = 0xCB, .data = &.{ 0x39, 0x2C, 0x00, 0x34, 0x02 } },
    .{ .cmd = 0xF7, .data = &.{0x20} },
    .{ .cmd = 0xEA, .data = &.{ 0x00, 0x00 } },
    .{ .cmd = 0xC0, .data = &.{0x23} }, // PWCTR1
    .{ .cmd = 0xC1, .data = &.{0x10} }, // PWCTR2
    .{ .cmd = 0xC5, .data = &.{ 0x3E, 0x28 } }, // VMCTR1
    .{ .cmd = 0xC7, .data = &.{0x86} }, // VMCTR2
    // MADCTL: MX (mirror columns) | BGR, the panel's upright portrait. The FT6206 then
    // reports both axes mirrored (ft6206.zig flips them back).
    .{ .cmd = 0x36, .data = &.{0x48} },
    .{ .cmd = 0x37, .data = &.{0x00} }, // VSCRSADD
    .{ .cmd = 0x3A, .data = &.{0x55} }, // COLMOD: 16 bits per pixel
    .{ .cmd = 0xB1, .data = &.{ 0x00, 0x18 } }, // FRMCTR1
    .{ .cmd = 0xB6, .data = &.{ 0x08, 0x82, 0x27 } }, // DFUNCTR
    .{ .cmd = 0xF2, .data = &.{0x00} }, // 3-gamma off
    .{ .cmd = 0x26, .data = &.{0x01} }, // GAMMASET
    .{ .cmd = 0xE0, .data = &.{ 0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E, 0xF1, 0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00 } },
    .{ .cmd = 0xE1, .data = &.{ 0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31, 0xC1, 0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F } },
    .{ .cmd = 0x11, .delay_ms = 150 }, // SLPOUT
    .{ .cmd = 0x29, .delay_ms = 20 }, // DISPON
};

fn command(cmd: u8, data: []const u8) void {
    pins.cs.put(0);
    defer pins.cs.put(1);
    pins.dc.put(0);
    spi.write_blocking(&.{cmd}, .single_two_wires);
    pins.dc.put(1);
    if (data.len > 0) spi.write_blocking(data, .single_two_wires);
}

/// Selects the window (x, y, w, h) and starts a pixel write. Follow with `pixels`, then `end`.
pub fn begin(x: u16, y: u16, w: u16, h: u16) void {
    std.debug.assert(w > 0 and h > 0 and x + w <= width and y + h <= height);
    const x1 = x + w - 1;
    const y1 = y + h - 1;
    command(0x2A, &.{ @truncate(x >> 8), @truncate(x), @truncate(x1 >> 8), @truncate(x1) }); // CASET
    command(0x2B, &.{ @truncate(y >> 8), @truncate(y), @truncate(y1 >> 8), @truncate(y1) }); // PASET
    pins.cs.put(0);
    pins.dc.put(0);
    spi.write_blocking(&.{0x2C}, .single_two_wires); // RAMWR; CS stays low for the pixels
    pins.dc.put(1);
}

/// Big-endian RGB565 bytes, filling the window row by row.
pub fn pixels(bytes: []const u8) void {
    spi.write_blocking(bytes, .single_two_wires);
}

pub fn end() void {
    pins.cs.put(1);
}

pub fn put(buf: []u8, i: usize, color: Color) void {
    buf[2 * i] = @truncate(color >> 8);
    buf[2 * i + 1] = @truncate(color);
}

pub fn fill(x: u16, y: u16, w: u16, h: u16, color: Color) void {
    if (w == 0 or h == 0) return;
    // One FIFO's worth (64 bytes): the HAL splits every write into chunks of that size anyway.
    var buf: [hal.spi.fifo_byte_len]u8 = undefined;
    for (0..buf.len / 2) |i| put(&buf, i, color);
    begin(x, y, w, h);
    defer end();
    var left: u32 = @as(u32, w) * h * 2;
    while (left > 0) {
        const n = @min(left, buf.len);
        pixels(buf[0..n]);
        left -= n;
    }
}
