//! RMT test sample for the ESP32-C6: WS2812 LEDs on both RMT transmit channels.
//!
//!   - TX0 -> GPIO8, the on-board RGB LED. One LED is 24 pulse codes, which fits in the
//!     channel's 48 code memory.
//!   - TX1 -> GPIO10, a 16 LED ring. 384 pulse codes: the HAL streams them through the same
//!     48 code memory while the frame is being sent.
//!
//! Each frame is checked (no RMT error, and it took as long as its bit count says) and the
//! result is logged on UART0 (TX = GPIO16, 115200 baud), ending with `rmt test: PASS` or
//! `rmt test: FAIL`. The animation then runs forever.
const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const gpio = hal.gpio;
const rmt = hal.rmt;
const time = hal.time;
const WS2812 = hal.drivers.WS2812_RMT;
const Color = WS2812.Color;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = uart_log,
});

comptime {
    _ = microzig.export_startup();
}

var log_buf: [256]u8 = undefined;

fn uart_log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const line = std.fmt.bufPrint(&log_buf, "[" ++ level.asText() ++ "] " ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

const led_pin = gpio.num(8);
const ring_pin = gpio.num(10);
const ring_len = 16;
/// Per-channel LED level. Wokwi draws the colour as plain RGB, so a level that is bright on a
/// real WS2812 (16 is plenty) looks black in the simulator. Lower it on hardware.
const brightness = 255;

// 40 MHz crystal, undivided: 25 ns ticks, whatever the CPU clock is.
const rmt_config: rmt.Config = .{ .clock_config = hal.clock_config };
const channel_config: rmt.Tx.Config = .{};
const tick_freq = channel_config.tick_freq(rmt_config);

/// A WS2812 bit lasts 1.25 us with the driver's default timing.
const bit_time_ns = 1250;

var led: WS2812 = undefined;
var ring: WS2812 = undefined;
var failures: u32 = 0;

pub fn main() !void {
    std.log.info("rmt on ESP32-C6, cpu clock {} MHz, rmt tick {} ns", .{
        hal.clock_config.cpu_clk_freq / 1_000_000,
        1_000_000_000 / tick_freq,
    });

    rmt.apply(rmt_config);
    inline for (.{ rmt.instance.TX0, rmt.instance.TX1 }, .{ led_pin, ring_pin }) |channel, pin| {
        channel.apply(channel_config);
        channel.connect_pin(pin);
    }
    led = .init(rmt.instance.TX0, tick_freq, .{});
    ring = .init(rmt.instance.TX1, tick_freq, .{});

    // 1. One LED: no streaming.
    check("TX0, 1 LED", &led, &.{.{ .r = brightness, .g = 0, .b = 0 }});

    // 2. Two LEDs fill the memory exactly, so the end marker is the first streamed code.
    var colors: [ring_len]Color = @splat(.{ .r = 0, .g = 0, .b = 0 });
    colors[0] = .{ .r = 0, .g = brightness, .b = 0 };
    colors[1] = .{ .r = 0, .g = 0, .b = brightness };
    check("TX1, 2 LEDs", &ring, colors[0..2]);

    // 3. The whole ring: 8 refills of half the memory.
    for (&colors, 0..) |*color, i| color.* = wheel(@intCast(i * 256 / ring_len));
    check("TX1, 16 LEDs", &ring, &colors);

    if (failures == 0) {
        std.log.info("rmt test: PASS", .{});
    } else {
        std.log.err("rmt test: FAIL ({} checks failed)", .{failures});
    }

    // Rotate the rainbow on the ring, and show its first colour on the on-board LED.
    var step: u8 = 0;
    var underruns: u32 = 0;
    while (true) : (step +%= 4) {
        for (&colors, 0..) |*color, i| color.* = wheel(step +% @as(u8, @intCast(i * 256 / ring_len)));

        ring.write(&colors) catch {
            underruns += 1;
            std.log.warn("ring underrun ({} so far)", .{underruns});
        };
        led.write(colors[0..1]) catch {};

        time.sleep_ms(40);
    }
}

/// Sends one frame and checks that it went out without an error and took the expected time.
fn check(name: []const u8, dev: *WS2812, colors: []const Color) void {
    const expected_us = colors.len * 24 * bit_time_ns / 1000;

    // Let the previous frame's reset time pass, so that `write` doesn't wait for it.
    time.sleep_us(500);

    const start = time.get_time_since_boot();
    const result = dev.write(colors);
    const took_us = time.get_time_since_boot().diff(start).to_us();

    // The frame can't be faster than its bits. On top of them comes the time to encode the
    // first memory fill, about 220 us in Wokwi (its CPU is slow compared to its timers) and a
    // tenth of that on hardware. The upper limit still catches a clock that is twice too slow
    // on the 16 LED frame.
    const ok = if (result) |_|
        took_us >= expected_us and took_us <= expected_us + expected_us / 2 + 300
    else |_|
        false;
    if (!ok) failures += 1;

    if (result) |_| {
        std.log.info("{s}: {s}, {} us (expected about {} us)", .{
            name, if (ok) "ok" else "WRONG DURATION", took_us, expected_us,
        });
    } else |err| {
        std.log.err("{s}: {s} after {} us", .{ name, @errorName(err), took_us });
    }
}

/// A colour wheel: 0 = red, 85 = green, 170 = blue.
fn wheel(pos: u8) Color {
    const level = brightness;
    const third: u8 = pos / 85;
    const x: u8 = @intCast(@as(u16, pos % 85) * level / 85);
    return switch (third) {
        0 => .{ .r = level - x, .g = x, .b = 0 },
        1 => .{ .r = 0, .g = level - x, .b = x },
        else => .{ .r = x, .g = 0, .b = level - x },
    };
}
