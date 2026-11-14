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
    // In a trap or a panic (interrupts off) the RTOS mutex can't be taken: write unlocked,
    // or the error report itself would deadlock.
    const locked = microzig.interrupt.globally_enabled();
    if (locked) log_mutex.lock();
    defer if (locked) log_mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&log_buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

const ssid = "Wokwi-GUEST";

// A global: the store holds a 4 KiB page buffer.
var store: flash.Nvs = undefined;

var failures: u32 = 0;

fn expect(ok: bool, comptime what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.log.err("check failed: " ++ what, .{});
}

/// Waits until the station reaches `state`, or fails after `timeout_ms`: a test that hangs
/// says less than one that fails.
fn wait_for(comptime state: wifi.StaState, timeout_ms: u64) error{WifiTimeout}!void {
    const start = time_ms();
    while (true) {
        const now = wifi.get_sta_state();
        const reached = if (state == .started) now.is_started() else now == state;
        if (reached) return;
        if (time_ms() - start >= timeout_ms) {
            std.log.err("wifinvs test: FAIL (Wi-Fi not {t} after {} ms)", .{ state, timeout_ms });
            return error.WifiTimeout;
        }
        rtos.sleep(.from_ms(100));
    }
}

fn time_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}

fn log_calibration() ?radio.PhyCalibration {
    const cal = radio.phy_calibration() orelse {
        std.log.err("the PHY was not enabled", .{});
        return null;
    };
    std.log.info("phy calibration: {t}{s}{s}", .{
        cal.mode,
        if (cal.data_check_failed) ", saved data rejected" else "",
        if (cal.saved) ", saved to nvs" else "",
    });
    return cal;
}

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
        try wait_for(.started, 5_000);
        const cal = log_calibration();
        expect(cal != null and cal.?.mode == .full and cal.?.saved, "boot 1 calibrates fully and saves");
        try wifi.connect();
        try wait_for(.connected, 30_000);
        std.log.info("connected to `{s}`", .{ssid});

        {
            wifi.lock_nvs();
            defer wifi.unlock_nvs();
            _ = store.open("nvs.net80211", .read_only) catch |err| {
                std.log.err("the driver wrote no namespace: {t}", .{err});
                failures += 1;
            };
            const phy_ns = store.open("phy", .read_only) catch |err| blk: {
                std.log.err("no phy namespace: {t}", .{err});
                failures += 1;
                break :blk null;
            };
            if (phy_ns) |h| expect((h.blob_len("cal_data") catch 0) > 0, "the calibration data is saved");
        }
        if (failures > 0) {
            std.log.err("wifinvs test: FAIL ({} checks failed)", .{failures});
            return;
        }
        std.log.info("first boot: config saved, resetting", .{});
        rtos.sleep(.from_ms(50)); // let the UART drain
        reset_chip();
    }

    expect(std.mem.eql(u8, saved, ssid), "the station ssid survived the reset");

    // The PHY is enabled by `start`: now it must reuse the data the first boot saved.
    // `wifi.init` resets the mode, so set it again; the saved station config stays.
    try wifi.set_mode(.sta);
    try wifi.start();
    try wait_for(.started, 5_000);
    const cal = log_calibration();
    expect(cal != null and cal.?.mode == .partial and !cal.?.data_check_failed, "boot 2 reuses the calibration data");
    try wifi.connect();
    try wait_for(.connected, 30_000);
    std.log.info("connected again, from the saved config", .{});

    if (failures == 0) {
        std.log.info("wifinvs test: PASS", .{});
    } else {
        std.log.err("wifinvs test: FAIL ({} checks failed)", .{failures});
    }
    while (true) rtos.sleep(.from_ms(1000));
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
