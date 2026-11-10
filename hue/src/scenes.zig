//! Reads the bridge's `GET /api/<user>/scenes` answer without building a map of it.
//!
//! The answer is an object of scene id -> scene, and each scene carries far more than the
//! remote needs (light lists, app data, timestamps): a home with many scenes runs to tens of
//! KiB. A streaming scan keeps only name, type and group, so memory use doesn't grow with the
//! bridge's contents. Pure std, tested on the host (`zig build test`).
const std = @import("std");

pub const Scene = struct {
    id: []const u8,
    name: []const u8,
    /// The room or zone a GroupScene belongs to. Null for a LightScene, which is recalled
    /// through group 0 (all lights).
    group: ?[]const u8,
    /// Scenes the bridge or an app made for its own use ("recycle": true): not for people.
    recycle: bool,
};

/// Calls `sink.add(scene)` for each scene, in the answer's order. The slices are valid only
/// during the call. `scratch` holds the scanner's nesting stack and any string that needed
/// unescaping; 1 KiB is plenty.
pub fn parse(body: []const u8, scratch: []u8, sink: anytype) !void {
    var fba: std.heap.FixedBufferAllocator = .init(scratch);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), body);
    // Leaked into `fba`, which is dropped on return.

    if (try scanner.next() != .object_begin) return error.BadResponse;
    while (true) {
        const id = switch (try scanner.nextAlloc(fba.allocator(), .alloc_if_needed)) {
            .object_end => return,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.BadResponse,
        };
        if (try scanner.next() != .object_begin) return error.BadResponse;

        var scene: Scene = .{ .id = id, .name = "", .group = null, .recycle = false };
        // Value strings escape rarely (names with quotes or non-ASCII written as \u): those
        // get copied into `fba`, the rest point into `body`.
        while (true) {
            const key = switch (try scanner.nextAlloc(fba.allocator(), .alloc_if_needed)) {
                .object_end => break,
                .string => |s| s,
                .allocated_string => |s| s,
                else => return error.BadResponse,
            };
            if (std.mem.eql(u8, key, "name")) {
                scene.name = try string(&scanner, fba.allocator());
            } else if (std.mem.eql(u8, key, "group")) {
                scene.group = try string(&scanner, fba.allocator());
            } else if (std.mem.eql(u8, key, "recycle")) {
                scene.recycle = switch (try scanner.next()) {
                    .true => true,
                    .false => false,
                    else => return error.BadResponse,
                };
            } else try scanner.skipValue();
        }
        sink.add(scene);
    }
}

fn string(scanner: *std.json.Scanner, allocator: std.mem.Allocator) ![]const u8 {
    return switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.BadResponse,
    };
}

// ---- tests ----

const testing = std.testing;

const Collect = struct {
    names: [8][32]u8 = undefined,
    groups: [8]?[8]u8 = undefined,
    ids: [8][16]u8 = undefined,
    recycle: [8]bool = undefined,
    len: usize = 0,

    fn add(c: *Collect, s: Scene) void {
        c.names[c.len] = @splat(0);
        @memcpy(c.names[c.len][0..s.name.len], s.name);
        c.ids[c.len] = @splat(0);
        @memcpy(c.ids[c.len][0..s.id.len], s.id);
        c.groups[c.len] = if (s.group) |g| blk: {
            var b: [8]u8 = @splat(0);
            @memcpy(b[0..g.len], g);
            break :blk b;
        } else null;
        c.recycle[c.len] = s.recycle;
        c.len += 1;
    }

    fn name(c: *const Collect, i: usize) []const u8 {
        return std.mem.sliceTo(&c.names[i], 0);
    }
};

// Shaped like a real bridge's answer (fields trimmed for length, nesting kept).
const sample =
    \\{
    \\  "4e1c6b20e-on-0": {"name": "Relax", "type": "GroupScene", "group": "1",
    \\    "lights": ["1", "2"], "owner": "abc", "recycle": false, "locked": false,
    \\    "appdata": {"version": 1, "data": "xyz_r01_d01"}, "picture": "",
    \\    "image": "a1f7da49-d181-4328-abea-68c9dc4b5416",
    \\    "lastupdated": "2026-10-01T18:12:00", "version": 2},
    \\  "OxQhdLtXxeyu5nj": {"name": "Movie \"night\"", "type": "LightScene",
    \\    "lights": ["3"], "recycle": false, "lightstates": {"3": {"on": true, "bri": 50}}},
    \\  "tmp0000000000001": {"name": "", "type": "GroupScene", "group": "2", "recycle": true},
    \\  "k2sEc0fFTRyR9nT": {"name": "Café", "type": "GroupScene", "group": "11", "recycle": false}
    \\}
;

test "scenes" {
    var c: Collect = .{};
    var scratch: [1024]u8 = undefined;
    try parse(sample, &scratch, &c);
    try testing.expectEqual(4, c.len);

    try testing.expectEqualStrings("Relax", c.name(0));
    try testing.expectEqualStrings("4e1c6b20e-on-0", std.mem.sliceTo(&c.ids[0], 0));
    try testing.expectEqualStrings("1", std.mem.sliceTo(&c.groups[0].?, 0));
    try testing.expect(!c.recycle[0]);

    try testing.expectEqualStrings("Movie \"night\"", c.name(1));
    try testing.expectEqual(null, c.groups[1]);

    try testing.expect(c.recycle[2]);

    try testing.expectEqualStrings("Café", c.name(3));
    try testing.expectEqualStrings("11", std.mem.sliceTo(&c.groups[3].?, 0));
}

test "bad answers" {
    var c: Collect = .{};
    var scratch: [1024]u8 = undefined;
    // An error reply (unknown username) is an array.
    try testing.expectError(error.BadResponse, parse(
        \\[{"error": {"type": 1, "address": "/scenes", "description": "unauthorized user"}}]
    , &scratch, &c));
    try testing.expectError(error.BadResponse, parse("{\"a\": 1}", &scratch, &c));
    var empty: Collect = .{};
    try parse("{}", &scratch, &empty);
    try testing.expectEqual(0, empty.len);
}
