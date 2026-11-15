//! HTTPS client for the Wi-Fi examples: TLS 1.3 with Zig's TLS client (patched for small
//! stacks, see https/tls_client.zig), one HTTP/1.0 request per connection: `request` for
//! small responses, `open` to stream a big one.
//!
//! Requirements on the firmware:
//!   - A main stack of at least 112 KiB: `microzig.Allocator.init_with_heap(112 * 1024)`.
//!     (The argument is what the heap leaves for the stack, not the heap's size.)
//!     The handshake goes about 86 KiB deep: `tls_client.init` (31 KiB) and, during the key
//!     exchange, `KeyShare.exchangeHybrid` (44 KiB) plus ML-KEM's own frames.
//!   - `std_options.page_size_min/max` set (any value): the certificate bundle's lock wants an
//!     `std.Io`, and `std.Io.failing` references file memory maps.
//!   - `sync_time()` once Wi-Fi is up: certificate dates need the wall-clock time.
//!
//! Trust: one pinned root, DigiCert Global Root G2 (valid to 2038), which is what
//! api.netatmo.com chains to. Hosts that chain elsewhere fail with
//! `error.CertificateIssuerNotFound`; add their root to `roots` below.
const std = @import("std");
const microzig = @import("microzig");
const net = @import("net");
const lwip = net.lwip;
const verify = @import("verify").verify;
pub const sntp = @import("https/sntp.zig");
pub const socket = @import("https/socket.zig");
/// The response head's parser (pure, host-tested), fed line by line by `read_head`.
const http = @import("https/http.zig");
pub const TlsClient = @import("https/tls_client.zig");
const tls = std.crypto.tls;

const log = std.log.scoped(.https);

const roots = [_][]const u8{
    // DigiCert Global Root G2, SHA-256 CB3CCBB7...5AB1CB5F, from the macOS system roots.
    @embedFile("https/digicert_global_root_g2.der"),
};

// ---- time ----

/// Unix time minus uptime, set by `sync_time`.
var boot_unix: ?i64 = null;

pub fn sync_time() !void {
    const ntp_host = "pool.ntp.org";
    const addr = try socket.resolve(ntp_host);
    var request_buf: [sntp.packet_len]u8 = undefined;
    sntp.build_request(&request_buf);
    var reply: [sntp.packet_len]u8 = undefined;
    for (0..3) |_| {
        const n = socket.udp_exchange(addr, sntp.port, &request_buf, &reply, 2000) catch |err| {
            log.warn("SNTP: {t}, retrying", .{err});
            continue;
        };
        const unix = sntp.parse_reply(reply[0..n]) catch |err| {
            log.warn("SNTP reply: {t}, retrying", .{err});
            continue;
        };
        boot_unix = unix - uptime_s();
        log.info("time: {} (Unix seconds) from {s}", .{ unix, ntp_host });
        return;
    }
    return error.NoTime;
}

/// Unix seconds, once `sync_time` has run.
pub fn now() ?i64 {
    return (boot_unix orelse return null) + uptime_s();
}

fn uptime_s() i64 {
    return @intCast(microzig.hal.time.get_time_since_boot().to_us() / 1_000_000);
}

// ---- requests ----

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Response = struct {
    status: u16,
    /// Inside the caller's buffer.
    body: []const u8,
};

// One connection at a time: both socket buffers hold a whole TLS record (the client asks its
// output for that much contiguous space; with less, the first encrypted write spins forever,
// since ReleaseSmall drops the assert), and so does the decrypted read buffer.
var socket_read: [TlsClient.min_buffer_len]u8 = undefined;
var socket_write: [TlsClient.min_buffer_len]u8 = undefined;
var tls_read: [TlsClient.min_buffer_len]u8 = undefined;
var tls_write: [2048]u8 = undefined;
var bundle_mem: [4096]u8 = undefined;
comptime {
    // The TLS client asks its output for a whole record of contiguous space, and asserts
    // it only in Debug: a smaller buffer made the first encrypted write spin forever.
    std.debug.assert(socket_write.len >= TlsClient.min_buffer_len);
    std.debug.assert(socket_read.len >= TlsClient.min_buffer_len);
    std.debug.assert(tls_read.len >= TlsClient.min_buffer_len);
    // The bundle copies every root and keeps an index next to them: twice their size
    // leaves room for the index.
    var roots_len = 0;
    for (roots) |der| roots_len += der.len;
    std.debug.assert(bundle_mem.len >= 2 * roots_len);
}

/// The open response of `open`: status, a few headers, and the decrypted body as a reader.
/// One at a time (the connection's buffers are statics); `close` it.
pub const Stream = struct {
    status: u16,
    content_length: ?usize,
    /// The body, decrypted. Not cut at `content_length`: reading past it waits for the
    /// server to close (`request` stops there; a JSON reader stops at the closing brace).
    body: *std.Io.Reader,

    pub fn close(_: *Stream) void {
        // Closing twice would delete the netconn twice.
        verify(stream_open, "an HTTPS stream is closed once");
        conn_tcp.close();
        stream_open = false;
    }
};

var conn_tcp: socket.Tcp = undefined;
/// Between a successful `open` and its `close`. The connection's buffers, the TLS client and
/// its key share are statics: a second `open` meanwhile (a token refresh while a stream is
/// read, say) would silently overwrite the first connection's state.
var stream_open = false;
var conn_client: TlsClient = undefined;

/// Sends one HTTPS request and reads the response head. `target` is the path and query;
/// `body` is sent as is (set its Content-Type in `headers`).
///
/// HTTP/1.0, so the server can't answer with chunked encoding: the body arrives as plain
/// bytes that a streaming parser (std.json.Reader) can read straight from `Stream.body`,
/// without buffering a response that may be bigger than the free RAM.
pub fn open(host: [:0]const u8, method: []const u8, target: []const u8, headers: []const Header, body: []const u8) !Stream {
    @setRuntimeSafety(true); // network input: this scope stays checked in ReleaseSmall
    // First: everything below, the certificate bundle included, lives in statics.
    verify(!stream_open, "one HTTPS connection at a time");
    const unix = now() orelse return error.NoTime;

    var fba: std.heap.FixedBufferAllocator = .init(&bundle_mem);
    const gpa = fba.allocator();
    var bundle: std.crypto.Certificate.Bundle = .empty;
    for (roots) |der| {
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(gpa, der);
        try bundle.parseCert(gpa, start, unix);
    }

    const addr = try socket.resolve(host);
    try conn_tcp.connect(addr, 443, &socket_read, &socket_write, .{
        .io_ms = 10_000,
        // A handshake takes about a second on the chip, ~9 s in Wokwi, and the biggest
        // answer (Netatmo's homesdata, tens of KiB) a few more: a minute is generous.
        .total_ms = 60_000,
    });
    errdefer conn_tcp.close();
    stream_open = true;
    errdefer stream_open = false;

    var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
    microzig.hal.rng.read(&entropy);
    // The key share's seed: wiped like the key share itself (see tls_client.zig).
    defer std.crypto.secureZero(u8, &entropy);
    var lock: std.Io.RwLock = .init;
    var alert: tls.Alert = undefined;
    const t0 = microzig.hal.time.get_time_since_boot().to_us();
    conn_client = TlsClient.init(&conn_tcp.reader, &conn_tcp.writer, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{ .gpa = gpa, .io = std.Io.failing, .lock = &lock, .bundle = &bundle } },
        .read_buffer = &tls_read,
        .write_buffer = &tls_write,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = @as(i96, unix) * std.time.ns_per_s },
        .alert = &alert,
        // HTTP/1.0 ends a body without Content-Length by closing; servers often skip
        // close_notify then. Bodies with a Content-Length are checked against it.
        .allow_truncation_attacks = true,
    }) catch |err| {
        if (err == error.TlsAlert) log.err("{s}: TLS alert {t}", .{ host, alert.description });
        return err;
    };
    log.debug("{s}: {t} handshake in {} ms", .{ host, conn_client.tls_version, (microzig.hal.time.get_time_since_boot().to_us() - t0) / 1000 });

    const w = &conn_client.writer;
    try w.print("{s} {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: microzig-esp32c6\r\n", .{ method, target, host });
    for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    if (body.len > 0 or !std.mem.eql(u8, method, "GET")) try w.print("Content-Length: {}\r\n", .{body.len});
    try w.writeAll("\r\n");
    try w.writeAll(body);
    try w.flush();
    try conn_tcp.writer.flush();

    return read_head(&conn_client.reader);
}

/// The status line and the headers `open` needs, leaving `r` at the body. Line by line:
/// each fits the TLS read buffer. The parsing is `http.zig`'s, tested on the host.
fn read_head(r: *std.Io.Reader) !Stream {
    const status = try http.status(try take_line(r));
    var head: http.Head = .{};
    // A limit on everything: a server that never ends its head can't keep us here.
    for (0..header_lines_max) |_| {
        const line = try take_line(r);
        if (line.len == 0) break;
        try head.add(line);
    } else return error.BadResponse; // more header lines than any real answer has
    return .{ .status = status, .content_length = head.content_length, .body = r };
}

fn take_line(r: *std.Io.Reader) ![]const u8 {
    return std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
}

/// Netatmo sends about 15.
const header_lines_max = 64;

/// One HTTPS request, the whole body read into `buf` (for small responses; stream bigger
/// ones with `open`).
pub fn request(
    host: [:0]const u8,
    method: []const u8,
    target: []const u8,
    headers: []const Header,
    body: []const u8,
    buf: []u8,
) !Response {
    @setRuntimeSafety(true); // network input: this scope stays checked in ReleaseSmall
    var stream = try open(host, method, target, headers, body);
    defer stream.close();
    const want = stream.content_length orelse buf.len;
    if (want > buf.len) return error.ResponseTooLarge;
    var len: usize = 0;
    while (len < want) {
        const n = stream.body.readSliceShort(buf[len..want]) catch |err| switch (err) {
            error.ReadFailed => return conn_client.read_err orelse error.ReadFailed,
        };
        if (n == 0) break;
        len += n;
    }
    if (stream.content_length != null and len < want) return error.BadResponse;
    if (stream.content_length == null and len == buf.len) return error.ResponseTooLarge;
    return .{ .status = stream.status, .body = buf[0..len] };
}
