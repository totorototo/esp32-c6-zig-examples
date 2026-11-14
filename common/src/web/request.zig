//! An HTTP request head, parsed: request line, headers, query parameters. Pure, tested on
//! the host (`zig build test`); `web.zig` does the reading from lwIP.
const std = @import("std");

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    /// The header lines, after the request line.
    headers: []const u8,

    pub fn is(req: Request, method: []const u8, path: []const u8) bool {
        return std.mem.eql(u8, req.method, method) and std.mem.eql(u8, req.path, path);
    }

    /// The value of header `name` (case-insensitive), or null.
    pub fn header(req: Request, name: []const u8) ?[]const u8 {
        @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
        var lines = std.mem.splitSequence(u8, req.headers, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

pub const ParseError = error{BadRequest};

/// Parses `head`: the request line and the headers, without the blank line that ends them.
/// The result's slices point into `head`.
pub fn parse(head: []const u8) ParseError!Request {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    var it = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
    const method = it.next() orelse return error.BadRequest;
    const target = it.next() orelse return error.BadRequest;
    const q = std.mem.indexOfScalar(u8, target, '?');
    return .{
        .method = method,
        .path = target[0 .. q orelse target.len],
        .query = if (q) |i| target[i + 1 ..] else "",
        .headers = if (line_end < head.len) head[line_end + 2 ..] else "",
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

const testing = std.testing;

test "request line, query, headers" {
    const req = try parse("POST /set?on=1&bri=200 HTTP/1.1\r\nHost: 192.168.1.20\r\nx-hue-remote:  1 \r\nAccept: */*");
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("/set", req.path);
    try testing.expectEqualStrings("on=1&bri=200", req.query);
    try testing.expect(req.is("POST", "/set"));
    try testing.expect(!req.is("GET", "/set"));
    // Case-insensitive name, value trimmed.
    try testing.expectEqualStrings("1", req.header("X-Hue-Remote").?);
    try testing.expectEqualStrings("192.168.1.20", req.header("host").?);
    try testing.expectEqual(null, req.header("Origin"));
}

test "no query, no headers" {
    const req = try parse("GET / HTTP/1.1");
    try testing.expectEqualStrings("/", req.path);
    try testing.expectEqualStrings("", req.query);
    try testing.expectEqualStrings("", req.headers);
    try testing.expectEqual(null, req.header("Host"));
    // An empty query after `?`.
    try testing.expectEqualStrings("", (try parse("GET /state? HTTP/1.1")).query);
}

test "bad request lines" {
    try testing.expectError(error.BadRequest, parse(""));
    try testing.expectError(error.BadRequest, parse("GET"));
    try testing.expectError(error.BadRequest, parse("\r\nHost: x"));
}

test "header lookup ignores lines without a colon and partial names" {
    const req = try parse("GET / HTTP/1.1\r\nnonsense\r\nX-Hue-Remote-Extra: 2\r\nX-Hue: 3");
    try testing.expectEqual(null, req.header("X-Hue-Remote"));
    try testing.expectEqualStrings("3", req.header("X-Hue").?);
}

test "params" {
    var it = params("on=1&&r=255&flag");
    const k1, const v1 = split_param(it.next().?).?;
    try testing.expectEqualStrings("on", k1);
    try testing.expectEqualStrings("1", v1);
    const k2, const v2 = split_param(it.next().?).?;
    try testing.expectEqualStrings("r", k2);
    try testing.expectEqualStrings("255", v2);
    // A pair without `=` is the caller's error to report.
    try testing.expectEqual(null, split_param(it.next().?));
    try testing.expectEqual(null, it.next());
    // An empty value is still a pair.
    _, const empty = split_param("bri=").?;
    try testing.expectEqualStrings("", empty);
}
