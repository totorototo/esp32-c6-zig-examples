//! FT6206/FT6236 capacitive touch controller on I2C (address 0x38), polled. The INT pin
//! is left unconnected: the main loop already ticks every 20 ms.
const std = @import("std");
const microzig = @import("microzig");
const ili9341 = @import("ili9341.zig");

const hal = microzig.hal;
const gpio = hal.gpio;
const Duration = microzig.drivers.time.Duration;

const log = std.log.scoped(.touch);

pub const Point = struct { x: u16, y: u16 };

const address: hal.i2c.Address = @fromBackingInt(0x38);
const timeout: Duration = .from_ms(20);
const reg_touches = 0x02; // TD_STATUS, then P1_XH, P1_XL, P1_YH, P1_YL
const reg_vendor = 0xA8; // FocalTech: 0x11

var i2c0 = hal.i2c.instance.num(0);

pub fn init(sda: gpio.Pin, scl: gpio.Pin) !void {
    inline for (.{ sda, scl }) |pin| {
        pin.apply(.{ .output_enable = true, .input_enable = true, .open_drain = true, .pull = .up });
    }
    i2c0.connect_pins(.{ .sda = sda, .scl = scl });
    try i2c0.apply(400_000);

    var vendor: [1]u8 = undefined;
    try read_regs(reg_vendor, &vendor);
    if (vendor[0] != 0x11) log.warn("unexpected vendor id 0x{X:0>2}, carrying on", .{vendor[0]});
}

fn read_regs(reg: u8, dst: []u8) !void {
    // Two transactions (write the register, then read), as Adafruit's driver does: the
    // chip accepts a STOP between them.
    try i2c0.write_blocking(address, &.{reg}, timeout);
    try i2c0.read_blocking(address, dst, timeout);
}

/// The first touch point in screen coordinates, or null when nothing touches the panel.
pub fn read() !?Point {
    var buf: [5]u8 = undefined;
    try read_regs(reg_touches, &buf);
    const count = buf[0] & 0x0F;
    if (count == 0 or count > 2) return null; // 0x0F after power-up means "no data"
    // The high bytes' top bits are event flags (down/up/contact).
    const x = @as(u16, buf[1] & 0x0F) << 8 | buf[2];
    const y = @as(u16, buf[3] & 0x0F) << 8 | buf[4];
    // The panel reports both axes mirrored relative to MADCTL 0x48 (Adafruit's examples
    // flip both too).
    return .{
        .x = ili9341.width - 1 - @min(x, ili9341.width - 1),
        .y = ili9341.height - 1 - @min(y, ili9341.height - 1),
    };
}
