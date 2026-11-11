//! The list UI's navigation and touch handling. Called from the main loop every tick; owns
//! no task.
//!
//!   home (ROOMS | LIGHTS)  ->  a room   ->  its SCENES   (tap: recall)
//!                                       ->  its LIGHTS   ->  a light
//!                          ->  a light
//!
//! `<` or a swipe right on the first page goes back. Lists page with `<` `>` or a swipe.
//!
//! Touches act on release, so a press can be shown (the row lights up under the finger)
//! and a finger that slides off, or turns out to be a swipe, cancels it. Changes are drawn
//! at once and sent after the frame (see `Outgoing`): the screen doesn't wait for the bridge,
//! and goes back to what it was if the bridge refuses.
const std = @import("std");
const hue = @import("hue.zig");
const catalog = @import("catalog.zig");
const ui = @import("ui.zig");
const colourfield = @import("colourfield.zig");
const backlight = @import("backlight.zig");
const ft6206 = @import("screen").touch;
const settings = @import("settings.zig");
const Point = ft6206.Point;

const log = std.log.scoped(.screen);

pub var touch_ok = false;
/// The list UI can ask before forgetting the bridge (see `ask_forget`).
pub const can_confirm = true;

// ---- gestures ----

/// The Hue bridge handles about 10 commands per second per light. While the brightness is
/// slid, the screen follows the finger and the bridge gets the latest value at most this
/// often, plus the final one on release.
const drag_send_ms = 150;
/// Capacitive panels drop the odd frame mid-touch. A release needs this many empty polls,
/// or one tap could act twice.
const release_polls = 3;
const swipe_px = 32;
/// Movement that turns a press into a slide (on the tile) or cancels it (anywhere else).
const still_px = 12;
const hold_ms = 600;
/// After a change, the bridge reports the old state for a moment: refreshes wait this long.
const settle_ms = 1500;
const banner_ms = 3000;

// ---- where we are ----

const Id = struct {
    buf: [16]u8 = @splat(0),
    len: u8 = 0,

    fn of(s: []const u8) Id {
        var r: Id = .{};
        r.len = @intCast(@min(s.len, r.buf.len));
        @memcpy(r.buf[0..r.len], s[0..r.len]);
        return r;
    }

    fn get(id: *const Id) []const u8 {
        return id.buf[0..id.len];
    }
};

const Ref = struct {
    kind: hue.Kind,
    id: Id,

    fn of(e: *const catalog.Entry) Ref {
        return .{ .kind = e.kind, .id = .of(e.id()) };
    }

    fn entry(r: *const Ref) ?*catalog.Entry {
        return catalog.list(r.kind).find(r.id.get());
    }

    fn is(r: *const Ref, e: *const catalog.Entry) bool {
        return r.kind == e.kind and std.mem.eql(u8, r.id.get(), e.id());
    }
};

/// A page, with the page number for lists. Kept by id: a refresh can drop or reorder entries.
const View = union(enum) {
    home: struct { tab: ui.Tab, page: u8 = 0 },
    entry: Ref,
    scenes: struct { room: Id, page: u8 = 0 },
    lights: struct { room: Id, page: u8 = 0 },
};

var stack: [4]View = @splat(.{ .home = .{ .tab = .rooms } });
var depth: usize = 1;

fn top() *View {
    return &stack[depth - 1];
}

const Overlay = enum { none, colour, confirm };
var overlay: Overlay = .none;

/// Set when navigation shows something whose state may be stale.
var refresh_wanted = false;
/// The scene list is read when the SCENES page opens, not every refresh: it's big.
var scenes_stale = true;
var now_t: u64 = 0;

fn push(v: View) void {
    if (depth == stack.len) {
        // Deepest is home -> room -> lights -> light: never reached, but keep the top.
        std.mem.copyForwards(View, stack[1 .. stack.len - 1], stack[2..stack.len]);
        depth -= 1;
    }
    stack[depth] = v;
    depth += 1;
    entered();
}

fn pop() void {
    if (depth > 1) depth -= 1;
    entered();
}

fn entered() void {
    refresh_wanted = true;
    switch (top().*) {
        .entry => |r| if (r.entry()) |e| select(e),
        .scenes => scenes_stale = true,
        else => {},
    }
}

/// The web remote and the LED follow the light or room open last, and it's reopened at boot.
fn select(e: *const catalog.Entry) void {
    catalog.select(e);
    var buf: [9]u8 = undefined;
    settings.set(.selected, std.fmt.bufPrint(&buf, "{c}{s}", .{ @as(u8, if (e.kind == .light) 'l' else 'g'), e.id() }) catch return);
}

/// Opens the page of `e` (at boot: the one open last), above the home list it belongs to.
pub fn open(e: *const catalog.Entry) void {
    depth = 1;
    stack[0] = .{ .home = .{ .tab = if (e.kind == .light) .lights else .rooms } };
    push(.{ .entry = .of(e) });
}

/// True while a finger is on the panel: the main loop holds off its periodic refresh so a
/// slide isn't interrupted by a slow bridge read.
pub fn busy() bool {
    return touch.down;
}

/// True once after navigation, so the main loop refreshes what just came on screen.
pub fn take_refresh_request() bool {
    defer refresh_wanted = false;
    return refresh_wanted;
}

/// Re-reads what the screen shows. Skipped just after a change: the bridge would still
/// report the old state, and the screen would flick back.
pub fn refresh(ctx: catalog.Context) !void {
    if (outgoing != null or now_t -| last_send < settle_ms) return;
    switch (top().*) {
        .home => |h| try catalog.refresh(ctx, if (h.tab == .rooms) .group else .light),
        .entry => |r| if (r.entry()) |e| try catalog.refresh_entry(ctx, e),
        .scenes => if (scenes_stale) {
            try catalog.refresh_scenes(ctx);
            scenes_stale = false;
        },
        .lights => try catalog.refresh(ctx, .light),
    }
}

// ---- the bridge: what failed ----

var refresh_failures: u8 = 0;
var banner_until: u64 = 0;

/// The main loop reports each refresh; two failures in a row show NO BRIDGE until one works.
pub fn report_refresh(ok: bool) void {
    refresh_failures = if (ok) 0 else refresh_failures +| 1;
}

fn banner_text() ?[]const u8 {
    if (refresh_failures >= 2) return "BRIDGE OFFLINE";
    if (now_t < banner_until) return "NOT SENT: NO ANSWER";
    return null;
}

// ---- forgetting the bridge (BOOT held) ----

var forget_confirmed = false;

/// Shows FORGET / CANCEL. A tap on FORGET makes `take_forget` true.
pub fn ask_forget() void {
    if (overlay == .confirm) return;
    overlay = .confirm;
    // A finger already on the glass doesn't answer.
    touch = .{ .down = touch.down, .swallow = touch.down, .errors = touch.errors };
}

pub fn take_forget() bool {
    return forget_confirmed;
}

// ---- changes: drawn now, sent after the frame ----

const Outgoing = union(enum) {
    change: struct { ref: Ref, change: hue.Change },
    recall: Id,
};
var outgoing: ?Outgoing = null;
var last_send: u64 = 0;

fn queue_change(e: *const catalog.Entry, c: hue.Change) void {
    if (outgoing) |*o| if (o.* == .change and o.change.ref.is(e)) {
        const m = &o.change.change;
        if (c.on) |v| m.on = v;
        if (c.bri) |v| m.bri = v;
        if (c.hue) |v| m.hue = v;
        if (c.sat) |v| m.sat = v;
        return;
    };
    // Something else waiting (two taps within a tick): it goes first.
    if (outgoing != null) flush(ctx_, true);
    outgoing = .{ .change = .{ .ref = .of(e), .change = c } };
}

/// The context of the tick, so `queue_change` can flush.
var ctx_: catalog.Context = undefined;

fn flush(ctx: catalog.Context, force: bool) void {
    const o = outgoing orelse return;
    if (!force and touch.down and touch.mode == .slide and now_t - last_send < drag_send_ms) return;
    outgoing = null;
    last_send = now_t;
    const ok = switch (o) {
        .change => |c| blk: {
            const e = c.ref.entry() orelse break :blk true;
            if (is_noop(e.state, c.change)) break :blk true;
            break :blk catalog.apply(ctx, e, c.change);
        },
        .recall => |id| if (catalog.find_scene(id.get())) |sc| catalog.recall(ctx, sc) else true,
    };
    if (!ok) banner_until = now_t + banner_ms;
}

/// The entry as the screen should show it: a change on its way wins.
fn preview(e: *const catalog.Entry) hue.LightState {
    var v = e.state;
    const o = outgoing orelse return v;
    if (o != .change or !o.change.ref.is(e)) return v;
    const c = o.change.change;
    if (c.on) |x| v.on = x;
    if (c.bri) |x| v.bri = x;
    if (c.hue) |x| v.hue = x;
    if (c.sat) |x| v.sat = x;
    return v;
}

fn is_noop(s: hue.LightState, c: hue.Change) bool {
    return (c.on == null or c.on.? == s.on) and
        (c.bri == null or std.meta.eql(c.bri, s.bri)) and
        (c.hue == null or std.meta.eql(c.hue, s.hue)) and
        (c.sat == null or std.meta.eql(c.sat, s.sat));
}

// ---- tick ----

pub fn tick(ctx: catalog.Context, t: u64) void {
    now_t = t;
    ctx_ = ctx;
    if (touch_ok) poll(t);
    drop_gone();
    render();
    flush(ctx, false);
    // Scene colours come from one request each: one per tick, for those on screen.
    if (overlay == .none and top().* == .scenes and !touch.down) for (page_scenes()) |i| {
        if (catalog.scenes.items[i].look == .unknown) {
            catalog.load_look(ctx, &catalog.scenes.items[i]);
            break;
        }
    };
}

/// Drops pages whose entry is gone from the bridge.
fn drop_gone() void {
    while (depth > 1) {
        const gone = switch (top().*) {
            .entry => |r| r.entry() == null,
            .scenes => |s| catalog.groups.find(s.room.get()) == null,
            .lights => |s| catalog.groups.find(s.room.get()) == null,
            .home => false,
        };
        if (!gone) break;
        pop();
    }
}

// ---- the pages' contents ----

var index_buf: [catalog.max_scenes]u8 = undefined;

/// The indices of what the list page `v` lists: into its kind's list, or into the scenes.
fn list_items(v: View) []const u8 {
    var n: usize = 0;
    switch (v) {
        .home => |h| {
            const l = catalog.list(if (h.tab == .rooms) .group else .light);
            for (0..l.len) |i| {
                index_buf[n] = @intCast(i);
                n += 1;
            }
        },
        .lights => |s| if (catalog.groups.find(s.room.get())) |room| {
            for (catalog.lights.slice(), 0..) |*light, i| if (room.has_member(light)) {
                index_buf[n] = @intCast(i);
                n += 1;
            };
        },
        .scenes => |s| for (catalog.scenes.slice(), 0..) |*sc, i| {
            if (!std.mem.eql(u8, sc.group(), s.room.get())) continue;
            index_buf[n] = @intCast(i);
            n += 1;
        },
        .entry => {},
    }
    return index_buf[0..n];
}

fn page_of(v: *View) ?*u8 {
    return switch (v.*) {
        .home => |*h| &h.page,
        .scenes => |*s| &s.page,
        .lights => |*s| &s.page,
        .entry => null,
    };
}

fn list_entries(v: View) ?*catalog.List {
    return switch (v) {
        .home => |h| catalog.list(if (h.tab == .rooms) .group else .light),
        .lights => &catalog.lights,
        else => null,
    };
}

/// The scenes on the SCENES page on screen.
fn page_scenes() []const u8 {
    const v = top().*;
    const all = list_items(v);
    const page: usize = page_of(top()).?.*;
    const first = @min(page * ui.rows_per_page, all.len);
    return all[first..@min(first + ui.rows_per_page, all.len)];
}

/// The list page's header, page and rows.
const ListPage = struct {
    header: ui.Header,
    page: u8,
    pages: u8,
    /// Indices of this page's rows (see `list_items`).
    items: []const u8,
};

fn list_page(v: *View) ListPage {
    const all = list_items(v.*);
    const page = page_of(v).?;
    const pages = ui.page_count(all.len);
    page.* = @min(page.*, pages - 1);
    const first = @as(usize, page.*) * ui.rows_per_page;
    const header: ui.Header = switch (v.*) {
        .home => |h| .{ .tabs = h.tab },
        .scenes => |s| .{ .title = .{ .name = room_name(s.room.get()), .label = "SCENES" } },
        .lights => |s| .{ .title = .{ .name = room_name(s.room.get()), .label = "LIGHTS" } },
        .entry => unreachable,
    };
    return .{ .header = header, .page = page.*, .pages = pages, .items = all[first..@min(first + ui.rows_per_page, all.len)] };
}

fn room_name(id: []const u8) []const u8 {
    return if (catalog.groups.find(id)) |g| g.name() else "";
}

fn room_counts(room: *const catalog.Entry) struct { scenes: usize, lights: usize } {
    var scenes: usize = 0;
    for (catalog.scenes.slice()) |*sc| {
        if (std.mem.eql(u8, sc.group(), room.id())) scenes += 1;
    }
    var lights: usize = 0;
    for (catalog.lights.slice()) |*l| {
        if (room.has_member(l)) lights += 1;
    }
    return .{ .scenes = scenes, .lights = lights };
}

fn entry_view(e: *const catalog.Entry) ui.EntryView {
    return .{
        .name = e.name(),
        .state = preview(e),
        .room = if (e.kind == .group) blk: {
            const c = room_counts(e);
            break :blk .{ .scenes = c.scenes, .lights = c.lights };
        } else null,
    };
}

fn row_of(v: View, i: u8) ui.Row {
    if (v == .scenes) {
        const sc = &catalog.scenes.items[i];
        const recalled = catalog.is_recalled(sc) or (outgoing != null and outgoing.? == .recall and std.mem.eql(u8, outgoing.?.recall.get(), sc.id()));
        return .{
            .name = sc.name(),
            .lead = .{ .swatch = switch (sc.look) {
                .unknown => .{ .r = 44, .g = 44, .b = 50 },
                .dark => .{ .r = 20, .g = 20, .b = 24 },
                .lit => |l| l.rgb,
            } },
            .trail = if (recalled) .mark else .none,
        };
    }
    const e = &list_entries(v).?.items[i];
    const s = preview(e);
    return .{
        .name = e.name(),
        .lead = .{ .toggle = .{ .on = s.on, .reachable = s.reachable, .rgb = ui.colour_of(s) } },
    };
}

// ---- drawing ----

fn render() void {
    switch (overlay) {
        .colour => return colourfield.render(if (touch.down and !touch.swallow) touch.last else null),
        .confirm => return ui.render_confirm(if (touch.mode == .press) touch.hit else .none),
        .none => {},
    }
    const pressed = if (touch.down and touch.mode == .press) touch.hit else .none;
    const v = top();
    switch (v.*) {
        .entry => |r| ui.render_entry(entry_view(r.entry().?), pressed),
        else => {
            const lp = list_page(v);
            var rows: [ui.rows_per_page]ui.Row = undefined;
            for (lp.items, 0..) |i, k| rows[k] = row_of(v.*, i);
            ui.render_list(.{
                .header = lp.header,
                .page = lp.page,
                .pages = lp.pages,
                .rows = rows[0..lp.items.len],
                .empty = switch (v.*) {
                    .home => |h| if (h.tab == .rooms) "NO ROOMS" else "NO LIGHTS",
                    else => "NOTHING HERE",
                },
            }, pressed);
        },
    }
    ui.render_banner(banner_text());
}

// ---- touch ----

const Touch = struct {
    down: bool = false,
    /// The touch woke the backlight, or was already down when a dialog opened: ignored.
    swallow: bool = false,
    start: Point = .{ .x = 0, .y = 0 },
    last: Point = .{ .x = 0, .y = 0 },
    start_t: u64 = 0,
    misses: u8 = 0,
    errors: u16 = 0,
    hit: ui.Hit = .none,
    mode: enum { press, cancelled, swipe, slide } = .press,
    start_bri: i32 = 0,
};
var touch: Touch = .{};

fn hit_test(p: Point) ui.Hit {
    if (overlay == .confirm) return ui.confirm_hit(p);
    const v = top();
    return switch (v.*) {
        .entry => |r| ui.entry_hit(p, entry_view(r.entry().?)),
        else => blk: {
            const lp = list_page(v);
            break :blk ui.list_hit(p, lp.header, lp.page, lp.pages, lp.items.len);
        },
    };
}

fn poll(t: u64) void {
    const point = ft6206.read() catch |err| {
        touch.errors += 1;
        if (touch.errors == 50) {
            log.err("touch controller keeps failing ({t}): touch disabled", .{err});
            touch_ok = false;
        }
        return;
    };
    touch.errors = 0;

    const p = point orelse {
        if (touch.down) {
            touch.misses += 1;
            if (touch.misses >= release_polls) release();
        }
        return;
    };
    touch.misses = 0;
    if (!touch.down) {
        const woke = backlight.wake(t);
        touch = .{ .down = true, .start = p, .last = p, .start_t = t, .swallow = woke };
        if (woke or overlay == .colour) return;
        touch.hit = hit_test(p);
        if (top().* == .entry) if (top().entry.entry()) |e| {
            const s = preview(e);
            touch.start_bri = if (s.on) s.bri orelse 254 else 0;
        };
        return;
    }
    _ = backlight.wake(t);
    touch.last = p;
    if (touch.swallow or overlay != .none) return;

    const dx = @as(i32, p.x) - touch.start.x;
    const dy = @as(i32, p.y) - touch.start.y;
    const is_swipe = @abs(dx) > swipe_px and @abs(dx) > 2 * @abs(dy);
    switch (touch.mode) {
        .press => {
            const moved = @abs(dx) > still_px or @abs(dy) > still_px;
            if (touch.hit == .tile) {
                const e = top().entry.entry() orelse return;
                if (@abs(dx) > still_px and @abs(dx) >= @abs(dy) and e.state.bri != null) {
                    touch.mode = .slide;
                } else if (!moved and t - touch.start_t >= hold_ms and e.state.hue != null) {
                    // Press and hold: straight into the colour field, finger still down.
                    open_colour();
                } else if (moved) touch.mode = .cancelled;
            } else if (is_swipe) {
                touch.mode = .swipe;
            } else if (moved) touch.mode = .cancelled;
        },
        // A finger that has moved too far for a tap can still turn out to be a swipe.
        .cancelled => if (touch.hit != .tile and is_swipe) {
            touch.mode = .swipe;
        },
        .slide => {
            const e = top().entry.entry() orelse return;
            // Sliding an off light right turns it on from the bottom.
            const bri = std.math.clamp(touch.start_bri + ui.slide_delta(dx), 1, 254);
            queue_change(e, .{ .on = true, .bri = @intCast(bri) });
        },
        .swipe => {},
    }
}

fn open_colour() void {
    overlay = .colour;
    colourfield.reset();
}

fn release() void {
    const t = touch;
    touch = .{ .errors = t.errors };
    if (t.swallow) return;
    switch (overlay) {
        .colour => {
            if (!colourfield.on_strip(t.last)) if (current_entry()) |e| queue_change(e, colourfield.colour_at(t.last));
            overlay = .none;
            ui.invalidate();
            return;
        },
        .confirm => {
            if (t.mode == .press and std.meta.eql(ui.confirm_hit(t.last), t.hit)) switch (t.hit) {
                .confirm_yes => forget_confirmed = true,
                .confirm_no => {
                    overlay = .none;
                    ui.invalidate();
                },
                else => {},
            };
            return;
        },
        .none => {},
    }
    switch (t.mode) {
        .press => if (std.meta.eql(hit_test(t.last), t.hit)) act(t.hit),
        .swipe => swipe(t.last.x < t.start.x),
        .slide => flush(ctx_, true),
        .cancelled => {},
    }
}

fn current_entry() ?*catalog.Entry {
    return if (top().* == .entry) top().entry.entry() else null;
}

/// Left: the next page. Right: the previous one, or back from the first.
fn swipe(left: bool) void {
    const v = top();
    const page = page_of(v) orelse {
        if (!left) pop();
        return;
    };
    const pages = ui.page_count(list_items(v.*).len);
    if (left) {
        if (page.* + 1 < pages) page.* += 1;
    } else if (page.* > 0) {
        page.* -= 1;
    } else if (depth > 1) pop();
}

fn act(hit: ui.Hit) void {
    const v = top();
    switch (hit) {
        .none, .confirm_yes, .confirm_no => {},
        .tab => |tab| if (v.home.tab != tab) {
            v.* = .{ .home = .{ .tab = tab } };
            refresh_wanted = true;
        },
        .back => pop(),
        .prev => page_of(v).?.* -|= 1,
        .next => page_of(v).?.* += 1,
        .row_switch, .row_open => |r| {
            const item = list_page(v).items[r];
            switch (v.*) {
                .scenes => outgoing_recall(&catalog.scenes.items[item]),
                else => {
                    const e = &list_entries(v.*).?.items[item];
                    if (hit == .row_switch)
                        queue_change(e, .{ .on = !preview(e).on })
                    else
                        push(.{ .entry = .of(e) });
                },
            }
        },
        .tile => if (current_entry()) |e| queue_change(e, .{ .on = !preview(e).on }),
        // The colour field takes the next touch.
        .colour => open_colour(),
        .scenes => push(.{ .scenes = .{ .room = .of(v.entry.id.get()) } }),
        .lights => push(.{ .lights = .{ .room = .of(v.entry.id.get()) } }),
    }
}

fn outgoing_recall(sc: *const catalog.Scene) void {
    if (outgoing != null) flush(ctx_, true);
    outgoing = .{ .recall = .of(sc.id()) };
}
