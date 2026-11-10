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

// ---- scenes ----

/// Eight pages of six.
/// Sixteen pages of six. A bridge has about ten per room, from the app's gallery.
pub const max_scenes = 96;

pub const Scene = struct {
    /// Scene ids are 15-16 characters.
    id_buf: [16]u8 = undefined,
    id_len: u8 = 0,
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    /// Empty for a LightScene, which belongs to no room.
    group_buf: [8]u8 = undefined,
    group_len: u8 = 0,

    pub fn id(s: *const Scene) []const u8 {
        return s.id_buf[0..s.id_len];
    }

    pub fn name(s: *const Scene) []const u8 {
        return s.name_buf[0..s.name_len];
    }

    /// The group to recall it on: its room or zone, or 0 (all lights).
    pub fn group(s: *const Scene) []const u8 {
        return if (s.group_len == 0) "0" else s.group_buf[0..s.group_len];
    }

    /// The room or zone's name, as last read; "" when unknown.
    pub fn room(s: *const Scene) []const u8 {
        if (s.group_len == 0) return "ALL LIGHTS";
        const g = groups.find(s.group_buf[0..s.group_len]) orelse return "";
        return g.name();
    }
};

pub const SceneList = struct {
    items: [max_scenes]Scene = undefined,
    len: usize = 0,
    /// Scenes left out because the list was full.
    dropped: usize = 0,

    pub fn slice(l: *SceneList) []Scene {
        return l.items[0..l.len];
    }

    pub fn add(l: *SceneList, info: @import("scenes.zig").Scene) void {
        if (info.recycle or info.name.len == 0) return;
        const group_id = info.group orelse "";
        if (l.len == max_scenes) {
            l.dropped += 1;
            return;
        }
        if (info.id.len > 16 or group_id.len > 8) {
            log.warn("skipping scene {s} `{s}`: id too long", .{ info.id, info.name });
            return;
        }
        const sc = &l.items[l.len];
        sc.* = .{ .id_len = @intCast(info.id.len), .group_len = @intCast(group_id.len) };
        @memcpy(sc.id_buf[0..info.id.len], info.id);
        @memcpy(sc.group_buf[0..group_id.len], group_id);
        const trimmed = std.mem.trimEnd(u8, info.name, " ");
        sc.name_len = @intCast(@min(trimmed.len, sc.name_buf.len));
        @memcpy(sc.name_buf[0..sc.name_len], trimmed[0..sc.name_len]);
        l.len += 1;
    }
};

pub var scenes: SceneList = .{};
var scene_scratch: SceneList = .{};

/// The scene last recalled from here, by id; the list shows it highlighted.
var recalled_buf: [16]u8 = undefined;
var recalled_len: usize = 0;

pub fn is_recalled(sc: *const Scene) bool {
    return recalled_len > 0 and std.mem.eql(u8, sc.id(), recalled_buf[0..recalled_len]);
}

/// Replaces the scene list, sorted by room, then name. Room names come from `groups`, so
/// refresh those first.
pub fn refresh_scenes(ctx: Context) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const fresh = &scene_scratch;
    fresh.len = 0;
    fresh.dropped = 0;
    try hue.get_scenes(arena.allocator(), ctx.bridge, ctx.user, fresh);
    if (fresh.dropped > 0) log.warn("{} scenes left out: the list holds {}", .{ fresh.dropped, max_scenes });
    std.mem.sort(Scene, fresh.slice(), {}, scene_less);
    scenes = fresh.*;
}

fn scene_less(_: void, a: Scene, b: Scene) bool {
    const ra = a.room();
    const rb = b.room();
    if (!std.mem.eql(u8, ra, rb)) return std.ascii.lessThanIgnoreCase(ra, rb);
    return std.ascii.lessThanIgnoreCase(a.name(), b.name());
}

/// Recalls `sc` on its room. The lights' new states show up with the next refresh.
pub fn recall(ctx: Context, sc: *const Scene) void {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    hue.recall_scene(arena.allocator(), ctx.bridge, ctx.user, sc.group(), sc.id()) catch |err| {
        log.err("recall scene {s} failed: {t}", .{ sc.id(), err });
        return;
    };
    recalled_len = sc.id_len;
    @memcpy(recalled_buf[0..recalled_len], sc.id());
    log.info("scene `{s}` recalled on `{s}`", .{ sc.name(), sc.room() });
}

pub fn log_all() void {
    for ([_]hue.Kind{ .light, .group }) |kind| {
        const l = list(kind);
        log.info("{} {s}:", .{ l.len, if (kind == .light) "lights" else "rooms and zones" });
        for (l.slice()) |*e| log.info("  {s}: {s} ({s}{s})", .{
            e.id(), e.name(), if (e.state.on) "on" else "off", if (e.state.reachable) "" else ", unreachable",
        });
    }
    log.info("{} scenes:", .{scenes.len});
    for (scenes.slice()) |*sc| log.info("  {s}: {s} ({s})", .{ sc.id(), sc.name(), sc.room() });
}
