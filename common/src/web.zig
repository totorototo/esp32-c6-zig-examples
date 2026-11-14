//! Tiny HTTP/1.1 server helpers: one request per connection, closed after the reply.
const std = @import("std");
const net = @import("net.zig");
const lwip = net.lwip;

const request = @import("web/request.zig");
pub const Request = request.Request;
pub const params = request.params;
pub const split_param = request.split_param;

pub const Timeouts = struct {
    /// For the first bytes. Browsers open speculative connections that send nothing; on a
    /// single-task server each one would stall everything else for `rest_ms`. Closed early,
    /// the browser just opens a new connection when it does have a request.
    first_ms: u32 = 150,
    /// For the rest of the head, once the client has started sending.
    rest_ms: u32 = 3000,
};

/// Reads the request line and headers; any body is ignored.
pub fn read_request(conn: *lwip.c.netconn, buf: []u8, timeouts: Timeouts) !Request {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var len: usize = 0;
    conn.recv_timeout = timeouts.first_ms;
    while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
        if (len == buf.len) return error.RequestTooLarge;

        var nb: ?*lwip.c.netbuf = null;
        try lwip.c_err(lwip.c.netconn_recv(conn, &nb));
        conn.recv_timeout = timeouts.rest_ms;
        defer lwip.c.netbuf_delete(nb);
        while (true) {
            var ptr: ?*anyopaque = null;
            var n: u16 = 0;
            try lwip.c_err(lwip.c.netbuf_data(nb, &ptr, &n));
            const chunk = @as([*]const u8, @ptrCast(ptr))[0..n];
            const take = @min(chunk.len, buf.len - len);
            @memcpy(buf[len..][0..take], chunk[0..take]);
            len += take;
            if (lwip.c.netbuf_next(nb) < 0) break;
        }
    }

    return request.parse(buf[0..std.mem.indexOf(u8, buf[0..len], "\r\n\r\n").?]);
}

pub fn respond(conn: *lwip.c.netconn, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var head: [160]u8 = undefined;
    const header = try std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len });
    try write_all(conn, header);
    try write_all(conn, body);
}

fn write_all(conn: *lwip.c.netconn, bytes: []const u8) !void {
    try lwip.c_err(lwip.c.netconn_write_partly(conn, bytes.ptr, bytes.len, lwip.c.NETCONN_COPY, null));
}
