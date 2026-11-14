//! lwIP netconn TCP connection as a `std.Io.Reader` and `std.Io.Writer`, which is what
//! `std.crypto.tls.Client` reads records from and writes records to. Plus DNS and one UDP
//! exchange (for SNTP).
const std = @import("std");
const net = @import("net");
const lwip = net.lwip;

const log = std.log.scoped(.socket);

pub fn resolve(host: [:0]const u8) !lwip.c.ip_addr_t {
    var addr: lwip.c.ip_addr_t = undefined;
    try lwip.c_err(lwip.c.netconn_gethostbyname(host.ptr, &addr));
    return addr;
}

/// Sends `request` to `addr:port` over UDP and copies the first reply into `reply`.
pub fn udp_exchange(addr: lwip.c.ip_addr_t, port: u16, request: []const u8, reply: []u8, timeout_ms: u32) !usize {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
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

pub const Tcp = struct {
    conn: *lwip.c.netconn,
    /// The netbuf being read, and how much of it was consumed.
    pending: ?*lwip.c.netbuf = null,
    pending_off: u16 = 0,
    closed: bool = false,

    reader: std.Io.Reader,
    writer: std.Io.Writer,

    /// `read_buffer` must hold one TLS record (`std.crypto.tls.Client.min_buffer_len`).
    pub fn connect(t: *Tcp, addr: lwip.c.ip_addr_t, port: u16, read_buffer: []u8, write_buffer: []u8, timeout_ms: u32) !void {
        const conn = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse
            return error.OutOfMemory;
        errdefer _ = lwip.c.netconn_delete(conn);
        conn[0].recv_timeout = @intCast(timeout_ms);
        try lwip.c_err(lwip.c.netconn_connect(conn, &addr, port));
        t.* = .{
            .conn = conn,
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
        @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
        const t: *Tcp = @alignCast(@fieldParentPtr("reader", r));
        if (t.pending == null) {
            if (t.closed) return error.EndOfStream;
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

    fn send(t: *Tcp, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        lwip.c_err(lwip.c.netconn_write_partly(t.conn, bytes.ptr, bytes.len, lwip.c.NETCONN_COPY, null)) catch |err| {
            log.warn("send failed: {t}", .{err});
            return error.WriteFailed;
        };
    }
};
