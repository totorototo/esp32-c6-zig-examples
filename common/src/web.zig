//! Tiny HTTP/1.1 server helpers: one request per connection, closed after the reply.
const std = @import("std");
const net = @import("net.zig");
const lwip = net.lwip;

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,

    pub fn is(req: Request, method: []const u8, path: []const u8) bool {
        return std.mem.eql(u8, req.method, method) and std.mem.eql(u8, req.path, path);
    }
};

/// Reads the request line and headers; any body is ignored.
pub fn read_request(conn: *lwip.c.netconn, buf: []u8) !Request {
    var len: usize = 0;
    while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
        if (len == buf.len) return error.RequestTooLarge;

        var nb: ?*lwip.c.netbuf = null;
        try lwip.c_err(lwip.c.netconn_recv(conn, &nb));
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

    const head = buf[0..len];
    const line_end = std.mem.indexOf(u8, head, "\r\n").?;
    var it = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
    const method = it.next() orelse return error.BadRequest;
    const target = it.next() orelse return error.BadRequest;
    const q = std.mem.indexOfScalar(u8, target, '?');
    return .{
        .method = method,
        .path = target[0 .. q orelse target.len],
        .query = if (q) |i| target[i + 1 ..] else "",
    };
}

/// Iterates `key=value` pairs of a query string (no percent-decoding: values are numbers).
pub fn params(query: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, query, '&');
}

pub fn split_param(pair: []const u8) ?struct { []const u8, []const u8 } {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
    return .{ pair[0..eq], pair[eq + 1 ..] };
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
