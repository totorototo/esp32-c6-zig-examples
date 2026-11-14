//! Netatmo Energy API answers, read by streaming: `homesdata` carries every heating schedule
//! and runs to tens of KiB, more than the free RAM next to Wi-Fi and TLS. The parsers walk
//! the JSON token by token, keep rooms and modules in fixed arrays, and skip the rest.
//!
//! Generic over the JSON source (`std.json.Scanner` or `std.json.Reader`), so the host tests
//! (`zig build test`) run the same streaming code the board does. Pure std.
const std = @import("std");

pub const max_rooms = 16;
pub const max_modules = 24;

pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: u8 = 0,

        const Self = @This();

        pub fn slice(t: *const Self) []const u8 {
            return t.buf[0..t.len];
        }

        /// For display text: cut to fit, at a UTF-8 character boundary (a cut in the middle
        /// of `é` would leave an invalid byte for the font to draw).
        pub fn set(t: *Self, s: []const u8) void {
            @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
            var len = @min(s.len, n);
            while (len > 0 and len < s.len and s[len] & 0xC0 == 0x80) len -= 1;
            t.len = @intCast(len);
            @memcpy(t.buf[0..len], s[0..len]);
        }

        /// For ids, which go back to the API: a cut one would name another room, or none.
        pub fn set_exact(t: *Self, s: []const u8) error{ValueTooLong}!void {
            if (s.len > n) return error.ValueTooLong;
            t.set(s);
        }

        pub fn eql(t: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, t.slice(), s);
        }
    };
}

pub const Room = struct {
    id: Text(16) = .{},
    name: Text(32) = .{},
    type: Text(16) = .{},
    // From homestatus, which only lists rooms with a thermostat or a valve:
    in_status: bool = false,
    measured: ?f32 = null,
    setpoint: ?f32 = null,
    /// "schedule", "manual", "away", "hg" (frost guard), "off", "max", "home".
    mode: Text(12) = .{},
    reachable: bool = false,
    /// Valve opening the room asks for, 0..100.
    heating: ?u8 = null,
};

pub const Module = struct {
    id: Text(18) = .{},
    /// "NAPlug" (relay), "NATherm1" (thermostat), "NRV" (valve), ...
    type: Text(10) = .{},
    name: Text(32) = .{},
    room_id: Text(16) = .{},
    // From homestatus:
    reachable: bool = false,
    /// "max", "full", "high", "medium", "low", "very_low".
    battery: Text(10) = .{},
};

pub const Home = struct {
    id: Text(24) = .{},
    name: Text(32) = .{},
    rooms: [max_rooms]Room = undefined,
    n_rooms: usize = 0,
    modules: [max_modules]Module = undefined,
    n_modules: usize = 0,

    pub fn room(h: *Home, id: []const u8) ?*Room {
        for (h.rooms[0..h.n_rooms]) |*r| if (r.id.eql(id)) return r;
        return null;
    }

    pub fn module(h: *Home, id: []const u8) ?*Module {
        for (h.modules[0..h.n_modules]) |*m| if (m.id.eql(id)) return m;
        return null;
    }

    fn new_room(h: *Home) ?*Room {
        // `==` below only stops at the limit if the count never jumped past it.
        std.debug.assert(h.n_rooms <= max_rooms);
        if (h.n_rooms == max_rooms) return null;
        h.rooms[h.n_rooms] = .{};
        h.n_rooms += 1;
        return &h.rooms[h.n_rooms - 1];
    }

    fn new_module(h: *Home) ?*Module {
        std.debug.assert(h.n_modules <= max_modules);
        if (h.n_modules == max_modules) return null;
        h.modules[h.n_modules] = .{};
        h.n_modules += 1;
        return &h.modules[h.n_modules - 1];
    }
};

pub const Error = error{ BadResponse, OutOfMemory, BufferUnderrun, ValueTooLong } || std.Io.Reader.Error || std.json.Error;

// ---- homesdata: the first home's rooms and modules ----

/// `{"body":{"homes":[{"id","name","rooms":[...],"modules":[...],...}]},"status":"ok"}`.
/// Reads the first home (or the one with `want_id`) into `home`. Returns false if none.
pub fn read_homesdata(src: anytype, scratch: std.mem.Allocator, want_id: ?[]const u8, home: *Home) Error!bool {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var found = false;
    try expect(src, .object_begin);
    while (try key(src, scratch)) |k| {
        if (!std.mem.eql(u8, k, "body")) {
            try src.skipValue();
            continue;
        }
        try expect(src, .object_begin);
        while (try key(src, scratch)) |bk| {
            if (!std.mem.eql(u8, bk, "homes")) {
                try src.skipValue();
                continue;
            }
            try expect(src, .array_begin);
            while (true) {
                // Peek first: a home after the one found is skipped whole, `{` included.
                switch (try src.peekNextTokenType()) {
                    .array_end => {
                        _ = try src.next();
                        break;
                    },
                    .object_begin => if (found) {
                        try src.skipValue();
                        continue;
                    } else {
                        _ = try src.next();
                    },
                    else => return error.BadResponse,
                }
                var h: Home = .{};
                try read_home(src, scratch, &h);
                if (want_id == null or h.id.eql(want_id.?)) {
                    home.* = h;
                    found = true;
                }
            }
        }
    }
    return found;
}

/// Reads one home object, `{` already consumed by `next_in_array`.
fn read_home(src: anytype, scratch: std.mem.Allocator, h: *Home) Error!void {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    while (try key(src, scratch)) |k| {
        if (std.mem.eql(u8, k, "id")) {
            try h.id.set_exact(try string(src, scratch));
        } else if (std.mem.eql(u8, k, "name")) {
            h.name.set(try string(src, scratch));
        } else if (std.mem.eql(u8, k, "rooms")) {
            try expect(src, .array_begin);
            while (try next_in_array(src)) {
                var r: Room = .{};
                while (try key(src, scratch)) |rk| {
                    if (std.mem.eql(u8, rk, "id")) try r.id.set_exact(try string(src, scratch)) else if (std.mem.eql(u8, rk, "name")) r.name.set(try string(src, scratch)) else if (std.mem.eql(u8, rk, "type")) r.type.set(try string(src, scratch)) else try src.skipValue();
                }
                if (h.new_room()) |slot| slot.* = r;
            }
        } else if (std.mem.eql(u8, k, "modules")) {
            try expect(src, .array_begin);
            while (try next_in_array(src)) {
                var m: Module = .{};
                while (try key(src, scratch)) |mk| {
                    if (std.mem.eql(u8, mk, "id")) try m.id.set_exact(try string(src, scratch)) else if (std.mem.eql(u8, mk, "type")) m.type.set(try string(src, scratch)) else if (std.mem.eql(u8, mk, "name")) m.name.set(try string(src, scratch)) else if (std.mem.eql(u8, mk, "room_id")) try m.room_id.set_exact(try string(src, scratch)) else try src.skipValue();
                }
                if (h.new_module()) |slot| slot.* = m;
            }
        } else try src.skipValue(); // schedules, coordinates, ...
    }
}

// ---- homestatus: live state, merged into a home read from homesdata ----

/// `{"body":{"home":{"id","rooms":[{"id","therm_measured_temperature",...}],"modules":[...]}}}`.
pub fn read_homestatus(src: anytype, scratch: std.mem.Allocator, home: *Home) Error!void {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    try expect(src, .object_begin);
    while (try key(src, scratch)) |k| {
        if (!std.mem.eql(u8, k, "body")) {
            try src.skipValue();
            continue;
        }
        try expect(src, .object_begin);
        while (try key(src, scratch)) |bk| {
            if (!std.mem.eql(u8, bk, "home")) {
                try src.skipValue();
                continue;
            }
            try expect(src, .object_begin);
            while (try key(src, scratch)) |hk| {
                if (std.mem.eql(u8, hk, "rooms")) {
                    try expect(src, .array_begin);
                    while (try next_in_array(src)) try read_room_status(src, scratch, home);
                } else if (std.mem.eql(u8, hk, "modules")) {
                    try expect(src, .array_begin);
                    while (try next_in_array(src)) try read_module_status(src, scratch, home);
                } else try src.skipValue();
            }
        }
    }
}

fn read_room_status(src: anytype, scratch: std.mem.Allocator, home: *Home) Error!void {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var s: Room = .{};
    var heating: ?u8 = null;
    while (try key(src, scratch)) |k| {
        if (std.mem.eql(u8, k, "id")) {
            try s.id.set_exact(try string(src, scratch));
        } else if (std.mem.eql(u8, k, "therm_measured_temperature")) {
            s.measured = try number(f32, src, scratch);
        } else if (std.mem.eql(u8, k, "therm_setpoint_temperature")) {
            s.setpoint = try number(f32, src, scratch);
        } else if (std.mem.eql(u8, k, "therm_setpoint_mode")) {
            s.mode.set(try string(src, scratch));
        } else if (std.mem.eql(u8, k, "reachable")) {
            s.reachable = try boolean(src);
        } else if (std.mem.eql(u8, k, "heating_power_request")) {
            heating = @intFromFloat(std.math.clamp(try number(f32, src, scratch), 0, 100));
        } else try src.skipValue();
    }
    const r = home.room(s.id.slice()) orelse return; // a room homesdata didn't list
    r.in_status = true;
    r.measured = s.measured;
    r.setpoint = s.setpoint;
    r.mode = s.mode;
    r.reachable = s.reachable;
    r.heating = heating;
}

fn read_module_status(src: anytype, scratch: std.mem.Allocator, home: *Home) Error!void {
    @setRuntimeSafety(true); // parses network input: keep bounds checks in ReleaseSmall
    var id: Text(18) = .{};
    var reachable = false;
    var battery: Text(10) = .{};
    while (try key(src, scratch)) |k| {
        if (std.mem.eql(u8, k, "id")) {
            try id.set_exact(try string(src, scratch));
        } else if (std.mem.eql(u8, k, "reachable")) {
            reachable = try boolean(src);
        } else if (std.mem.eql(u8, k, "battery_state")) {
            battery.set(try string(src, scratch));
        } else try src.skipValue();
    }
    const m = home.module(id.slice()) orelse return;
    m.reachable = reachable;
    m.battery = battery;
}

// ---- small answers (token, setroomthermpoint), read whole ----

pub const Token = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: u32 = 10800,
};

pub fn parse_token(arena: std.mem.Allocator, body: []const u8) !Token {
    return std.json.parseFromSliceLeaky(Token, arena, body, .{ .ignore_unknown_fields = true });
}

/// Netatmo's errors: `{"error":"invalid_grant"}` (OAuth) or `{"error":{"code":..,"message":..}}`.
pub fn error_text(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return body[0..@min(body.len, 120)];
    if (v != .object) return "?";
    const e = v.object.get("error") orelse return "?";
    return switch (e) {
        .string => |s| s,
        .object => |o| if (o.get("message")) |m| (if (m == .string) m.string else "?") else "?",
        else => "?",
    };
}

// ---- forms ----

/// Writes `s` percent-encoded for an application/x-www-form-urlencoded body or a query:
/// unreserved characters (RFC 3986) as is, everything else as %XX.
pub fn percent_encode(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

// ---- token helpers over either JSON source ----

fn expect(src: anytype, comptime want: std.meta.Tag(std.json.Token)) Error!void {
    const t = try src.next();
    if (t != want) return error.BadResponse;
}

/// The next key of the current object, or null at its end.
fn key(src: anytype, scratch: std.mem.Allocator) Error!?[]const u8 {
    return switch (try src.nextAlloc(scratch, .alloc_if_needed)) {
        .object_end => null,
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.BadResponse,
    };
}

/// True with the next element's `{` consumed; false at the array's end.
fn next_in_array(src: anytype) Error!bool {
    return switch (try src.next()) {
        .object_begin => true,
        .array_end => false,
        else => error.BadResponse,
    };
}

fn string(src: anytype, scratch: std.mem.Allocator) Error![]const u8 {
    return switch (try src.nextAlloc(scratch, .alloc_if_needed)) {
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.BadResponse,
    };
}

fn number(comptime T: type, src: anytype, scratch: std.mem.Allocator) Error!T {
    const text = switch (try src.nextAlloc(scratch, .alloc_if_needed)) {
        .number => |s| s,
        .allocated_number => |s| s,
        else => return error.BadResponse,
    };
    return std.fmt.parseFloat(T, text) catch error.BadResponse;
}

fn boolean(src: anytype) Error!bool {
    return switch (try src.next()) {
        .true => true,
        .false => false,
        else => error.BadResponse,
    };
}

// ---- tests ----

const testing = std.testing;

// Shaped like Netatmo's documented answers, with the bulky parts kept (schedules).
const homesdata_json =
    \\{"body":{"homes":[{"id":"5a327cbdb05a2133678b5d3e","name":"Maison","altitude":112,
    \\"coordinates":[2.35,48.85],"country":"FR","timezone":"Europe/Paris",
    \\"rooms":[{"id":"2255031728","name":"Salon","type":"livingroom","module_ids":["04:00:00:aa:bb:cc"]},
    \\{"id":"1196426604","name":"Chambre Alo\u00efse","type":"bedroom","module_ids":["09:00:00:dd:ee:ff"]}],
    \\"modules":[{"id":"70:ee:50:11:22:33","type":"NAPlug","name":"Relais","setup_date":1512210000,
    \\"modules_bridged":["04:00:00:aa:bb:cc","09:00:00:dd:ee:ff"]},
    \\{"id":"04:00:00:aa:bb:cc","type":"NATherm1","name":"Thermostat","room_id":"2255031728","bridge":"70:ee:50:11:22:33"},
    \\{"id":"09:00:00:dd:ee:ff","type":"NRV","name":"Vanne chambre","room_id":"1196426604","bridge":"70:ee:50:11:22:33"}],
    \\"schedules":[{"timetable":[{"zone_id":1,"m_offset":0},{"zone_id":0,"m_offset":420}],
    \\"zones":[{"name":"Confort","id":0,"type":0,"rooms":[{"id":"2255031728","therm_setpoint_temperature":20}]}],
    \\"name":"Semaine","default":true,"away_temp":12,"hg_temp":7,"id":"5a327cbdb05a2133678b5d40","selected":true,"type":"therm"}],
    \\"therm_setpoint_default_duration":180,"therm_mode":"schedule"},
    \\{"id":"second","name":"Chalet","rooms":[],"modules":[]}],
    \\"user":{"email":"x@example.com","language":"fr-FR"}},"status":"ok","time_exec":0.05,"time_server":1794341450}
;

const homestatus_json =
    \\{"status":"ok","time_server":1794341450,"body":{"home":{"id":"5a327cbdb05a2133678b5d3e",
    \\"modules":[{"id":"70:ee:50:11:22:33","type":"NAPlug","firmware_revision":203,"rf_strength":107,"wifi_strength":44},
    \\{"id":"04:00:00:aa:bb:cc","type":"NATherm1","boiler_status":true,"battery_state":"high","reachable":true},
    \\{"id":"09:00:00:dd:ee:ff","type":"NRV","battery_state":"low","reachable":false}],
    \\"rooms":[{"id":"2255031728","reachable":true,"therm_measured_temperature":19.6,"heating_power_request":45,
    \\"therm_setpoint_temperature":20.5,"therm_setpoint_mode":"manual","therm_setpoint_end_time":1794345050},
    \\{"id":"1196426604","reachable":false,"therm_measured_temperature":17,"therm_setpoint_temperature":17,"therm_setpoint_mode":"schedule"}]}}}
;

test "homesdata, streamed" {
    var io: std.Io.Reader = .fixed(homesdata_json);
    var scratch_mem: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch_mem);
    var reader: std.json.Reader = .init(fba.allocator(), &io);
    var home: Home = .{};
    try testing.expect(try read_homesdata(&reader, fba.allocator(), null, &home));
    try testing.expectEqualStrings("Maison", home.name.slice());
    try testing.expectEqual(@as(usize, 2), home.n_rooms);
    try testing.expectEqualStrings("Chambre Aloïse", home.rooms[1].name.slice());
    try testing.expectEqual(@as(usize, 3), home.n_modules);
    try testing.expectEqualStrings("NRV", home.modules[2].type.slice());
    try testing.expectEqualStrings("1196426604", home.modules[2].room_id.slice());
}

test "homesdata picks the wanted home" {
    var scanner: std.json.Scanner = .initCompleteInput(testing.allocator, homesdata_json);
    defer scanner.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var home: Home = .{};
    try testing.expect(try read_homesdata(&scanner, arena.allocator(), "second", &home));
    try testing.expectEqualStrings("Chalet", home.name.slice());
    try testing.expectEqual(@as(usize, 0), home.n_rooms);
}

test "homestatus merges into the home" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var home: Home = .{};
    {
        var s: std.json.Scanner = .initCompleteInput(testing.allocator, homesdata_json);
        defer s.deinit();
        _ = try read_homesdata(&s, arena.allocator(), null, &home);
    }
    var io: std.Io.Reader = .fixed(homestatus_json);
    var reader: std.json.Reader = .init(arena.allocator(), &io);
    try read_homestatus(&reader, arena.allocator(), &home);
    const salon = home.room("2255031728").?;
    try testing.expectApproxEqAbs(@as(f32, 19.6), salon.measured.?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20.5), salon.setpoint.?, 0.001);
    try testing.expectEqualStrings("manual", salon.mode.slice());
    try testing.expectEqual(@as(?u8, 45), salon.heating);
    try testing.expect(salon.reachable);
    try testing.expect(salon.in_status);
    const chambre = home.room("1196426604").?;
    try testing.expect(!chambre.reachable);
    try testing.expectEqual(@as(?u8, null), chambre.heating);
    const valve = home.module("09:00:00:dd:ee:ff").?;
    try testing.expectEqualStrings("low", valve.battery.slice());
    try testing.expect(!valve.reachable);
}

test "token and errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try parse_token(arena.allocator(),
        \\{"access_token":"5c3d|aaa","refresh_token":"5c3d|bbb","expires_in":10800,"expire_in":10800,"scope":["read_thermostat","write_thermostat"]}
    );
    try testing.expectEqualStrings("5c3d|bbb", t.refresh_token);
    try testing.expectEqual(@as(u32, 10800), t.expires_in);
    try testing.expectEqualStrings("invalid_grant", error_text(arena.allocator(), "{\"error\":\"invalid_grant\"}"));
    try testing.expectEqualStrings("Access token is missing", error_text(arena.allocator(),
        \\{"error":{"code":1,"message":"Access token is missing"}}
    ));
}

test "percent encoding" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percent_encode(&w, "5c3d|a b+c/é");
    try testing.expectEqualStrings("5c3d%7Ca%20b%2Bc%2F%C3%A9", w.buffered());
}

test "text: names cut at a character, ids refused" {
    var fits: Text(6) = .{};
    fits.set("Séjour"); // 7 bytes: the cut falls between `u` and `r`
    try std.testing.expectEqualStrings("Séjou", fits.slice());
    var short: Text(4) = .{};
    short.set("Aloïse"); // a cut at 4 would split `ï` (bytes 3-4)
    try std.testing.expectEqualStrings("Alo", short.slice());

    var id: Text(4) = .{};
    try id.set_exact("1234");
    try std.testing.expectError(error.ValueTooLong, id.set_exact("12345"));
    try std.testing.expectEqualStrings("1234", id.slice());
}

test "truncated and corrupted answers never panic" {
    const mutations = @import("mutations");
    try mutations.each(homesdata_json, struct {
        fn check(input: []u8) void {
            var scanner: std.json.Scanner = .initCompleteInput(testing.allocator, input);
            defer scanner.deinit();
            var scratch_mem: [1024]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&scratch_mem);
            var home: Home = .{};
            _ = read_homesdata(&scanner, fba.allocator(), null, &home) catch return;
        }
    }.check);
    try mutations.each(homestatus_json, struct {
        fn check(input: []u8) void {
            var scanner: std.json.Scanner = .initCompleteInput(testing.allocator, input);
            defer scanner.deinit();
            var scratch_mem: [1024]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&scratch_mem);
            var home: Home = .{};
            read_homestatus(&scanner, fba.allocator(), &home) catch return;
        }
    }.check);
}
