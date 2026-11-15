//! The bridge's lights and rooms/zones as last read, plus which one is selected.
//!
//! Fixed-size copies, so nothing points into the parser's arena or the shared response
//! buffer once a refresh returns. Owned by the UI task: the bridge task reads into its own
//! copies and hands them over (see bridge.zig).
const std = @import("std");
const hue = @import("hue.zig");
/// The bridge's scene record, as `scenes.zig` reads it (catalog.Scene is the kept copy).
const SceneInfo = @import("scenes.zig").Scene;

const log = std.log.scoped(.catalog);

/// Per kind.
pub const max_entries = 24;
pub const max_members = 16;

pub const Entry = struct {
    kind: hue.Kind,
    id_buf: [8]u8 = undefined,
    id_len: u8 = 0,
    /// Hue names are at most 32 bytes.
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    state: hue.LightState,
    /// A room or zone's lights, by id (the bridge's light ids are numbers).
    members: [max_members]u16 = undefined,
    member_len: u8 = 0,

    pub fn id(e: *const Entry) []const u8 {
        return e.id_buf[0..e.id_len];
    }

    pub fn has_member(e: *const Entry, light: *const Entry) bool {
        const n = std.fmt.parseInt(u16, light.id(), 10) catch return false;
        return std.mem.indexOfScalar(u16, e.members[0..e.member_len], n) != null;
    }

    pub fn set_members(e: *Entry, ids: []const []const u8) void {
        e.member_len = 0;
        for (ids) |s| {
            if (e.member_len == max_members) break;
            e.members[e.member_len] = std.fmt.parseInt(u16, s, 10) catch continue;
            e.member_len += 1;
        }
    }

    pub fn name(e: *const Entry) []const u8 {
        return e.name_buf[0..e.name_len];
    }

    pub fn target(e: *const Entry) hue.Target {
        return .{ .kind = e.kind, .id = e.id() };
    }

    /// A fresh read of one light or group, outside any list.
    pub fn make(kind: hue.Kind, entry_id: []const u8, n: []const u8, state: hue.LightState) Entry {
        var e: Entry = .{ .kind = kind, .state = state };
        e.id_len = @intCast(@min(entry_id.len, e.id_buf.len));
        @memcpy(e.id_buf[0..e.id_len], entry_id[0..e.id_len]);
        e.set_name(n);
        return e;
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

pub fn add(l: *List, kind: hue.Kind, id: []const u8, n: []const u8, state: hue.LightState) void {
    if (l.len == max_entries or id.len > 8) {
        log.warn("skipping {t} {s} `{s}`: list full or id too long", .{ kind, id, n });
        return;
    }
    l.items[l.len] = .make(kind, id, n, state);
    l.len += 1;
}

pub var lights: List = .{};

/// No bridge: changes only update the local copies, reads keep what's there (-Ddemo).
pub var offline = false;
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

// ---- what the bridge task sends back, applied here ----
//
// The bridge task (bridge.zig) does the requests and never touches these globals: the UI
// task applies what it read, so the screen, the web remote and the LED read one copy with
// no lock.

/// Replaces `kind`'s list with a fresh read.
pub fn apply_list(kind: hue.Kind, fresh: *const List) void {
    list(kind).* = fresh.*;
}

/// Updates the entry that `fresh` was read from, if it's still listed.
pub fn apply_entry(fresh: *const Entry) void {
    const e = list(fresh.kind).find(fresh.id()) orelse return;
    e.state = fresh.state;
    e.set_name(fresh.name());
}

/// Updates the local copy once the bridge took `change`.
pub fn apply_change(e: *Entry, change: hue.Change) void {
    if (change.on) |v| e.state.on = v;
    if (change.bri) |v| e.state.bri = v;
    if (change.hue) |v| e.state.hue = v;
    if (change.sat) |v| e.state.sat = v;
    log.info("{t} {s} `{s}` -> {s}, bri {?}, hue {?}, sat {?}", .{
        e.kind,      e.id(),      e.name(),    if (e.state.on) "on" else "off",
        e.state.bri, e.state.hue, e.state.sat,
    });
}

/// Every light off (group 0 is all of them), once the bridge took it.
pub fn apply_all_off() void {
    for ([_]*List{ &lights, &groups }) |l| for (l.slice()) |*e| {
        e.state.on = false;
    };
    log.info("all lights off", .{});
}

/// A fixed-size copy of an id, for what outlives the entry it came from: a page on the
/// screen, a change on its way to the bridge.
pub const Id = struct {
    buf: [16]u8 = @splat(0),
    len: u8 = 0,

    pub fn of(s: []const u8) Id {
        var r: Id = .{};
        r.len = @intCast(@min(s.len, r.buf.len));
        @memcpy(r.buf[0..r.len], s[0..r.len]);
        return r;
    }

    pub fn get(id: *const Id) []const u8 {
        return id.buf[0..id.len];
    }
};

/// A light or a room by id, not by pointer: a refresh can add, drop or move entries.
pub const Ref = struct {
    kind: hue.Kind,
    id: Id,

    pub fn of(e: *const Entry) Ref {
        return .{ .kind = e.kind, .id = .of(e.id()) };
    }

    pub fn entry(r: *const Ref) ?*Entry {
        return list(r.kind).find(r.id.get());
    }

    pub fn is(r: *const Ref, e: *const Entry) bool {
        return r.kind == e.kind and std.mem.eql(u8, r.id.get(), e.id());
    }

    pub fn target(r: *const Ref) hue.Target {
        return .{ .kind = r.kind, .id = r.id.get() };
    }
};

// ---- scenes ----

/// A bridge has about ten per room, from the app's gallery.
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
    /// What it looks like, read from the scene's light states on first use (see `look_of`).
    look: union(enum) { unknown, dark, lit: hue.Look } = .unknown,

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

    pub fn add(l: *SceneList, info: SceneInfo) void {
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

/// The scene last recalled from here, by id; the list shows it highlighted.
var recalled_buf: [16]u8 = undefined;
var recalled_len: usize = 0;

pub fn is_recalled(sc: *const Scene) bool {
    return recalled_len > 0 and std.mem.eql(u8, sc.id(), recalled_buf[0..recalled_len]);
}

/// Replaces the scene list with a fresh read, sorted by room, then name. Room names come
/// from `groups`, so apply those first.
pub fn apply_scenes(fresh: *SceneList) void {
    if (fresh.dropped > 0) log.warn("{} scenes left out: the list holds {}", .{ fresh.dropped, max_scenes });
    std.mem.sort(Scene, fresh.slice(), {}, scene_less);
    // Keep the looks already read: they cost one request per scene.
    for (fresh.slice()) |*sc| for (scenes.slice()) |*old| if (std.mem.eql(u8, old.id(), sc.id())) {
        sc.look = old.look;
        break;
    };
    scenes = fresh.*;
}

/// What scene `id` looks like, as the bridge task read it. Null when it couldn't: shown
/// dark, so the screen doesn't ask again every tick.
pub fn apply_look(id: []const u8, look: ?hue.Look) void {
    const sc = find_scene(id) orelse return;
    sc.look = if (look) |l| .{ .lit = l } else .dark;
}

fn scene_less(_: void, a: Scene, b: Scene) bool {
    const ra = a.room();
    const rb = b.room();
    if (!std.mem.eql(u8, ra, rb)) return std.ascii.lessThanIgnoreCase(ra, rb);
    return std.ascii.lessThanIgnoreCase(a.name(), b.name());
}

/// Marks scene `id` as the one recalled from here, once the bridge took it. Offline
/// (-Ddemo), nothing re-reads the room: it gets the scene's look directly.
pub fn apply_recall(id: []const u8) void {
    const sc = find_scene(id) orelse return;
    recalled_len = sc.id_len;
    @memcpy(recalled_buf[0..recalled_len], sc.id());
    log.info("scene `{s}` recalled on `{s}`", .{ sc.name(), sc.room() });
    if (offline) if (groups.find(sc.group())) |g| switch (sc.look) {
        .lit => |l| {
            const hs = @import("screen").colour.rgb_to_hue_sat(l.rgb);
            g.state = .{ .on = true, .bri = l.bri, .hue = hs.hue, .sat = hs.sat };
        },
        .dark => g.state.on = false,
        .unknown => {},
    };
}

pub fn find_scene(id: []const u8) ?*Scene {
    for (scenes.slice()) |*sc| if (std.mem.eql(u8, sc.id(), id)) return sc;
    return null;
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
