//! The `/set` query: `on=0|1`, `r`, `g`, `b` (0..255), any subset. Pure, tested on the host
//! (`zig build test`).
const std = @import("std");

/// What the query asks to change; null fields are left alone.
pub const Update = struct {
    on: ?bool = null,
    r: ?u8 = null,
    g: ?u8 = null,
    b: ?u8 = null,
};

pub fn parse(query: []const u8) error{BadParameter}!Update {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var update: Update = .{};
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadParameter;
        const key = pair[0..eq];
        const value = std.fmt.parseInt(u8, pair[eq + 1 ..], 10) catch return error.BadParameter;
        if (std.mem.eql(u8, key, "on")) {
            update.on = value != 0;
        } else if (std.mem.eql(u8, key, "r")) {
            update.r = value;
        } else if (std.mem.eql(u8, key, "g")) {
            update.g = value;
        } else if (std.mem.eql(u8, key, "b")) {
            update.b = value;
        } else return error.BadParameter;
    }
    return update;
}

const testing = std.testing;

test "any subset" {
    const all: Update = .{ .on = true, .r = 255, .g = 128, .b = 0 };
    try testing.expectEqualDeep(all, try parse("on=1&r=255&g=128&b=0"));
    try testing.expectEqualDeep(Update{ .g = 7 }, try parse("g=7"));
    try testing.expectEqualDeep(Update{ .on = false }, try parse("on=0"));
    try testing.expectEqualDeep(Update{}, try parse(""));
    // The last value of a repeated key wins.
    try testing.expectEqualDeep(Update{ .r = 2 }, try parse("r=1&r=2"));
}

test "bad parameters" {
    for ([_][]const u8{ "r=256", "r=-1", "r=", "r", "x=1", "on=yes", "r=1&b=0x10" }) |bad| {
        try testing.expectError(error.BadParameter, parse(bad));
    }
}
