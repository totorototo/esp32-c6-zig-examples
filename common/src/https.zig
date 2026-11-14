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
pub const sntp = @import("https/sntp.zig");
pub const socket = @import("https/socket.zig");
/// Response framing (Content-Length, chunked) for callers that read raw HTTP themselves.
pub const http = @import("https/http.zig");
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
    /// The body, decrypted. Ends at Content-Length or when the server closes.
    body: *std.Io.Reader,

    pub fn close(_: *Stream) void {
        conn_tcp.close();
    }
};

var conn_tcp: socket.Tcp = undefined;
var conn_client: TlsClient = undefined;

/// Sends one HTTPS request and reads the response head. `target` is the path and query;
/// `body` is sent as is (set its Content-Type in `headers`).
///
/// HTTP/1.0, so the server can't answer with chunked encoding: the body arrives as plain
/// bytes that a streaming parser (std.json.Reader) can read straight from `Stream.body`,
/// without buffering a response that may be bigger than the free RAM.
pub fn open(host: [:0]const u8, method: []const u8, target: []const u8, headers: []const Header, body: []const u8) !Stream {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
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
    try conn_tcp.connect(addr, 443, &socket_read, &socket_write, 10_000);
    errdefer conn_tcp.close();

    var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
    microzig.hal.rng.read(&entropy);
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

    // The head, line by line (each fits the TLS read buffer).
    const r = &conn_client.reader;
    const status_line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
    if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;
    var stream: Stream = .{
        .status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse,
        .content_length = null,
        .body = r,
    };
    // A limit on everything: a server that never ends its head can't keep us here.
    for (0..header_lines_max) |_| {
        const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
            stream.content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        } else if (std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) {
            if (std.ascii.findIgnoreCase(value, "chunked") != null) return error.ChunkedResponse;
        }
    } else return error.BadResponse; // more header lines than any real answer has
    return stream;
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
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
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
