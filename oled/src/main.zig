//! SSD1306 128x64 I2C OLED demo for the ESP32-C6.
//!
//! Exercises the C6 I2C HAL: each frame pushes the full 1 KiB framebuffer, which the HAL
//! splits into FIFO-sized chunks. Logs go to UART0 (TX = GPIO16, 115200 baud), so they show
//! up in the Wokwi serial monitor and on the DevKitC's USB-UART port.
//!
//! Wiring: SDA = GPIO22, SCL = GPIO23, address 0x3C, 3V3 and GND.
const std = @import("std");
const microzig = @import("microzig");
const font = @import("font.zig");

const hal = microzig.hal;
const gpio = hal.gpio;
const time = hal.time;
const mdf = microzig.drivers;
const I2C_DatagramDevice = hal.drivers.I2C_DatagramDevice;

const Display = mdf.display.ssd1306.SSD1306_Generic(.{
    .mode = .i2c,
    .DatagramDevice = I2C_DatagramDevice,
});
const Framebuffer = mdf.display.ssd1306.Framebuffer;

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

const i2c_freq = 400_000;
const oled_addr = 0x3C;

var i2c0 = hal.i2c.instance.num(0);
var fb: Framebuffer = .init(.black);

pub fn main() !void {
    std.log.info("oled on ESP32-C6, cpu clock {} MHz", .{hal.clock_config.cpu_clk_freq / 1_000_000});

    // GPIO22/23: free on the DevKitC-1 and not strapping or JTAG pins (GPIO4-7 are JTAG,
    // GPIO8/9/15 are strapping). Open drain with pull-ups; real modules also have their own.
    const sda = gpio.num(22);
    const scl = gpio.num(23);
    inline for (.{ sda, scl }) |pin| {
        pin.apply(.{ .output_enable = true, .input_enable = true, .open_drain = true, .pull = .up });
    }
    i2c0.connect_pins(.{ .sda = sda, .scl = scl });
    try i2c0.apply(i2c_freq);

    const dev = I2C_DatagramDevice.init(i2c0, @fromBackingInt(oled_addr), mdf.time.Duration.from_ms(100));
    const display = Display.init(dev) catch |err| {
        std.log.err("SSD1306 init at 0x{X:0>2} failed: {s} (check wiring)", .{ oled_addr, @errorName(err) });
        return err;
    };
    std.log.info("SSD1306 ready at 0x{X:0>2}, I2C {} kHz", .{ oled_addr, i2c_freq / 1000 });

    var frame: u32 = 0;
    var text_buf: [24]u8 = undefined;
    while (true) : (frame += 1) {
        fb.clear(.black);
        draw_text(0, 0, "MICROZIG ESP32-C6", 1);
        draw_text(0, 10, std.fmt.bufPrint(&text_buf, "I2C {} KHZ ADDR {X:0>2}", .{ i2c_freq / 1000, oled_addr }) catch unreachable, 1);
        draw_text(0, 24, std.fmt.bufPrint(&text_buf, "{d:0>5}", .{frame % 100_000}) catch unreachable, 3);
        draw_bouncer(frame);

        const start = time.get_time_since_boot();
        try display.write_full_display(fb.bit_stream());
        const took = time.get_time_since_boot().diff(start).to_us();

        // 1025 bytes at 9 clocks each is ~23 ms at 400 kHz; much faster means the bus clock is off.
        if (frame % 50 == 0) std.log.info("frame {}: framebuffer write took {} us", .{ frame, took });
        time.sleep_ms(50);
    }
}

/// Draws `text` with its top-left corner at (x, y), each font pixel scaled to `scale`x`scale`.
fn draw_text(x: u32, y: u32, text: []const u8, scale: u32) void {
    for (text, 0..) |c, i| {
        const gx = x + @as(u32, @intCast(i)) * (font.width + 1) * scale;
        for (font.glyph(c), 0..) |column, col| {
            for (0..font.height) |row| {
                if (column & (@as(u8, 1) << @intCast(row)) == 0) continue;
                fill_rect(gx + @as(u32, @intCast(col)) * scale, y + @as(u32, @intCast(row)) * scale, scale, scale);
            }
        }
    }
}

/// A small square bouncing along the bottom row, so a frozen display is obvious.
fn draw_bouncer(frame: u32) void {
    const size = 6;
    const span = Framebuffer.width - size;
    const pos = frame * 3 % (2 * span);
    const x = if (pos < span) pos else 2 * span - pos;
    fill_rect(x, Framebuffer.height - size, size, size);
}

fn fill_rect(x: u32, y: u32, w: u32, h: u32) void {
    var py = y;
    while (py < @min(y + h, Framebuffer.height)) : (py += 1) {
        var px = x;
        while (px < @min(x + w, Framebuffer.width)) : (px += 1) {
            fb.set_pixel(@intCast(px), @intCast(py), .white);
        }
    }
}

test {
    _ = font;
}
