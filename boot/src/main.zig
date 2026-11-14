//! Boot test sample for the ESP32-C6: one firmware, built for the three ways a C6 can start it
//! (see build.zig). Each boot path lays memory out differently, so the firmware checks what the
//! startup code and the linker script must get right:
//!   - initialised data was copied to RAM (direct boot copies it from flash itself),
//!   - zero-initialised data is zero,
//!   - code marked for RAM runs from RAM, and other code runs from where the target says,
//!   - read-only data is readable.
//!
//! Logs go to UART0 (TX = GPIO16, 115200 baud) and end with `boot test: PASS` or
//! `boot test: FAIL`, then a line every second.
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");

const hal = microzig.hal;
const time = hal.time;

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

const ram = struct {
    const start = 0x4080_0000;
    const end = 0x4088_0000;
    fn contains(addr: usize) bool {
        return addr >= start and addr < end;
    }
};
const flash_window = struct {
    const start = 0x4200_0000;
    const end = 0x4300_0000;
    fn contains(addr: usize) bool {
        return addr >= start and addr < end;
    }
};

// `.data`: must hold these values at startup, whoever loaded it.
var data_words: [4]u32 = .{ 0x1234_5678, 0x9abc_def0, 0x0f1e_2d3c, 0x4b5a_6978 };
// `.bss`: must be zero at startup.
var bss_zeroed: [64]u32 = @splat(0);
// `.rodata`.
const rodata_table = [_]u16{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };

/// Returns the address it runs at.
noinline fn in_ram() linksection(".ram_text") usize {
    return asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> usize),
    );
}

/// Returns the address it runs at.
noinline fn in_text() usize {
    return asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> usize),
    );
}

var failures: u32 = 0;

fn expect(ok: bool, comptime what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.log.err("check failed: " ++ what, .{});
}

/// Reads memory for real. Plain reads can be answered at compile time: `rodata_table` is
/// comptime-known, and LLVM turns a global nobody writes (`bss_zeroed`) into a constant, so
/// the checks below would pass whatever the startup code did.
fn read(comptime T: type, items: *const T) T {
    return @as(*const volatile T, items).*;
}

pub fn main() !void {
    std.log.info("boot test on ESP32-C6, {s}", .{config.mode});

    expect(std.mem.eql(u32, &read([4]u32, &data_words), &.{ 0x1234_5678, 0x9abc_def0, 0x0f1e_2d3c, 0x4b5a_6978 }), "initialised data");
    var zero = true;
    for (read([64]u32, &bss_zeroed)) |w| zero = zero and w == 0;
    expect(zero, "zero-initialised data");

    var sum: u32 = 0;
    for (read(@TypeOf(rodata_table), &rodata_table)) |p| sum += p;
    expect(sum == 197, "read-only data");

    const ram_fn = in_ram();
    const text_fn = in_text();
    const rodata = @intFromPtr(&rodata_table);
    std.log.info("ram code at 0x{x}, code at 0x{x}, rodata at 0x{x}", .{ ram_fn, text_fn, rodata });
    expect(ram.contains(ram_fn), "RAM code runs from RAM");
    const ram_image = std.mem.eql(u8, config.mode, "flashless");
    expect(if (ram_image) ram.contains(text_fn) else flash_window.contains(text_fn), "code is where the target puts it");
    expect(if (ram_image) ram.contains(rodata) else flash_window.contains(rodata), "rodata is where the target puts it");

    // Writable data really is RAM.
    data_words[0] +%= 1;
    expect(data_words[0] == 0x1234_5679, "initialised data is writable");

    if (failures == 0) {
        std.log.info("boot test: PASS", .{});
    } else {
        std.log.err("boot test: FAIL ({} checks failed)", .{failures});
    }

    var n: u32 = 0;
    while (true) : (n += 1) {
        time.sleep_ms(1000);
        std.log.info("alive {}", .{n});
    }
}
