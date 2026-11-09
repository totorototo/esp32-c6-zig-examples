//! The bridge's lights and rooms/zones as last read, plus which one is selected.
//!
//! Fixed-size copies, so nothing points into the parser's arena or the shared response
//! buffer once a refresh returns.
const std = @import("std");
const hue = @import("hue.zig");

const log = std.log.scoped(.catalog);

/// Per kind. Six rows per screen page, so four pages.
pub const max_entries = 24;

pub const Entry = struct {
    kind: hue.Kind,
    id_buf: [8]u8 = undefined,
    id_len: u8 = 0,
    /// Hue names are at most 32 bytes.
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    state: hue.LightState,

    pub fn id(e: *const Entry) []const u8 {
        return e.id_buf[0..e.id_len];
    }

    pub fn name(e: *const Entry) []const u8 {
        return e.name_buf[0..e.name_len];
    }

    pub fn target(e: *const Entry) hue.Target {
        return .{ .kind = e.kind, .id = e.id() };
    }

    fn set_name(e: *Entry, n: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, n, " ");
        e.name_len = @intCast(@min(trimmed.len, e.name_buf.len));
        @memcpy(e.name_buf[0..e.name_len], trimmed[0..e.name_len]);
    }
};

pub const List = struct {
    items: [max_entries]Entry = undefined,
    len: usize = 0,

    pub fn slice(l: *List) []Entry {
        return l.items[0..l.len];
    }

    pub fn find(l: *List, id: []const u8) ?*Entry {
        for (l.slice()) |*e| if (std.mem.eql(u8, e.id(), id)) return e;
        return null;
    }
};

pub var lights: List = .{};
pub var groups: List = .{};

pub fn list(kind: hue.Kind) *List {
    return switch (kind) {
        .light => &lights,
        .group => &groups,
    };
}

/// The selection is kept by id, not by pointer: a refresh can add or drop entries.
var selected_kind: hue.Kind = .light;
var selected_id_buf: [8]u8 = undefined;
var selected_id_len: usize = 0;

pub fn select(e: ?*const Entry) void {
    const entry = e orelse {
        selected_id_len = 0;
        return;
    };
    selected_kind = entry.kind;
    selected_id_len = entry.id_len;
    @memcpy(selected_id_buf[0..selected_id_len], entry.id());
}

pub fn select_id(kind: hue.Kind, id: []const u8) bool {
    const e = list(kind).find(id) orelse return false;
    select(e);
    return true;
}

pub fn selected() ?*Entry {
    if (selected_id_len == 0) return null;
    return list(selected_kind).find(selected_id_buf[0..selected_id_len]);
}

// ---- bridge access ----

pub const Context = struct {
    bridge: hue.Bridge,
    user: []const u8,
    allocator: std.mem.Allocator,
};

/// Replaces `kind`'s list with what the bridge has now. Rooms and zones only: the other
/// group types (LightGroup, Entertainment, Luminaire) are app or bridge internals.
pub fn refresh(ctx: Context, kind: hue.Kind) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const l = list(kind);
    // Static, not on the stack: 1.4 KiB.
    const fresh = &scratch;
    fresh.len = 0;
    switch (kind) {
        .light => {
            const map = try hue.get_lights(arena.allocator(), ctx.bridge, ctx.user);
            var it = map.map.iterator();
            while (it.next()) |kv| add(fresh, .light, kv.key_ptr.*, kv.value_ptr.name, kv.value_ptr.state);
        },
        .group => {
            const map = try hue.get_groups(arena.allocator(), ctx.bridge, ctx.user);
            var it = map.map.iterator();
            while (it.next()) |kv| {
                const g = kv.value_ptr.*;
                if (!std.mem.eql(u8, g.type, "Room") and !std.mem.eql(u8, g.type, "Zone")) continue;
                add(fresh, .group, kv.key_ptr.*, g.name, g.as_light().state);
            }
        },
    }
    l.* = fresh.*;
}

var scratch: List = .{};

fn add(l: *List, kind: hue.Kind, id: []const u8, n: []const u8, state: hue.LightState) void {
    if (l.len == max_entries or id.len > 8) {
        log.warn("skipping {t} {s} `{s}`: list full or id too long", .{ kind, id, n });
        return;
    }
    const e = &l.items[l.len];
    e.* = .{ .kind = kind, .state = state, .id_len = @intCast(id.len) };
    @memcpy(e.id_buf[0..id.len], id);
    e.set_name(n);
    l.len += 1;
}

/// Re-reads one entry, e.g. the one on the settings page.
pub fn refresh_entry(ctx: Context, e: *Entry) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const fresh = try hue.get(arena.allocator(), ctx.bridge, ctx.user, e.target());
    e.state = fresh.state;
    e.set_name(fresh.name);
}

/// Sends `change` and, when the bridge accepts it, updates the local copy.
pub fn apply(ctx: Context, e: *Entry, change: hue.Change) void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    hue.set_state(arena.allocator(), ctx.bridge, ctx.user, e.target(), change) catch |err| {
        log.err("set {t} {s} failed: {t}", .{ e.kind, e.id(), err });
        return;
    };
    if (change.on) |v| e.state.on = v;
    if (change.bri) |v| e.state.bri = v;
    if (change.hue) |v| e.state.hue = v;
    if (change.sat) |v| e.state.sat = v;
    log.info("{t} {s} `{s}` -> {s}, bri {?}, hue {?}, sat {?}", .{
        e.kind, e.id(), e.name(), if (e.state.on) "on" else "off", e.state.bri, e.state.hue, e.state.sat,
    });
}

pub fn log_all() void {
    for ([_]hue.Kind{ .light, .group }) |kind| {
        const l = list(kind);
        log.info("{} {s}:", .{ l.len, if (kind == .light) "lights" else "rooms and zones" });
        for (l.slice()) |*e| log.info("  {s}: {s} ({s}{s})", .{
            e.id(), e.name(), if (e.state.on) "on" else "off", if (e.state.reachable) "" else ", unreachable",
        });
    }
}
