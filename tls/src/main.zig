//! TLS test sample for the ESP32-C6: an HTTPS request to Netatmo's API with Zig's own TLS
//! client, through ../common's `https` module. The first step of the Netatmo remote.
//!
//!   1. Joins Wi-Fi (`-Dssid=... -Dpassword=...`, default `Wokwi-GUEST`).
//!   2. Gets the time over SNTP: certificate dates need it, and the board has no clock.
//!   3. Opens TLS 1.3 to api.netatmo.com:443, verifying the chain up to one pinned root
//!      (DigiCert Global Root G2, valid until 2038) and the host name.
//!   4. Sends `GET /api/homesdata` without a token: Netatmo must answer with its JSON error
//!      (`400 Missing token argument`).
//!
//! Logs go to UART0 (115200 baud) and end with `tls test: PASS` or `tls test: FAIL`.
const std = @import("std");
const microzig = @import("microzig");
const net = @import("net");
const https = @import("https");

const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;

comptime {
    _ = net.exports;
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;

pub const std_options: std.Options = with_page_size(microzig.std_options(.{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
        .{ .scope = .https, .level = .debug },
    },
    .logFn = uart_log,
}));

/// The TLS client's certificate-bundle lock wants an `std.Io`; `std.Io.failing` references
/// file memory maps, which need a page size. Freestanding has none. Never actually used.
fn with_page_size(o: std.Options) std.Options {
    var with = o;
    with.page_size_min = 4096;
    with.page_size_max = 4096;
    return with;
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{ .wifi = .{ .on_packet_received = net.on_packet_received } },
    },
};

var log_mutex: rtos.Mutex = .{};
var log_buf: [256]u8 = undefined;

fn uart_log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // In a trap or a panic (interrupts off) the RTOS mutex can't be taken: write unlocked,
    // or the error report itself would deadlock and the board would just freeze.
    const mstatus = asm volatile ("csrr %[r], mstatus"
        : [r] "=r" (-> u32),
    );
    const locked = mstatus & 0x8 != 0;
    if (locked) log_mutex.lock();
    defer if (locked) log_mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&log_buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

var response: [4096]u8 = undefined;

pub fn main() !void {
    std.log.info("tls on ESP32-C6, cpu clock {} MHz", .{hal.clock_config.cpu_clk_freq / 1_000_000});
    // What the heap leaves for the main task's stack (not the heap's size): HTTPS needs
    // 112 KiB, see ../common/src/https.zig.
    var heap: microzig.Allocator = try .init_with_heap(112 * 1024);
    try net.up(heap.allocator());

    run() catch |err| {
        std.log.err("tls test: FAIL ({t})", .{err});
        return;
    };
}

fn run() !void {
    try https.sync_time();
    const resp = try https.request("api.netatmo.com", "GET", "/api/homesdata", &.{}, "", &response);
    std.log.info("HTTP {}", .{resp.status});
    std.log.info("body: {s}", .{resp.body[0..@min(resp.body.len, 200)]});

    // Without a token, Netatmo answers `400 Missing token argument` with
    // {"error":{"code":1,"message":"Access token is missing"}}. Any 4xx with that error object
    // shows the request went through, encrypted, and the API read it.
    if (resp.status / 100 != 4 or std.mem.indexOf(u8, resp.body, "\"error\"") == null) return error.UnexpectedAnswer;
    std.log.info("tls test: PASS", .{});
}
