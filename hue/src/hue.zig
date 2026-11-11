//! Minimal Philips Hue bridge client: local API v1 over plain HTTP (port 80).
const std = @import("std");
const net = @import("net");
const lwip = net.lwip;
const mdns = @import("mdns.zig");
const scenes = @import("scenes.zig");
const colour = @import("screen").colour;

const log = std.log.scoped(.hue);

pub const Bridge = struct {
    addr: lwip.c.ip_addr_t,
    host_buf: [15]u8,
    host_len: u8,

    pub fn init(ip: []const u8) !Bridge {
        return from_octets(try parse_ipv4(ip));
    }

    pub fn from_octets(octets: [4]u8) Bridge {
        var b: Bridge = .{ .addr = std.mem.zeroes(lwip.c.ip_addr_t), .host_buf = undefined, .host_len = 0 };
        b.addr = ip_addr(octets);
        b.host_len = @intCast((std.fmt.bufPrint(&b.host_buf, "{}.{}.{}.{}", .{ octets[0], octets[1], octets[2], octets[3] }) catch unreachable).len);
        return b;
    }

    /// Dotted IPv4 text, as sent in the Host header and stored in the settings.
    pub fn host(b: *const Bridge) []const u8 {
        return b.host_buf[0..b.host_len];
    }
};

pub const Config = struct {
    name: []const u8,
    apiversion: []const u8,
    bridgeid: []const u8,
};

pub const LightState = struct {
    on: bool,
    reachable: bool = true,
    /// Brightness 1..254. Absent on on/off-only plugs.
    bri: ?u8 = null,
    /// Hue 0..65535 and saturation 0..254. Absent on white-only lights.
    hue: ?u16 = null,
    sat: ?u8 = null,
};

pub const Light = struct {
    name: []const u8,
    type: []const u8 = "",
    state: LightState,
};

/// A room or zone. `action` holds the last values sent to the whole group, `state` what
/// its lights actually do.
pub const Group = struct {
    name: []const u8,
    /// "Room", "Zone", "LightGroup", "Entertainment", ...
    type: []const u8 = "",
    /// Light ids.
    lights: []const []const u8 = &.{},
    state: struct { any_on: bool = false, all_on: bool = false } = .{},
    action: struct { bri: ?u8 = null, hue: ?u16 = null, sat: ?u8 = null } = .{},

    /// The group seen as one light: on when any of its lights is.
    pub fn as_light(g: Group) Light {
        return .{ .name = g.name, .type = g.type, .state = .{
            .on = g.state.any_on,
            .bri = g.action.bri,
            .hue = g.action.hue,
            .sat = g.action.sat,
        } };
    }
};

pub const Kind = enum { light, group };

/// What a read or a change applies to: one light, or a whole room or zone.
pub const Target = struct { kind: Kind, id: []const u8 };

/// A state change; null fields are left alone.
pub const Change = struct {
    on: ?bool = null,
    bri: ?u8 = null,
    hue: ?u16 = null,
    sat: ?u8 = null,
};

/// One entry of the array the bridge returns for writes and for errors.
const Result = struct {
    success: ?std.json.Value = null,
    @"error": ?struct { type: u32, description: []const u8 } = null,
};

pub const Error = error{ BridgeError, HttpStatus, BadResponse };

/// Response bodies land here. `/lights` with many lights runs to tens of KiB.
var response_buf: [48 * 1024]u8 = undefined;

pub fn get_config(arena: std.mem.Allocator, bridge: Bridge) !Config {
    const body = try request(bridge, "GET", "/api/config", "");
    return parse(Config, arena, body);
}

/// Pairing: succeeds only within 30 s of pressing the bridge's link button.
/// Returns null while the button has not been pressed.
pub fn create_user(arena: std.mem.Allocator, bridge: Bridge, devicetype: []const u8) !?[]const u8 {
    var req: [64]u8 = undefined;
    const body = try request(bridge, "POST", "/api", try std.fmt.bufPrint(&req, "{{\"devicetype\":\"{s}\"}}", .{devicetype}));
    const results = try parse([]Result, arena, body);
    if (results.len == 0) return error.BadResponse;
    if (results[0].@"error") |e| {
        if (e.type == 101) return null; // link button not pressed
        log.err("pairing failed: {s} (type {})", .{ e.description, e.type });
        return error.BridgeError;
    }
    const success = results[0].success orelse return error.BadResponse;
    const user = success.object.get("username") orelse return error.BadResponse;
    if (user != .string) return error.BadResponse;
    return user.string;
}

/// Asks the LAN for a Hue bridge over mDNS (see mdns.zig) and returns the first one that
/// answers, or null after `tries` queries a second apart.
pub fn discover(tries: u8) !?Bridge {
    const conn = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_UDP, 0, null) orelse
        return error.OutOfMemory;
    defer _ = lwip.c.netconn_delete(conn);
    try lwip.c_err(lwip.c.netconn_bind(conn, null, 0)); // any address, ephemeral port
    conn[0].recv_timeout = 1000;

    var query_buf: [64]u8 = undefined;
    const query = mdns.build_query(&query_buf);
    const group = ip_addr(mdns.group);

    for (0..tries) |_| {
        {
            const out = lwip.c.netbuf_new() orelse return error.OutOfMemory;
            defer lwip.c.netbuf_delete(out);
            try lwip.c_err(lwip.c.netbuf_ref(out, query.ptr, @intCast(query.len)));
            try lwip.c_err(lwip.c.netconn_sendto(conn, out, &group, mdns.port));
        }
        // Other devices may answer too (they shouldn't for this name, but some do): keep
        // reading until the timeout.
        while (true) {
            var in: ?*lwip.c.netbuf = null;
            lwip.c_err(lwip.c.netconn_recv(conn, &in)) catch |err| switch (err) {
                error.Timeout => break,
                else => return err,
            };
            defer lwip.c.netbuf_delete(in);
            var buf: [1500]u8 = undefined;
            const n = lwip.c.pbuf_copy_partial(in.?.p, &buf, buf.len, 0);
            const answer = mdns.parse(buf[0..n]) catch |err| {
                log.debug("ignoring mDNS packet: {t}", .{err});
                continue;
            };
            if (!answer.service) continue;
            // Without an A record in the answer, the sender is the bridge.
            const octets = answer.addr orelse octets_of(in.?.addr);
            return Bridge.from_octets(octets);
        }
    }
    return null;
}

pub fn get_lights(arena: std.mem.Allocator, bridge: Bridge, user: []const u8) !std.json.ArrayHashMap(Light) {
    var path: [96]u8 = undefined;
    const body = try request(bridge, "GET", try std.fmt.bufPrint(&path, "/api/{s}/lights", .{user}), "");
    try check_error(arena, body);
    return parse(std.json.ArrayHashMap(Light), arena, body);
}

pub fn get_light(arena: std.mem.Allocator, bridge: Bridge, user: []const u8, id: []const u8) !Light {
    var path: [112]u8 = undefined;
    const body = try request(bridge, "GET", try std.fmt.bufPrint(&path, "/api/{s}/lights/{s}", .{ user, id }), "");
    try check_error(arena, body);
    return parse(Light, arena, body);
}

pub fn get_groups(arena: std.mem.Allocator, bridge: Bridge, user: []const u8) !std.json.ArrayHashMap(Group) {
    var path: [96]u8 = undefined;
    const body = try request(bridge, "GET", try std.fmt.bufPrint(&path, "/api/{s}/groups", .{user}), "");
    try check_error(arena, body);
    return parse(std.json.ArrayHashMap(Group), arena, body);
}

/// A light, or a group seen as one light.
pub fn get(arena: std.mem.Allocator, bridge: Bridge, user: []const u8, target: Target) !Light {
    return switch (target.kind) {
        .light => get_light(arena, bridge, user, target.id),
        .group => {
            var path: [112]u8 = undefined;
            const body = try request(bridge, "GET", try std.fmt.bufPrint(&path, "/api/{s}/groups/{s}", .{ user, target.id }), "");
            try check_error(arena, body);
            return (try parse(Group, arena, body)).as_light();
        },
    };
}

/// Calls `sink.add(scene)` for each scene (see scenes.zig). Slices are only valid during the
/// call.
pub fn get_scenes(arena: std.mem.Allocator, bridge: Bridge, user: []const u8, sink: anytype) !void {
    var path: [96]u8 = undefined;
    const body = try request(bridge, "GET", try std.fmt.bufPrint(&path, "/api/{s}/scenes", .{user}), "");
    try check_error(arena, body);
    var scratch: [1024]u8 = undefined;
    scenes.parse(body, &scratch, sink) catch |err| {
        log.err("unexpected scenes JSON ({t}): {s}", .{ err, body[0..@min(body.len, 160)] });
        return error.BadResponse;
    };
}

/// What a scene looks like: the average colour and brightness of the lights it turns on,
/// or null when it turns them all off.
pub const Look = struct { rgb: colour.Rgb, bri: u8 };

pub fn get_scene_look(arena: std.mem.Allocator, bridge: Bridge, user: []const u8, scene: []const u8) !?Look {
    var path: [112]u8 = undefined;
    const body = try request(bridge, "GET", try std.fmt.bufPrint(&path, "/api/{s}/scenes/{s}", .{ user, scene }), "");
    try check_error(arena, body);
    const State = struct {
        on: bool = false,
        bri: ?u8 = null,
        xy: ?[2]f32 = null,
        ct: ?u16 = null,
        hue: ?u16 = null,
        sat: ?u8 = null,
    };
    const detail = try parse(struct { lightstates: std.json.ArrayHashMap(State) = .{} }, arena, body);
    var mix: colour.Mix = .{};
    for (detail.lightstates.map.values()) |ls| {
        if (!ls.on) continue;
        const rgb = if (ls.xy) |xy|
            colour.xy_to_rgb(xy[0], xy[1])
        else if (ls.hue != null and ls.sat != null)
            colour.hsv_to_rgb(ls.hue.?, ls.sat.?)
        else if (ls.ct) |ct|
            colour.ct_to_rgb(ct)
        else
            colour.warm_white;
        mix.add(rgb, ls.bri orelse 254);
    }
    const rgb = mix.colour() orelse return null;
    return .{ .rgb = rgb, .bri = mix.brightness() };
}

/// Recalls a scene on its group: a room or zone, or group 0 (all lights) for a LightScene.
pub fn recall_scene(arena: std.mem.Allocator, bridge: Bridge, user: []const u8, group: []const u8, scene: []const u8) !void {
    var json_buf: [48]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf, "{{\"scene\":\"{s}\"}}", .{scene});
    var path: [128]u8 = undefined;
    const body = try request(bridge, "PUT", try std.fmt.bufPrint(&path, "/api/{s}/groups/{s}/action", .{ user, group }), json);
    try check_error(arena, body);
}

/// Applies `change` to a light (`/state`) or to every light of a group (`/action`, same
/// body). The bridge rejects bri/hue/sat while a light is off (error 201), so callers
/// changing those should also pass `.on = true`.
pub fn set_state(arena: std.mem.Allocator, bridge: Bridge, user: []const u8, target: Target, change: Change) !void {
    if (std.meta.eql(change, Change{})) return; // nothing to change

    // The bridge rejects bri 0 and bri/sat 255.
    var c = change;
    if (c.bri) |v| c.bri = std.math.clamp(v, 1, 254);
    if (c.sat) |v| c.sat = @min(v, 254);

    var json_buf: [80]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf, "{f}", .{std.json.fmt(c, .{ .emit_null_optional_fields = false })});

    var path: [128]u8 = undefined;
    const url = switch (target.kind) {
        .light => try std.fmt.bufPrint(&path, "/api/{s}/lights/{s}/state", .{ user, target.id }),
        .group => try std.fmt.bufPrint(&path, "/api/{s}/groups/{s}/action", .{ user, target.id }),
    };
    const body = try request(bridge, "PUT", url, json);
    try check_error(arena, body);
}

/// Reads go back as an object, but failures (e.g. an unknown username) come back as an
/// array of `{"error": ...}`, still with HTTP 200.
fn check_error(arena: std.mem.Allocator, body: []const u8) !void {
    const trimmed = std.mem.trimStart(u8, body, " \r\n\t");
    if (trimmed.len == 0 or trimmed[0] != '[') return;
    const results = try parse([]Result, arena, trimmed);
    for (results) |r| if (r.@"error") |e| {
        log.err("bridge error: {s} (type {})", .{ e.description, e.type });
        return error.BridgeError;
    };
}

fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true }) catch |err| {
        log.err("unexpected JSON ({t}): {s}", .{ err, body[0..@min(body.len, 160)] });
        return error.BadResponse;
    };
}

/// One HTTP exchange; returns the response body (valid until the next request).
/// HTTP/1.0 so the bridge can't answer with chunked encoding: it closes the connection
/// after the body, which is how we find the end.
fn request(bridge: Bridge, method: []const u8, path: []const u8, body: []const u8) ![]const u8 {
    const conn = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse
        return error.OutOfMemory;
    defer _ = lwip.c.netconn_delete(conn);
    conn[0].recv_timeout = 5000;

    try lwip.c_err(lwip.c.netconn_connect(conn, &bridge.addr, 80));
    defer _ = lwip.c.netconn_close(conn);

    var head: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&head, "{s} {s} HTTP/1.0\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", .{ method, path, bridge.host(), body.len });
    try write_all(conn, req);
    if (body.len > 0) try write_all(conn, body);

    var len: usize = 0;
    while (true) {
        var nb: ?*lwip.c.netbuf = null;
        lwip.c_err(lwip.c.netconn_recv(conn, &nb)) catch |err| switch (err) {
            error.ConnectionClosed => break,
            else => return err,
        };
        defer lwip.c.netbuf_delete(nb);
        while (true) {
            var ptr: ?*anyopaque = null;
            var n: u16 = 0;
            try lwip.c_err(lwip.c.netbuf_data(nb, &ptr, &n));
            const chunk = @as([*]const u8, @ptrCast(ptr))[0..n];
            if (len + chunk.len > response_buf.len) return error.ResponseTooLarge;
            @memcpy(response_buf[len..][0..chunk.len], chunk);
            len += chunk.len;
            if (lwip.c.netbuf_next(nb) < 0) break;
        }
    }

    const resp = response_buf[0..len];
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse;
    // "HTTP/1.x 200 ..."
    if (resp.len < 12 or !std.mem.eql(u8, resp[9..12], "200")) {
        log.err("HTTP status: {s}", .{resp[0 .. std.mem.indexOf(u8, resp, "\r\n") orelse 0]});
        return error.HttpStatus;
    }
    return resp[head_end + 4 ..];
}

fn write_all(conn: *lwip.c.netconn, bytes: []const u8) !void {
    try lwip.c_err(lwip.c.netconn_write_partly(conn, bytes.ptr, bytes.len, lwip.c.NETCONN_COPY, null));
}

fn parse_ipv4(s: []const u8) ![4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&octets) |*o| o.* = try std.fmt.parseInt(u8, it.next() orelse return error.BadAddress, 10);
    if (it.next() != null) return error.BadAddress;
    return octets;
}

fn ip_addr(octets: [4]u8) lwip.c.ip_addr_t {
    var addr = std.mem.zeroes(lwip.c.ip_addr_t);
    addr.type = lwip.c.IPADDR_TYPE_V4;
    // lwIP stores IPv4 addresses in network byte order.
    addr.u_addr.ip4.addr = std.mem.readInt(u32, &octets, .little);
    return addr;
}

fn octets_of(addr: lwip.c.ip_addr_t) [4]u8 {
    var octets: [4]u8 = undefined;
    std.mem.writeInt(u32, &octets, addr.u_addr.ip4.addr, .little);
    return octets;
}
