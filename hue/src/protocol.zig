//! The Hue bridge API v1's message formats, without the network: bodies in, values out (and
//! back). Pure, tested on the host (`zig build test`); hue.zig sends and receives them.
//!
//! Nothing here logs: failures come back as errors, with the bridge's explanation in a
//! `Failure` when it gave one. hue.zig, which has the context, does the logging.
const std = @import("std");

/// A state change; null fields are left alone.
pub const Change = struct {
    on: ?bool = null,
    bri: ?u8 = null,
    hue: ?u16 = null,
    sat: ?u8 = null,
};

pub const Error = error{ BridgeError, BadResponse };

/// What the bridge said when it refused (`error.BridgeError`).
pub const Failure = struct { type: u32 = 0, description: []const u8 = "" };

/// One entry of the array the bridge returns for writes and for errors.
const Result = struct {
    success: ?std.json.Value = null,
    @"error": ?struct { type: u32, description: []const u8 } = null,
};

/// `body` as a `T`, unknown fields ignored. Slices point into `arena`.
pub fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true }) catch
        error.BadResponse;
}

/// Reads go back as an object, but failures (e.g. an unknown username) come back as an
/// array of `{"error": ...}`, still with HTTP 200.
pub fn check_error(arena: std.mem.Allocator, body: []const u8, failure: ?*Failure) Error!void {
    const trimmed = std.mem.trimStart(u8, body, " \r\n\t");
    if (trimmed.len == 0 or trimmed[0] != '[') return;
    const results = try parse([]Result, arena, trimmed);
    for (results) |r| if (r.@"error") |e| {
        if (failure) |f| f.* = .{ .type = e.type, .description = e.description };
        return error.BridgeError;
    };
}

/// The answer to `POST /api {"devicetype": ...}`: the new username, or null while the link
/// button has not been pressed (error 101).
pub fn pairing_user(
    arena: std.mem.Allocator,
    body: []const u8,
    failure: ?*Failure,
) Error!?[]const u8 {
    const results = try parse([]Result, arena, body);
    if (results.len == 0) return error.BadResponse;
    if (results[0].@"error") |e| {
        if (e.type == 101) return null; // link button not pressed
        if (failure) |f| f.* = .{ .type = e.type, .description = e.description };
        return error.BridgeError;
    }
    const success = results[0].success orelse return error.BadResponse;
    if (success != .object) return error.BadResponse;
    const user = success.object.get("username") orelse return error.BadResponse;
    if (user != .string) return error.BadResponse;
    return user.string;
}

/// The body of `PUT .../state` or `.../action` for `change`, in `buf`. The bridge rejects
/// bri 0 and bri/sat 255, so those are clamped; null fields are left out.
pub fn state_body(buf: []u8, change: Change) error{NoSpaceLeft}![]const u8 {
    var c = change;
    if (c.bri) |v| c.bri = std.math.clamp(v, 1, 254);
    if (c.sat) |v| c.sat = @min(v, 254);
    const json = std.json.fmt(c, .{ .emit_null_optional_fields = false });
    return std.fmt.bufPrint(buf, "{f}", .{json});
}

/// The web remote's `/set` query: `on=0|1`, `bri`, `hue`, `sat`, any subset.
pub fn parse_change(query: []const u8) error{BadParameter}!Change {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var change: Change = .{};
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadParameter;
        const key = kv[0..eq];
        const value = kv[eq + 1 ..];
        if (std.mem.eql(u8, key, "on")) {
            change.on = (parse_int(u1, value) orelse return error.BadParameter) == 1;
        } else if (std.mem.eql(u8, key, "bri")) {
            change.bri = parse_int(u8, value) orelse return error.BadParameter;
        } else if (std.mem.eql(u8, key, "hue")) {
            change.hue = parse_int(u16, value) orelse return error.BadParameter;
        } else if (std.mem.eql(u8, key, "sat")) {
            change.sat = parse_int(u8, value) orelse return error.BadParameter;
        } else return error.BadParameter;
    }
    return change;
}

fn parse_int(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// Dotted IPv4 text, as given with -Dhue_ip or saved in flash.
pub fn parse_ipv4(s: []const u8) error{BadAddress}![4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&octets) |*o| {
        const part = it.next() orelse return error.BadAddress;
        o.* = std.fmt.parseInt(u8, part, 10) catch return error.BadAddress;
    }
    if (it.next() != null) return error.BadAddress;
    return octets;
}

// ---- tests ----

const testing = std.testing;

test "check_error: objects pass, error arrays fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try check_error(a, "{\"1\":{\"name\":\"Salon\"}}", null);
    try check_error(a, "", null);
    // Writes answer with an array of successes.
    try check_error(a, "[{\"success\":{\"/lights/1/state/on\":true}}]", null);
    const unauthorized = " \r\n[{\"error\":{\"type\":1,\"address\":\"/\"," ++
        "\"description\":\"unauthorized user\"}}]";
    try testing.expectError(error.BridgeError, check_error(a, unauthorized, null));
    // Any error among successes fails the whole write, and says why.
    const partly = "[{\"success\":{}}," ++
        "{\"error\":{\"type\":201,\"description\":\"device is off\"}}]";
    var why: Failure = .{};
    try testing.expectError(error.BridgeError, check_error(a, partly, &why));
    try testing.expectEqual(@as(u32, 201), why.type);
    try testing.expectEqualStrings("device is off", why.description);
    try testing.expectError(error.BadResponse, check_error(a, "[{\"error\":", null));
}

test "pairing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user = "83b7780291a6ceffbe0bd049104df";
    const paired = "[{\"success\":{\"username\":\"" ++ user ++ "\"}}]";
    try testing.expectEqualStrings(user, (try pairing_user(a, paired, null)).?);
    const not_pressed = "[{\"error\":{\"type\":101,\"address\":\"\"," ++
        "\"description\":\"link button not pressed\"}}]";
    try testing.expectEqual(null, try pairing_user(a, not_pressed, null));
    const refused = "[{\"error\":{\"type\":7,\"description\":\"invalid value\"}}]";
    try testing.expectError(error.BridgeError, pairing_user(a, refused, null));
    for ([_][]const u8{
        "[]",
        "[{\"success\":{\"user\":\"x\"}}]",
        "[{\"success\":\"x\"}]",
        "[{\"success\":{\"username\":42}}]",
    }) |bad| try testing.expectError(error.BadResponse, pairing_user(a, bad, null));
}

test "state body: nulls left out, out-of-range values clamped" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("{\"on\":true}", try state_body(&buf, .{ .on = true }));
    const clamped = try state_body(&buf, .{ .bri = 0, .sat = 255 });
    try testing.expectEqualStrings("{\"bri\":1,\"sat\":254}", clamped);
    const largest: Change = .{ .on = false, .bri = 255, .hue = 65535, .sat = 0 };
    const all = try state_body(&buf, largest);
    try testing.expectEqualStrings("{\"on\":false,\"bri\":254,\"hue\":65535,\"sat\":0}", all);
    try testing.expectEqualStrings("{}", try state_body(&buf, .{}));
    // The largest change fits the 80-byte buffer hue.zig gives it, but not a tiny one.
    var small: [10]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, state_body(&small, largest));
}

test "parse_change" {
    const full: Change = .{ .on = true, .bri = 200, .hue = 8000, .sat = 254 };
    try testing.expectEqualDeep(full, try parse_change("on=1&bri=200&hue=8000&sat=254"));
    try testing.expectEqualDeep(Change{ .on = false }, try parse_change("on=0"));
    try testing.expectEqualDeep(Change{}, try parse_change(""));
    try testing.expectError(error.BadParameter, parse_change("on=2")); // u1
    try testing.expectError(error.BadParameter, parse_change("bri=256"));
    try testing.expectError(error.BadParameter, parse_change("hue=-1"));
    try testing.expectError(error.BadParameter, parse_change("sat"));
    try testing.expectError(error.BadParameter, parse_change("colour=red"));
    try testing.expectError(error.BadParameter, parse_change("bri="));
}

test "parse_ipv4" {
    try testing.expectEqual([4]u8{ 192, 168, 1, 20 }, try parse_ipv4("192.168.1.20"));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try parse_ipv4("0.0.0.0"));
    for ([_][]const u8{
        "",
        "192.168.1",
        "192.168.1.20.5",
        "192.168.1.256",
        "192.168..20",
        "a.b.c.d",
        "192.168.1.20 ",
    }) |bad| try testing.expectError(error.BadAddress, parse_ipv4(bad));
}
