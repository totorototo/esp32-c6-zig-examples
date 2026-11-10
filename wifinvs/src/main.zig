//! Wi-Fi + NVS test sample for the ESP32-C6: the Wi-Fi driver keeps its configuration in the
//! flash's `nvs` partition (`InitConfig.nvs`), like ESP-IDF does.
//!
//! The first boot applies a station config and joins `Wokwi-GUEST`, then resets the CPU. The
//! second boot asks the driver for its station config right after `wifi.init`, before applying
//! anything: the SSID must be the one the first boot saved.
//!
//! Logs go to UART0 (TX = GPIO16, 115200 baud) and end with `wifinvs test: PASS` or
//! `wifinvs test: FAIL`.
const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const flash = hal.flash;
const rtos = hal.rtos;
const radio = hal.radio;
const wifi = radio.wifi;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
    .logFn = uart_log,
});

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{},
    },
};

comptime {
    _ = microzig.export_startup();
}

// The Wi-Fi driver and main both log, so the shared line buffer needs a lock.
var log_mutex: rtos.Mutex = .{};
var log_buf: [256]u8 = undefined;

fn uart_log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&log_buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

const ssid = "Wokwi-GUEST";

// A global: the store holds a 4 KiB page buffer.
var store: flash.Nvs = undefined;

pub fn main() !void {
    std.log.info("wifinvs on ESP32-C6", .{});

    const partition = try flash.partition_table.find_data(.nvs, null) orelse {
        std.log.err("no nvs partition in the partition table", .{});
        std.log.err("wifinvs test: FAIL", .{});
        return;
    };
    try store.init(partition.region(), partition.size);

    // The application's own keys, before Wi-Fi shares the store (after `wifi.init`, use
    // `wifi.lock_nvs`).
    const settings = try store.open("sample", .read_write);
    const boots = (settings.get(u32, "boots") catch |err| switch (err) {
        error.NotFound => 0,
        else => return err,
    }) + 1;
    try settings.set(u32, "boots", boots);
    std.log.info("boot {}", .{boots});

    var heap: microzig.Allocator = try .init_with_heap(16384);
    try wifi.init(heap.allocator(), .{ .nvs = &store });

    var buf: [32]u8 = undefined;
    const saved = try wifi.get_sta_ssid(&buf);
    std.log.info("station ssid after init: `{s}`", .{saved});

    if (boots == 1) {
        try wifi.apply(.{ .sta = .{ .ssid = ssid, .auth_method = .none } });
        try wifi.start();
        while (!wifi.get_sta_state().is_started()) rtos.sleep(.from_ms(100));
        try wifi.connect();
        while (wifi.get_sta_state() != .connected) rtos.sleep(.from_ms(100));
        std.log.info("connected to `{s}`", .{ssid});

        {
            wifi.lock_nvs();
            defer wifi.unlock_nvs();
            _ = store.open("nvs.net80211", .read_only) catch |err| {
                std.log.err("the driver wrote no namespace: {t}", .{err});
                std.log.err("wifinvs test: FAIL", .{});
                return;
            };
        }
        std.log.info("first boot: config saved, resetting", .{});
        rtos.sleep(.from_ms(50)); // let the UART drain
        // CPU reset: Wokwi ignores the C6 system reset.
        hal.rom.software_reset_cpu();
    }

    if (std.mem.eql(u8, saved, ssid)) {
        std.log.info("wifinvs test: PASS", .{});
    } else {
        std.log.err("wifinvs test: FAIL (expected `{s}`)", .{ssid});
    }
    while (true) rtos.sleep(.from_ms(1000));
}
