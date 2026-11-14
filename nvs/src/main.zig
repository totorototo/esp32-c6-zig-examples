//! NVS test sample for the ESP32-C6: settings that survive a reset, stored in the flash's `nvs`
//! partition in ESP-IDF's NVS format.
//!
//! Each boot increments a counter. The first boot also stores a string and a blob, then resets
//! the chip; the second boot checks that everything is still there. A long loop of counter
//! updates then fills the partition several times over, to exercise page reclaiming.
//!
//! Logs go to UART0 (TX = GPIO16, 115200 baud) and end with `nvs test: PASS` or
//! `nvs test: FAIL`.
const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const flash = hal.flash;
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

// A global: the store holds a 4 KiB page buffer.
var store: flash.Nvs = undefined;

// 6000 bytes: more than a page, so the blob is stored in chunks. Globals, to keep them off the
// stack.
var blob: [6000]u8 = undefined;
var buf: [6000]u8 = undefined;

const greeting = "hello from the first boot";
const churn_count = 600;

var failures: u32 = 0;

fn expect(ok: bool, comptime what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.log.err("check failed: " ++ what, .{});
}

fn blob_byte(i: usize) u8 {
    return @truncate(i *% 31 +% (i >> 8));
}

pub fn main() !void {
    std.log.info("nvs on ESP32-C6", .{});

    var it: flash.partition_table.Iterator = .{};
    while (try it.next()) |p| {
        std.log.info("partition {s}: type {} subtype {} at 0x{x}, {} KiB", .{
            p.label(), @backingInt(p.type), p.subtype, p.offset, p.size / 1024,
        });
    }

    const partition = try flash.partition_table.find_data(.nvs, null) orelse {
        std.log.err("no nvs partition in the partition table", .{});
        std.log.err("nvs test: FAIL", .{});
        return;
    };

    var start = time.get_time_since_boot();
    try store.init(partition.region(), partition.size);
    std.log.info("store opened in {} us", .{time.get_time_since_boot().diff(start).to_us()});

    const settings = try store.open("sample", .read_write);

    const boots = (settings.get(u32, "boots") catch |err| switch (err) {
        error.NotFound => 0,
        else => return err,
    }) + 1;
    try settings.set(u32, "boots", boots);
    std.log.info("boot {}", .{boots});

    if (boots == 1) {
        for (&blob, 0..) |*b, i| b.* = blob_byte(i);
        try settings.set_str("greeting", greeting);
        try settings.set(i16, "offset", -1234);
        try settings.set_blob("blob", &blob);
        std.log.info("first boot: values stored, resetting", .{});
        time.sleep_ms(50); // let the UART drain
        reset_chip();
    }

    // Second boot (or later, on hardware): everything must have survived the reset.
    expect(boots >= 2, "the boot counter survived");
    expect(std.mem.eql(u8, try settings.get_str("greeting", &buf), greeting), "the string survived");
    expect(try settings.get(i16, "offset") == -1234, "the integer survived");
    const stored = try settings.get_blob("blob", &buf);
    var blob_ok = stored.len == blob.len;
    for (stored, 0..) |b, i| blob_ok = blob_ok and b == blob_byte(i);
    expect(blob_ok, "the blob survived");
    expect(settings.get(u8, "missing") == error.NotFound, "a missing key is reported");
    expect(settings.get(u32, "offset") == error.TypeMismatch, "a wrong type is reported");
    std.log.info("values read back after the reset", .{});

    // Each update appends an entry and erases the old one: this fills the partition several
    // times and forces pages to be reclaimed (erased) while the other values stay in place.
    start = time.get_time_since_boot();
    for (0..churn_count) |i| try settings.set(u32, "churn", @intCast(i));
    const churn_us = time.get_time_since_boot().diff(start).to_us();
    std.log.info("{} updates in {} ms", .{ churn_count, churn_us / 1000 });

    expect(try settings.get(u32, "churn") == churn_count - 1, "the last update is the one read");
    expect(std.mem.eql(u8, try settings.get_str("greeting", &buf), greeting), "the string survived the reclaims");
    expect((try settings.get_blob("blob", &buf)).len == blob.len, "the blob survived the reclaims");

    // Opening the partition again from scratch must find the same state.
    try store.init(partition.region(), partition.size);
    const reopened = try store.open("sample", .read_only);
    expect(try reopened.get(u32, "churn") == churn_count - 1, "the store reopens with the same values");
    expect(try reopened.get(u32, "boots") == boots, "the boot counter is still there");

    if (failures == 0) {
        std.log.info("nvs test: PASS", .{});
    } else {
        std.log.err("nvs test: FAIL ({} checks failed)", .{failures});
    }
    while (true) {}
}

/// Reboots the whole chip (radio and peripherals too, like the reset button). Wokwi ignores
/// the C6 system reset, so if the chip is still running a moment later, a CPU reset (which
/// Wokwi does) takes over. On hardware the system reset always wins: a CPU-only reset would
/// leave the radio and the other peripherals running into the next boot.
fn reset_chip() noreturn {
    microzig.chip.peripherals.LP_AON.SYS_CFG.modify(.{ .HPSYS_SW_RESET = 1 });
    hal.rom.delay_us(10_000);
    hal.rom.software_reset_cpu();
}
