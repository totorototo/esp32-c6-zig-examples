//! The UART0 logger (115200 baud, the Wokwi serial monitor), as a `uart_log` module:
//! `.logFn = @import("uart_log").log` in `std_options`, or `.log_unlocked` in firmware
//! without the RTOS.
//!
//! Several tasks log (Wi-Fi driver, lwIP, main), so `log` keeps the shared line buffer behind
//! an RTOS mutex. In a trap or a panic interrupts are off and that mutex can't be taken: the
//! line is then written without it, or the error report itself would deadlock and the board
//! would just freeze.
//!
//! A line longer than the buffer is cut and ends with ` [cut]`, rather than dropped: a
//! missing line reads as "it never happened", which is the wrong conclusion.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

var mutex: hal.rtos.Mutex = .{};
var buf: [256]u8 = undefined;

const cut = " [cut]\r\n";

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const locked = microzig.interrupt.globally_enabled();
    if (locked) mutex.lock();
    defer if (locked) mutex.unlock();
    write_line(level, scope, format, args);
}

/// For firmware without the RTOS: one task, nothing to lock against (and no scheduler to
/// take a mutex from).
pub fn log_unlocked(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    write_line(level, scope, format, args);
}

fn write_line(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_text = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ scope_text;
    // A fixed writer fills up to its end before failing, so what fits is kept.
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - cut.len]);
    w.print(prefix ++ format ++ "\r\n", args) catch {
        hal.uart.write(0, w.buffered());
        hal.uart.write(0, cut);
        return;
    };
    hal.uart.write(0, w.buffered());
}
