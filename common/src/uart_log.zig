//! The UART0 logger of the RTOS samples (115200 baud, the Wokwi serial monitor), as a
//! `uart_log` module: `.logFn = @import("uart_log").log` in `std_options`.
//!
//! Several tasks log (Wi-Fi driver, lwIP, main), so the shared line buffer is behind an RTOS
//! mutex. In a trap or a panic interrupts are off and that mutex can't be taken: the line is
//! then written without it, or the error report itself would deadlock and the board would
//! just freeze.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

var mutex: hal.rtos.Mutex = .{};
var buf: [256]u8 = undefined;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const locked = microzig.interrupt.globally_enabled();
    if (locked) mutex.lock();
    defer if (locked) mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}
