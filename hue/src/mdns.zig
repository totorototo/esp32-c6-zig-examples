//! Just enough mDNS to find a Hue bridge: one query for `_hue._tcp.local`, and a reader for
//! the answer. Pure functions over byte slices, tested on the host (`zig build test`).
//!
//! The query is sent to 224.0.0.251:5353 from an ordinary (ephemeral) port. That makes it a
//! "legacy unicast" query (RFC 6762 6.7): responders must answer with a unicast packet to the
//! sender's address and port, so the board needs no multicast group membership. The answer
//! carries a PTR record for the service and, usually, the bridge's A record as additional
//! data; without one, the packet's source address is the bridge.
const std = @import("std");

pub const port = 5353;
pub const group = [4]u8{ 224, 0, 0, 251 };
pub const service = "_hue._tcp.local";

const query_id = 0x4855; // "HU"
const type_a = 1;
const type_ptr = 12;
const type_srv = 33;
const class_in = 1;
/// Top bit of a question's class: "unicast response requested".
const class_qu = 0x8000;

/// Writes the query into `buf` (at least 64 bytes) and returns it.
pub fn build_query(buf: []u8) []u8 {
    var w: Writer = .{ .buf = buf };
    w.u16be(query_id);
    w.u16be(0); // standard query
    w.u16be(1); // one question
    w.u16be(0);
    w.u16be(0);
    w.u16be(0);
    var labels = std.mem.splitScalar(u8, service, '.');
    while (labels.next()) |label| {
        w.byte(@intCast(label.len));
        w.bytes(label);
    }
    w.byte(0);
    w.u16be(type_ptr);
    w.u16be(class_qu | class_in);
    return buf[0..w.len];
}

pub const Answer = struct {
    /// A PTR record for `_hue._tcp.local` was in the packet.
    service: bool = false,
    /// The first A record in the packet.
    addr: ?[4]u8 = null,
};

pub const ParseError = error{ Truncated, BadName, NotAResponse };

/// Reads a response. Records of other services are ignored, not an error.
pub fn parse(msg: []const u8) ParseError!Answer {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    if (msg.len < 12) return error.Truncated;
    const flags = read_u16(msg, 2);
    if (flags & 0x8000 == 0) return error.NotAResponse;
    const questions = read_u16(msg, 4);
    const records = @as(u32, read_u16(msg, 6)) + read_u16(msg, 8) + read_u16(msg, 10);

    var off: usize = 12;
    for (0..questions) |_| {
        off = try skip_name(msg, off);
        off += 4; // type, class
        if (off > msg.len) return error.Truncated;
    }

    var answer: Answer = .{};
    var name_buf: [256]u8 = undefined;
    for (0..records) |_| {
        const name, off = try read_name(msg, off, &name_buf);
        if (off + 10 > msg.len) return error.Truncated;
        const rtype = read_u16(msg, off);
        const rdlen = read_u16(msg, off + 8);
        const rdata = off + 10;
        off = rdata + rdlen;
        if (off > msg.len) return error.Truncated;

        switch (rtype) {
            type_ptr => if (std.ascii.eqlIgnoreCase(name, service)) {
                answer.service = true;
            },
            type_a => if (rdlen == 4 and answer.addr == null) {
                answer.addr = msg[rdata..][0..4].*;
            },
            else => {},
        }
    }
    return answer;
}

/// Decodes the (possibly compressed) name at `off` as dotted text into `buf`. Returns the
/// name and the offset just past it in the record.
fn read_name(msg: []const u8, start: usize, buf: *[256]u8) ParseError!struct { []const u8, usize } {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var off = start;
    var end: ?usize = null; // where the record continues, once a pointer was followed
    var len: usize = 0;
    var jumps: u8 = 0;
    while (true) {
        if (off >= msg.len) return error.Truncated;
        const n = msg[off];
        if (n == 0) {
            off += 1;
            break;
        }
        if (n & 0xC0 == 0xC0) {
            if (off + 1 >= msg.len) return error.Truncated;
            if (end == null) end = off + 2;
            jumps += 1;
            if (jumps > 16) return error.BadName; // a pointer loop
            off = @as(usize, n & 0x3F) << 8 | msg[off + 1];
            continue;
        }
        if (n & 0xC0 != 0) return error.BadName;
        if (off + 1 + n > msg.len) return error.Truncated;
        if (len + n + 1 > buf.len) return error.BadName;
        if (len > 0) {
            buf[len] = '.';
            len += 1;
        }
        @memcpy(buf[len..][0..n], msg[off + 1 ..][0..n]);
        len += n;
        off += 1 + n;
    }
    return .{ buf[0..len], end orelse off };
}

fn skip_name(msg: []const u8, off: usize) ParseError!usize {
    var buf: [256]u8 = undefined;
    _, const next = try read_name(msg, off, &buf);
    return next;
}

fn read_u16(msg: []const u8, off: usize) u16 {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    return std.mem.readInt(u16, msg[off..][0..2], .big);
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(w: *Writer, b: u8) void {
        w.buf[w.len] = b;
        w.len += 1;
    }
    fn bytes(w: *Writer, s: []const u8) void {
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
    }
    fn u16be(w: *Writer, v: u16) void {
        std.mem.writeInt(u16, w.buf[w.len..][0..2], v, .big);
        w.len += 2;
    }
};

// ---- tests ----

const testing = std.testing;

test "query" {
    var buf: [64]u8 = undefined;
    const q = build_query(&buf);
    try testing.expectEqualSlices(u8, &.{
        0x48, 0x55, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        4,    '_',  'h', 'u', 'e',
        4,    '_',  't', 'c', 'p',
        5,    'l',  'o', 'c', 'a', 'l',
        0,
        0,    12, // PTR
        0x80, 1, // QU, IN
    }, q);
}

/// A legacy-unicast answer as a bridge sends it: the question echoed, a PTR to the instance,
/// then SRV and A as additional records, names compressed against earlier ones.
fn sample_answer(buf: []u8, with_a: bool) []u8 {
    var w: Writer = .{ .buf = buf };
    w.u16be(query_id);
    w.u16be(0x8400); // response, authoritative
    w.u16be(1);
    w.u16be(1);
    w.u16be(0);
    w.u16be(if (with_a) 2 else 1);
    // question: _hue._tcp.local PTR, at offset 12
    w.bytes("\x04_hue\x04_tcp\x05local\x00");
    w.u16be(type_ptr);
    w.u16be(class_in);
    // answer: _hue._tcp.local (pointer to 12) PTR "Hue Bridge - 1A2B3C" + pointer
    w.bytes(&.{ 0xC0, 12 });
    w.u16be(type_ptr);
    w.u16be(class_in);
    w.bytes(&.{ 0, 0, 0x11, 0x94 }); // ttl
    const instance = "\x13Hue Bridge - 1A2B3C";
    w.u16be(instance.len + 2);
    const instance_off = w.len;
    w.bytes(instance);
    w.bytes(&.{ 0xC0, 12 });
    // SRV for the instance: target "ecb5fa1a2b3c.local"
    w.bytes(&.{ 0xC0, @intCast(instance_off) });
    w.u16be(type_srv);
    w.u16be(0x8001);
    w.bytes(&.{ 0, 0, 0, 120 });
    const target = "\x0cecb5fa1a2b3c";
    w.u16be(6 + target.len + 2);
    w.bytes(&.{ 0, 0, 0, 0, 0, 80 }); // priority, weight, port 80
    const target_off = w.len;
    w.bytes(target);
    w.bytes(&.{ 0xC0, 12 + 10 }); // "local", inside the question name
    if (with_a) {
        w.bytes(&.{ 0xC0, @intCast(target_off) });
        w.u16be(type_a);
        w.u16be(0x8001);
        w.bytes(&.{ 0, 0, 0, 120 });
        w.u16be(4);
        w.bytes(&.{ 192, 168, 1, 125 });
    }
    return buf[0..w.len];
}

test "answer with an A record" {
    var buf: [256]u8 = undefined;
    const a = try parse(sample_answer(&buf, true));
    try testing.expect(a.service);
    try testing.expectEqual([4]u8{ 192, 168, 1, 125 }, a.addr.?);
}

test "answer without an A record" {
    var buf: [256]u8 = undefined;
    const a = try parse(sample_answer(&buf, false));
    try testing.expect(a.service);
    try testing.expectEqual(null, a.addr);
}

test "compressed names decode" {
    var buf: [256]u8 = undefined;
    const msg = sample_answer(&buf, true);
    var name_buf: [256]u8 = undefined;
    // The SRV target ends with a pointer into the question's name.
    const srv_target_off = std.mem.indexOf(u8, msg, "\x0cecb5fa").?;
    const name, _ = try read_name(msg, srv_target_off, &name_buf);
    try testing.expectEqualStrings("ecb5fa1a2b3c.local", name);
}

test "bad packets" {
    var buf: [256]u8 = undefined;
    const msg = sample_answer(&buf, true);
    for (0..msg.len) |n| _ = parse(msg[0..n]) catch continue; // truncations never crash

    var q: [64]u8 = undefined;
    try testing.expectError(error.NotAResponse, parse(build_query(&q)));

    // A name pointer that points at itself.
    var loop = [_]u8{ 0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xC0, 12 };
    try testing.expectError(error.BadName, parse(&loop));
}

test "other services are ignored" {
    var buf: [256]u8 = undefined;
    const msg = sample_answer(&buf, true);
    // Rename the answer's service to `_hap._tcp.local`.
    const at = std.mem.indexOf(u8, msg, "_hue").?;
    msg[at + 2] = 'a';
    msg[at + 3] = 'p';
    const a = try parse(msg);
    try testing.expect(!a.service);
}
