//! Touch navigation between the list page (lights / rooms) and the settings page of the
//! selected entry. Called from the main loop every tick; owns no task.
const std = @import("std");
const hue = @import("hue.zig");
const catalog = @import("catalog.zig");
const ui = @import("ui.zig");
const ft6206 = @import("screen").touch;
const settings = @import("settings.zig");

const log = std.log.scoped(.screen);

pub const Page = enum { list, settings };

pub var page: Page = .list;
var tab: ui.Tab = .lights;
var list_page: u8 = 0;
/// Set when navigation shows something whose state may be stale.
var refresh_wanted = false;
pub var touch_ok = false;

/// The Hue bridge handles about 10 commands per second per light. While a slider is being
/// dragged, the screen follows the finger and the bridge gets the latest value at most this
/// often, plus the final one on release.
const drag_send_ms = 150;
/// Capacitive panels drop the odd frame mid-touch. A release needs this many empty polls,
/// or one tap could act twice.
const release_polls = 3;

const Touch = struct {
    down: bool = false,
    control: ui.Control = .none,
    misses: u8 = 0,
    errors: u16 = 0,
    /// The latest slider value not yet sent to the bridge.
    pending: ?hue.Change = null,
    last_send: u64 = 0,
};
var touch: Touch = .{};

/// Opens the settings page of `e`, and remembers it for the next boot.
pub fn open(e: *const catalog.Entry) void {
    catalog.select(e);
    page = .settings;
    tab = if (e.kind == .light) .lights else .rooms;
    // The SCENES tab follows the room last opened, when it has scenes.
    if (e.kind == .group and has_scenes(e.id())) set_scene_room(e.id());
    refresh_wanted = true;
    var buf: [9]u8 = undefined;
    settings.set(.selected, std.fmt.bufPrint(&buf, "{c}{s}", .{ @as(u8, if (e.kind == .light) 'l' else 'g'), e.id() }) catch return);
}

fn kind_of(t: ui.Tab) ?hue.Kind {
    return switch (t) {
        .lights => .light,
        .rooms => .group,
        .scenes => null,
    };
}

fn tab_len(t: ui.Tab) usize {
    return if (kind_of(t)) |k| catalog.list(k).len else scene_view().len;
}

// ---- the SCENES tab's room filter ----

/// The room whose scenes the SCENES tab shows, by group id ("0" for LightScenes); empty
/// for all rooms. Kept by id: a refresh replaces the scene list.
var scene_room_buf: [8]u8 = undefined;
var scene_room_len: u8 = 0;

fn scene_room() []const u8 {
    return scene_room_buf[0..scene_room_len];
}

fn set_scene_room(id: []const u8) void {
    scene_room_len = @intCast(@min(id.len, scene_room_buf.len));
    @memcpy(scene_room_buf[0..scene_room_len], id[0..scene_room_len]);
    list_page = 0;
}

fn has_scenes(group: []const u8) bool {
    for (catalog.scenes.slice()) |*sc| if (std.mem.eql(u8, sc.group(), group)) return true;
    return false;
}

var view_buf: [catalog.max_scenes]u8 = undefined;

/// Indices into `catalog.scenes` of the scenes the filter lets through, in list order.
fn scene_view() []const u8 {
    if (scene_room_len > 0 and !has_scenes(scene_room())) scene_room_len = 0; // room gone
    var n: usize = 0;
    for (catalog.scenes.slice(), 0..) |*sc, i| {
        if (scene_room_len > 0 and !std.mem.eql(u8, sc.group(), scene_room())) continue;
        view_buf[n] = @intCast(i);
        n += 1;
    }
    return view_buf[0..n];
}

fn scene_room_label() []const u8 {
    if (scene_room_len == 0) return "ALL ROOMS";
    for (catalog.scenes.slice()) |*sc| if (std.mem.eql(u8, sc.group(), scene_room())) return sc.room();
    return "ALL ROOMS";
}

/// Steps the filter through "all rooms", then each room with scenes, in list order.
fn step_scene_room(forward: bool) void {
    // The rooms, each once, in the order they first appear.
    var rooms: [catalog.max_scenes][]const u8 = undefined;
    var n: usize = 0;
    for (catalog.scenes.slice()) |*sc| {
        const g = sc.group();
        for (rooms[0..n]) |r| {
            if (std.mem.eql(u8, r, g)) break;
        } else {
            rooms[n] = g;
            n += 1;
        }
    }
    // Position 0 is "all rooms", 1..n the rooms.
    var at: usize = 0;
    for (rooms[0..n], 1..) |r, k| {
        if (std.mem.eql(u8, r, scene_room())) at = k;
    }
    const next = if (forward) (at + 1) % (n + 1) else (at + n) % (n + 1);
    if (next == 0) {
        scene_room_len = 0;
        list_page = 0;
    } else set_scene_room(rooms[next - 1]);
}

/// True while a finger is on the panel: the main loop holds off its periodic refresh so a
/// drag isn't interrupted by a slow bridge read.
pub fn busy() bool {
    return touch.down;
}

/// True once after navigation, so the main loop refreshes what just came on screen.
pub fn take_refresh_request() bool {
    defer refresh_wanted = false;
    return refresh_wanted;
}

/// Re-reads what the screen shows: the open tab's list, or the selected entry.
pub fn refresh(ctx: catalog.Context) !void {
    switch (page) {
        .list => if (kind_of(tab)) |k| try catalog.refresh(ctx, k) else {
            // Scene rows show their room's name.
            if (catalog.groups.len == 0) try catalog.refresh(ctx, .group);
            try catalog.refresh_scenes(ctx);
        },
        .settings => if (catalog.selected()) |e| try catalog.refresh_entry(ctx, e),
    }
}

pub fn tick(ctx: catalog.Context, t: u64) void {
    if (touch_ok) poll(ctx, t);
    render();
}

fn render() void {
    if (page == .settings) {
        if (catalog.selected()) |e| return ui.render_settings(e.name(), preview(e.state));
        page = .list; // the entry disappeared from the bridge
    }
    const n = tab_len(tab);
    const pages = ui.page_count(tab, n);
    list_page = @min(list_page, pages - 1);
    const per = ui.rows_for(tab);
    const first = @as(usize, list_page) * per;
    const count = @min(per, n -| first);
    const view = scene_view();
    var rows: [ui.rows_per_page]ui.Row = undefined;
    for (rows[0..count], first..) |*row, i| row.* = if (kind_of(tab)) |k|
        .of_entry(&catalog.list(k).items[i])
    else
        .of_scene(&catalog.scenes.items[view[i]]);
    ui.render_list(tab, list_page, pages, rows[0..count], scene_room_label());
}

/// The entry as the screen should show it: a pending slider value wins.
fn preview(state: hue.LightState) hue.LightState {
    var v = state;
    const c = touch.pending orelse return v;
    if (c.on) |x| v.on = x;
    if (c.bri) |x| v.bri = x;
    if (c.hue) |x| v.hue = x;
    if (c.sat) |x| v.sat = x;
    return v;
}

fn poll(ctx: catalog.Context, t: u64) void {
    const point = ft6206.read() catch |err| {
        touch.errors += 1;
        if (touch.errors == 50) {
            log.err("touch controller keeps failing ({t}): touch disabled", .{err});
            touch_ok = false;
        }
        return;
    };
    touch.errors = 0;

    if (point) |p| {
        touch.misses = 0;
        if (!touch.down) {
            touch.down = true;
            // Everything acts on touch-down; only sliders follow the drag.
            touch.control = switch (page) {
                .list => blk: {
                    list_touched(ctx, p);
                    break :blk .none;
                },
                .settings => settings_touched(ctx, p),
            };
        }
        // Dimming or recolouring something that's off turns it on: the bridge rejects
        // bri, hue and sat on an off light anyway.
        switch (touch.control) {
            .brightness => touch.pending = .{ .on = true, .bri = ui.brightness_at(p.x) },
            .hue => touch.pending = .{ .on = true, .hue = ui.hue_at(p.x), .sat = 254 },
            .none, .back, .power, .white => {},
        }
    } else if (touch.down) {
        touch.misses += 1;
        if (touch.misses >= release_polls) {
            touch.down = false;
            touch.control = .none;
        }
    }

    const c = touch.pending orelse return;
    if (touch.down and t - touch.last_send < drag_send_ms) return;
    touch.pending = null;
    const e = catalog.selected() orelse return;
    if (is_noop(e.state, c)) return;
    catalog.apply(ctx, e, c);
    touch.last_send = t;
}

fn list_touched(ctx: catalog.Context, p: ft6206.Point) void {
    const n = tab_len(tab);
    switch (ui.list_hit(p, tab, list_page, n)) {
        .none => {},
        .filter_prev => step_scene_room(false),
        .filter_next => step_scene_room(true),
        .tab => |t| if (t != tab) {
            tab = t;
            list_page = 0;
            refresh_wanted = true;
        },
        .prev => list_page -|= 1,
        .next => if (list_page + 1 < ui.page_count(tab, n)) {
            list_page += 1;
        },
        // A scene row has one action, wherever it's tapped.
        .toggle => |i| if (kind_of(tab)) |k| {
            const e = &catalog.list(k).items[i];
            catalog.apply(ctx, e, .{ .on = !e.state.on });
        } else catalog.recall(ctx, &catalog.scenes.items[scene_view()[i]]),
        .open => |i| if (kind_of(tab)) |k|
            open(&catalog.list(k).items[i])
        else
            catalog.recall(ctx, &catalog.scenes.items[scene_view()[i]]),
    }
}

fn settings_touched(ctx: catalog.Context, p: ft6206.Point) ui.Control {
    const e = catalog.selected() orelse return .none;
    const control = ui.control_at(p, e.state);
    switch (control) {
        .back => {
            page = .list;
            refresh_wanted = true;
        },
        .power => catalog.apply(ctx, e, .{ .on = !e.state.on }),
        .white => catalog.apply(ctx, e, .{ .on = true, .sat = 0 }),
        .none, .brightness, .hue => {},
    }
    return control;
}

fn is_noop(s: hue.LightState, c: hue.Change) bool {
    return (c.on == null or c.on.? == s.on) and
        (c.bri == null or std.meta.eql(c.bri, s.bri)) and
        (c.hue == null or std.meta.eql(c.hue, s.hue)) and
        (c.sat == null or std.meta.eql(c.sat, s.sat));
}
