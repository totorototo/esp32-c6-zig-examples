//! Reading an HTTP/1.x response head, one line at a time: the status line, then the header
//! lines `https.open` needs. Pure, tested on the host; `https.read_head` feeds it the lines.
//!
//! Requests go out as HTTP/1.0, so a server may not answer with chunked encoding: the body
//! is plain bytes, ending at Content-Length or when the server closes.
const std = @import("std");

pub const Error = error{
    BadResponse,
    /// Not allowed in an answer to HTTP/1.0, and not decoded here.
    ChunkedResponse,
};

/// The status code of a status line ("HTTP/1.1 200 OK", without its CRLF).
pub fn status(line: []const u8) Error!u16 {
    @setRuntimeSafety(true); // network input: this scope stays checked in ReleaseSmall
    // "HTTP/1.x" + " " + three digits, then an optional reason.
    if (line.len < 12 or !std.mem.startsWith(u8, line, "HTTP/1.") or line[8] != ' ')
        return error.BadResponse;
    if (line.len > 12 and line[12] != ' ') return error.BadResponse;
    for (line[9..12]) |d| if (!std.ascii.isDigit(d)) return error.BadResponse;
    return std.fmt.parseInt(u16, line[9..12], 10) catch unreachable; // three digits
}

/// What the head says about the body.
pub const Head = struct {
    content_length: ?usize = null,

    /// Takes one header line (without its CRLF). Lines that aren't `name: value` and
    /// headers that don't matter here are skipped.
    pub fn add(head: *Head, line: []const u8) Error!void {
        @setRuntimeSafety(true); // network input: this scope stays checked in ReleaseSmall
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const n = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
            // Two that disagree: which one frames the body is anyone's guess.
            if (head.content_length) |old| if (old != n) return error.BadResponse;
            head.content_length = n;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.findIgnoreCase(value, "chunked") != null) return error.ChunkedResponse;
        }
    }
};

const testing = std.testing;

test status {
    try testing.expectEqual(@as(u16, 200), try status("HTTP/1.1 200 OK"));
    try testing.expectEqual(@as(u16, 400), try status("HTTP/1.0 400"));
    try testing.expectError(error.BadResponse, status("SSH-2.0-OpenSSH"));
    try testing.expectError(error.BadResponse, status("HTTP/1.1 2x0 OK"));
    // parseInt alone would take a sign.
    try testing.expectError(error.BadResponse, status("HTTP/1.1 +20 OK"));
    try testing.expectError(error.BadResponse, status("HTTP/1.1 2000 OK"));
    try testing.expectError(error.BadResponse, status("HTTP/1.1  200"));
    try testing.expectError(error.BadResponse, status("HTTP/1.1 20"));
}

test "Head.add" {
    var head: Head = .{};
    try head.add("Content-Type: application/json");
    try head.add("not a header");
    try testing.expectEqual(null, head.content_length);
    try head.add("content-length:  11 ");
    try testing.expectEqual(@as(?usize, 11), head.content_length);
    try head.add("Content-Length: 11"); // repeated, same value
    try testing.expectError(error.BadResponse, head.add("Content-Length: 12"));
    try testing.expectError(error.BadResponse, head.add("Content-Length: -1"));
    try testing.expectError(error.BadResponse, head.add("Content-Length: 99999999999999999999999"));
    try testing.expectError(error.ChunkedResponse, head.add("Transfer-Encoding: gzip, Chunked"));
}

test "corrupted heads never panic" {
    const mutations = @import("mutations");
    try mutations.each("HTTP/1.1 200 OK", struct {
        fn check(line: []u8) void {
            _ = status(line) catch return;
        }
    }.check);
    for ([_][]const u8{ "Content-Length: 11", "Transfer-Encoding: chunked" }) |fixture| {
        try mutations.each(fixture, struct {
            fn check(line: []u8) void {
                var head: Head = .{};
                head.add(line) catch return;
            }
        }.check);
    }
}
