//! Reading an HTTP/1.1 response: status line, headers, and a body framed by Content-Length,
//! chunked transfer encoding, or the end of the connection. Pure, tested on the host.
const std = @import("std");

pub const Head = struct {
    status: u16,
    /// Where the body starts in the buffer.
    body_start: usize,
    content_length: ?usize,
    chunked: bool,
};

pub const Error = error{BadResponse};

/// Parses the head if `buf` holds all of it, else returns null (read more).
pub fn parse_head(buf: []const u8) Error!?Head {
    const end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, buf[0..end], "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    // "HTTP/1.1 200 OK"
    if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse;
    var head: Head = .{ .status = status, .body_start = end + 4, .content_length = null, .chunked = false };
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            head.content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            head.chunked = std.ascii.findIgnoreCase(value, "chunked") != null;
        }
    }
    return head;
}

/// With the response read so far in `buf`, the body (chunked bodies decoded in place), or
/// null while more bytes are needed. `at_eof`: the server closed the connection.
pub fn body(buf: []u8, head: Head, at_eof: bool) Error!?[]u8 {
    const raw = buf[head.body_start..];
    if (head.chunked) return dechunk(raw, at_eof);
    if (head.content_length) |n| {
        if (raw.len < n) return if (at_eof) error.BadResponse else null;
        return raw[0..n];
    }
    // Neither: the body runs to the end of the connection.
    return if (at_eof) raw else null;
}

/// Decodes chunked transfer encoding in place: `<hex size>[;ext]\r\n<data>\r\n` ... `0\r\n\r\n`.
/// Returns null while incomplete. Decoding writes behind the read position, so it can run
/// again on the same buffer once more bytes arrive only if nothing was decoded: callers call
/// it once per read, on the undecoded bytes, and a null result leaves `raw` untouched.
fn dechunk(raw: []u8, at_eof: bool) Error!?[]u8 {
    // First pass: check the whole body is there, without modifying it.
    var in: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, raw, in, "\r\n") orelse return incomplete(at_eof);
        const size = try chunk_size(raw[in..line_end]);
        in = line_end + 2;
        if (size == 0) break; // trailers, if any, are not needed
        if (raw.len < in + size + 2) return incomplete(at_eof);
        if (!std.mem.eql(u8, raw[in + size ..][0..2], "\r\n")) return error.BadResponse;
        in += size + 2;
    }
    // Second pass: compact the chunks' data to the front.
    in = 0;
    var out: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, raw, in, "\r\n").?;
        const size = chunk_size(raw[in..line_end]) catch unreachable;
        in = line_end + 2;
        if (size == 0) return raw[0..out];
        std.mem.copyForwards(u8, raw[out..][0..size], raw[in..][0..size]);
        out += size;
        in += size + 2;
    }
}

fn chunk_size(line: []const u8) Error!usize {
    const hex = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len], " \t");
    if (hex.len == 0) return error.BadResponse;
    return std.fmt.parseInt(usize, hex, 16) catch error.BadResponse;
}

fn incomplete(at_eof: bool) Error!?[]u8 {
    return if (at_eof) error.BadResponse else null;
}

const testing = std.testing;

test "content-length" {
    var buf = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".*;
    const head = (try parse_head(&buf)).?;
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("{\"ok\":true}", (try body(&buf, head, false)).?);
    // One byte short: wait for more, or fail at the end of the connection.
    try testing.expectEqual(null, try body(buf[0 .. buf.len - 1], head, false));
    try testing.expectError(error.BadResponse, body(buf[0 .. buf.len - 1], head, true));
}

test "chunked" {
    var buf = "HTTP/1.1 200 OK\r\ntransfer-encoding: Chunked\r\n\r\n4\r\n{\"a\"\r\nb;ext=1\r\n:[1,2,3,4]}\r\n0\r\n\r\n".*;
    const head = (try parse_head(&buf)).?;
    try testing.expect(head.chunked);
    try testing.expectEqualStrings("{\"a\":[1,2,3,4]}", (try body(&buf, head, false)).?);
}

test "chunked, incomplete" {
    var buf = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\nb\r\n:[1,".*;
    const head = (try parse_head(&buf)).?;
    try testing.expectEqual(null, try body(&buf, head, false));
    try testing.expectError(error.BadResponse, body(&buf, head, true));
}

test "to the end of the connection" {
    var buf = "HTTP/1.0 400 Bad\r\n\r\n{\"error\":1}".*;
    const head = (try parse_head(&buf)).?;
    try testing.expectEqual(@as(u16, 400), head.status);
    try testing.expectEqual(null, try body(&buf, head, false));
    try testing.expectEqualStrings("{\"error\":1}", (try body(&buf, head, true)).?);
}

test "bad heads" {
    try testing.expectEqual(null, try parse_head("HTTP/1.1 200 OK\r\nContent-Le"));
    try testing.expectError(error.BadResponse, parse_head("SSH-2.0-OpenSSH\r\n\r\n"));
    try testing.expectError(error.BadResponse, parse_head("HTTP/1.1 2x0 OK\r\n\r\n"));
    var buf = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".*;
    const head = (try parse_head(&buf)).?;
    try testing.expectError(error.BadResponse, body(&buf, head, false));
}
