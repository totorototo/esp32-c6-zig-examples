//! lwIP netconn TCP connection as a `std.Io.Reader` and `std.Io.Writer`, which is what
//! `std.crypto.tls.Client` reads records from and writes records to. Plus DNS and one UDP
//! exchange (for SNTP).
const std = @import("std");
const microzig = @import("microzig");
const net = @import("net");
const lwip = net.lwip;
const verify = @import("verify").verify;

const log = std.log.scoped(.socket);

pub fn resolve(host: [:0]const u8) !lwip.c.ip_addr_t {
    var addr: lwip.c.ip_addr_t = undefined;
    try lwip.c_err(lwip.c.netconn_gethostbyname(host.ptr, &addr));
    return addr;
}

/// Sends `request` to `addr:port` over UDP and copies the first reply into `reply`.
pub fn udp_exchange(addr: lwip.c.ip_addr_t, port: u16, request: []const u8, reply: []u8, timeout_ms: u32) !usize {
    @setRuntimeSafety(true); // network input: this scope stays checked in ReleaseSmall
    const conn = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_UDP, 0, null) orelse
        return error.OutOfMemory;
    defer _ = lwip.c.netconn_delete(conn);
    try lwip.c_err(lwip.c.netconn_bind(conn, null, 0));
    conn[0].recv_timeout = @intCast(timeout_ms);
    {
        const out = lwip.c.netbuf_new() orelse return error.OutOfMemory;
        defer lwip.c.netbuf_delete(out);
        try lwip.c_err(lwip.c.netbuf_ref(out, request.ptr, @intCast(request.len)));
        try lwip.c_err(lwip.c.netconn_sendto(conn, out, &addr, port));
    }
    var in: ?*lwip.c.netbuf = null;
    try lwip.c_err(lwip.c.netconn_recv(conn, &in));
    defer lwip.c.netbuf_delete(in);
    return lwip.c.pbuf_copy_partial(in.?.p, reply.ptr, @intCast(reply.len), 0);
}

pub fn ip_text(addr: lwip.c.ip_addr_t, buf: *[16]u8) []const u8 {
    var o: [4]u8 = undefined;
    std.mem.writeInt(u32, &o, addr.u_addr.ip4.addr, .little);
    return std.fmt.bufPrint(buf, "{}.{}.{}.{}", .{ o[0], o[1], o[2], o[3] }) catch unreachable;
}

fn uptime_us() u64 {
    return microzig.hal.time.get_time_since_boot().to_us();
}

pub const Tcp = struct {
    conn: *lwip.c.netconn,
    /// The netbuf being read, and how much of it was consumed.
    pending: ?*lwip.c.netbuf = null,
    pending_off: u16 = 0,
    closed: bool = false,
    /// Uptime (us) by which the whole exchange must be over. `recv_timeout` and
    /// `send_timeout` bound one read or write each: a peer sending or taking a byte every
    /// few seconds would otherwise hold the connection, and the task, for as long as it
    /// likes.
    deadline_us: u64,
    /// The per-read and per-write timeout `connect` was given; near the deadline, less.
    io_timeout_ms: u32,

    reader: std.Io.Reader,
    writer: std.Io.Writer,

    pub const Timeouts = struct {
        /// For each read and each write.
        io_ms: u32,
        /// For everything from `connect` to the last byte read. Connecting itself is not
        /// bounded by either: netconn has no connect timeout, and TCP gives up only after
        /// its SYN retries (lwIP's TCP_SYNMAXRTX, over a minute). The deadline then fails
        /// the first read or write.
        total_ms: u32,
    };

    /// `read_buffer` must hold one TLS record (`std.crypto.tls.Client.min_buffer_len`).
    pub fn connect(
        t: *Tcp,
        addr: lwip.c.ip_addr_t,
        port: u16,
        read_buffer: []u8,
        write_buffer: []u8,
        timeouts: Timeouts,
    ) !void {
        // 0 would mean "no timeout" to lwIP.
        verify(timeouts.io_ms > 0, "reads and writes time out");
        verify(timeouts.io_ms <= timeouts.total_ms, "a read fits in the whole exchange");
        const start_us = uptime_us();
        const conn = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse
            return error.OutOfMemory;
        errdefer _ = lwip.c.netconn_delete(conn);
        try lwip.c_err(lwip.c.netconn_connect(conn, &addr, port));
        t.* = .{
            .conn = conn,
            .deadline_us = start_us + @as(u64, timeouts.total_ms) * 1000,
            .io_timeout_ms = timeouts.io_ms,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = read_buffer, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = write_buffer },
        };
    }

    pub fn close(t: *Tcp) void {
        if (t.pending) |nb| lwip.c.netbuf_delete(nb);
        t.pending = null;
        _ = lwip.c.netconn_close(t.conn);
        _ = lwip.c.netconn_delete(t.conn);
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        @setRuntimeSafety(true); // network input: this scope stays checked in ReleaseSmall
        const t: *Tcp = @alignCast(@fieldParentPtr("reader", r));
        if (t.pending == null) {
            if (t.closed) return error.EndOfStream;
            t.conn.recv_timeout = t.timeout_ms() orelse return error.ReadFailed;
            var nb: ?*lwip.c.netbuf = null;
            lwip.c_err(lwip.c.netconn_recv(t.conn, &nb)) catch |err| switch (err) {
                error.ConnectionClosed => {
                    t.closed = true;
                    return error.EndOfStream;
                },
                else => {
                    log.warn("recv failed: {t}", .{err});
                    return error.ReadFailed;
                },
            };
            t.pending = nb;
            t.pending_off = 0;
        }
        const nb = t.pending.?;
        const total = nb.p.*.tot_len;
        verify(t.pending_off < total, "a pending netbuf has bytes left");
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = lwip.c.pbuf_copy_partial(nb.p, dest.ptr, @intCast(@min(dest.len, total - t.pending_off)), t.pending_off);
        w.advance(n);
        t.pending_off += n;
        if (t.pending_off >= total) {
            lwip.c.netbuf_delete(nb);
            t.pending = null;
        }
        return n;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const t: *Tcp = @alignCast(@fieldParentPtr("writer", w));
        try t.send(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try t.send(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try t.send(last);
        return n + last.len * splat;
    }

    /// With a `send_timeout` set, lwIP writes what it can before the timeout and says how
    /// much (it refuses the call without `written`), so this loops until all of it is out.
    fn send(t: *Tcp, bytes: []const u8) std.Io.Writer.Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            t.conn.send_timeout = @intCast(t.timeout_ms() orelse return error.WriteFailed);
            var written: usize = 0;
            const rest = bytes[off..];
            lwip.c_err(lwip.c.netconn_write_partly(t.conn, rest.ptr, rest.len, lwip.c.NETCONN_COPY, &written)) catch |err| {
                log.warn("send failed: {t}", .{err});
                return error.WriteFailed;
            };
            if (written == 0) {
                log.warn("send failed: the peer took nothing for {} ms", .{t.conn.send_timeout});
                return error.WriteFailed;
            }
            verify(written <= rest.len, "lwIP wrote at most what it was given");
            off += written;
        }
    }

    /// The timeout for the next read or write: `io_timeout_ms`, or less near the deadline.
    /// Null once the deadline has passed. Never 0, which lwIP takes as "wait forever".
    fn timeout_ms(t: *const Tcp) ?u32 {
        const now = uptime_us();
        if (now >= t.deadline_us) {
            log.warn("the peer is too slow: over the time allowed for the whole exchange", .{});
            return null;
        }
        const left_ms = (t.deadline_us - now) / 1000 + 1;
        return @intCast(@min(left_ms, t.io_timeout_ms));
    }
};
