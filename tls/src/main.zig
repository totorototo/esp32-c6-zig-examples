//! TLS test sample for the ESP32-C6: an HTTPS request to Netatmo's API with Zig's own TLS
//! client (`std.crypto.tls`), as the first step towards a Netatmo thermostat remote.
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
const lwip = net.lwip;
const sntp = @import("sntp.zig");
const socket = @import("socket.zig");

const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;
const tls = std.crypto.tls;
/// std's TLS client with its handshake buffers moved off the stack (see tls_client.zig).
const TlsClient = @import("tls_client.zig");

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
    },
    .logFn = uart_log,
}));

/// `std.Io.failing` (the TLS client's certificate-bundle lock wants an `Io`) references file
/// memory maps, which need a page size; freestanding has none. Never actually used.
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

const host = "api.netatmo.com";
const ntp_host = "pool.ntp.org";
/// DigiCert Global Root G2, from the macOS system roots; SHA-256 CB3CCBB7...5AB1CB5F, the
/// same as the root api.netatmo.com sends. Pinning the root, not the leaf: the leaf is
/// reissued every six months.
const root_der = @embedFile("digicert_global_root_g2.der");

// Both socket buffers must hold one TLS record (`min_buffer_len`): the client asks its
// output for that much contiguous space before encrypting a record. It asserts this, but
// ReleaseSmall drops asserts: with a smaller socket write buffer, the first encrypted write
// spins forever. The decrypted read buffer holds a whole record too; the plaintext write
// buffer only sets how much goes into one record. Globals, about 52 KiB.
var socket_read: [TlsClient.min_buffer_len]u8 = undefined;
var socket_write: [TlsClient.min_buffer_len]u8 = undefined;
var tls_read: [TlsClient.min_buffer_len]u8 = undefined;
var tls_write: [2048]u8 = undefined;
var bundle_mem: [4096]u8 = undefined;
var response: [4096]u8 = undefined;

pub fn main() !void {
    std.log.info("tls on ESP32-C6, cpu clock {} MHz", .{hal.clock_config.cpu_clk_freq / 1_000_000});
    // The argument is how much the heap leaves for the main task's stack at the top of RAM,
    // not the heap's size: the heap gets the rest. The handshake goes about 130 KiB deep
    // (Client.init's frame alone is 83 KiB). The heap needs about 70 KiB, Wi-Fi's buffers
    // and the RTOS tasks' stacks included.
    var heap: microzig.Allocator = try .init_with_heap(160 * 1024);
    try net.up(heap.allocator());

    run() catch |err| {
        std.log.err("tls test: FAIL ({t})", .{err});
        return;
    };
}

fn run() !void {
    // ---- time ----
    const now = try fetch_time();
    std.log.info("time: {} (Unix seconds) from {s}", .{ now, ntp_host });

    // ---- the trust anchor ----
    var fba: std.heap.FixedBufferAllocator = .init(&bundle_mem);
    const gpa = fba.allocator();
    var bundle: std.crypto.Certificate.Bundle = .empty;
    try bundle.bytes.appendSlice(gpa, root_der);
    try bundle.parseCert(gpa, 0, now);

    // ---- TCP ----
    const addr = try socket.resolve(host);
    var ip_buf: [16]u8 = undefined;
    std.log.info("{s} is {s}", .{ host, socket.ip_text(addr, &ip_buf) });
    var tcp: socket.Tcp = undefined;
    try tcp.connect(addr, 443, &socket_read, &socket_write, 10_000);
    defer tcp.close();

    // ---- TLS ----
    var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
    hal.rng.read(&entropy);
    var lock: std.Io.RwLock = .init;
    var alert: tls.Alert = undefined;
    const t0 = now_ms();
    var client = TlsClient.init(&tcp.reader, &tcp.writer, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{ .gpa = gpa, .io = std.Io.failing, .lock = &lock, .bundle = &bundle } },
        .read_buffer = &tls_read,
        .write_buffer = &tls_write,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = @as(i96, now) * std.time.ns_per_s },
        .alert = &alert,
    }) catch |err| {
        if (err == error.TlsAlert) std.log.err("server alert: {t}", .{alert.description});
        return err;
    };
    std.log.info("TLS {t} handshake in {} ms, chain verified to DigiCert Global Root G2", .{ client.tls_version, now_ms() - t0 });

    // ---- HTTP ----
    try client.writer.writeAll("GET /api/homesdata HTTP/1.1\r\nHost: " ++ host ++ "\r\nUser-Agent: microzig-esp32c6\r\nConnection: close\r\n\r\n");
    try client.writer.flush();
    try tcp.writer.flush();

    const resp = try read_response(&client.reader);
    const status_end = std.mem.indexOf(u8, resp, "\r\n") orelse return error.BadResponse;
    std.log.info("{s}", .{resp[0..status_end]});
    const body_start = (std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse) + 4;
    const body = resp[body_start..];
    std.log.info("body: {s}", .{body[0..@min(body.len, 200)]});

    // Without a token, Netatmo answers `400 Missing token argument` with
    // {"error":{"code":1,"message":"Access token is missing"}}. Any 4xx with that error object
    // shows the request went through, encrypted, and the API read it.
    const status_ok = std.mem.startsWith(u8, resp, "HTTP/1.1 4");
    if (!status_ok or std.mem.indexOf(u8, body, "\"error\"") == null) return error.UnexpectedAnswer;
    std.log.info("tls test: PASS", .{});
}

/// Reads headers and a Content-Length body (the server keeps the connection until then).
fn read_response(r: *std.Io.Reader) ![]const u8 {
    var len: usize = 0;
    while (true) {
        const n = r.readSliceShort(response[len..]) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) break; // end of stream
        len += n;
        const head_end = std.mem.indexOf(u8, response[0..len], "\r\n\r\n") orelse {
            if (len == response.len) return error.ResponseTooLarge;
            continue;
        };
        const body_len = content_length(response[0..head_end]) orelse continue;
        if (len >= head_end + 4 + body_len) return response[0 .. head_end + 4 + body_len];
        if (len == response.len) return error.ResponseTooLarge;
    }
    return response[0..len];
}

fn content_length(head: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
    }
    return null;
}

fn fetch_time() !i64 {
    const addr = try socket.resolve(ntp_host);
    var request: [sntp.packet_len]u8 = undefined;
    sntp.build_request(&request);
    var reply: [sntp.packet_len]u8 = undefined;
    for (0..3) |_| {
        const n = socket.udp_exchange(addr, sntp.port, &request, &reply, 2000) catch |err| {
            std.log.warn("SNTP: {t}, retrying", .{err});
            continue;
        };
        return sntp.parse_reply(reply[0..n]) catch |err| {
            std.log.warn("SNTP reply: {t}, retrying", .{err});
            continue;
        };
    }
    return error.NoTime;
}

fn now_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}
