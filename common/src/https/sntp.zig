//! Minimal SNTP (RFC 4330): one 48-byte request, one reply, the server's transmit time.
//! TLS needs the wall-clock time to check certificate dates, and the board has no clock.
//! Pure, tested on the host (`zig build test`).
const std = @import("std");

pub const port = 123;
pub const packet_len = 48;

/// Seconds from the NTP epoch (1900) to the Unix epoch (1970).
const ntp_to_unix = 2_208_988_800;

/// A client request: version 4, mode 3 (client), everything else zero.
pub fn build_request(buf: *[packet_len]u8) void {
    buf.* = @splat(0);
    buf[0] = (0 << 6) | (4 << 3) | 3; // LI 0, VN 4, mode 3
}

pub const ParseError = error{ Truncated, NotAServerReply, Unsynchronized };

/// The server's transmit time, as Unix seconds.
pub fn parse_reply(msg: []const u8) ParseError!i64 {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    if (msg.len < packet_len) return error.Truncated;
    const mode = msg[0] & 0x7;
    if (mode != 4) return error.NotAServerReply;
    // Leap indicator 3 (alarm) or stratum 0 (kiss-o'-death): the server has no time to give.
    if (msg[0] >> 6 == 3 or msg[1] == 0) return error.Unsynchronized;
    const secs = std.mem.readInt(u32, msg[40..44], .big);
    // NTP's 32-bit seconds wrap in 2036; everything after 1970 + a margin is "era 1".
    const era: i64 = if (secs < 0x8000_0000) 1 else 0;
    return era * (1 << 32) + secs - ntp_to_unix;
}

const testing = std.testing;

test "request" {
    var buf: [packet_len]u8 = undefined;
    build_request(&buf);
    try testing.expectEqual(@as(u8, 0x23), buf[0]);
    for (buf[1..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

fn reply(secs: u32, first: u8, stratum: u8) [packet_len]u8 {
    var r: [packet_len]u8 = @splat(0);
    r[0] = first;
    r[1] = stratum;
    std.mem.writeInt(u32, r[40..44], secs, .big);
    return r;
}

test "reply" {
    // 2026-11-10T00:00:00Z = Unix 1_794_268_800 = NTP 4_003_257_600.
    const r = reply(4_003_257_600, 0x24, 2); // LI 0, VN 4, mode 4
    try testing.expectEqual(@as(i64, 1_794_268_800), try parse_reply(&r));
}

test "after the 2036 wrap" {
    // 2040-01-01T00:00:00Z = Unix 2_208_988_800 = NTP 4_417_977_600 - 2^32 = 123_010_304.
    const r = reply(123_010_304, 0x24, 2);
    try testing.expectEqual(@as(i64, 2_208_988_800), try parse_reply(&r));
}

test "bad replies" {
    var req: [packet_len]u8 = undefined;
    build_request(&req);
    try testing.expectError(error.NotAServerReply, parse_reply(&req));
    try testing.expectError(error.Unsynchronized, parse_reply(&reply(4_003_257_600, 0x24, 0)));
    try testing.expectError(error.Unsynchronized, parse_reply(&reply(4_003_257_600, 0xE4, 2)));
    try testing.expectError(error.Truncated, parse_reply(req[0..20]));
}
