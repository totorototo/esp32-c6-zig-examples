//! The Hue bridge, from a task of its own. Before this, the UI loop made the requests
//! itself, and a slow bridge froze the touch screen for as long as a request took (up to
//! `hue.response_timeout_ms`, 10 s).
//!
//! Two sides, one command in flight at a time:
//!
//!   UI task                           bridge task
//!   submit(cmd) -- cmds (1 slot) -->  run(cmd): the requests, into its own buffers
//!   poll()      <-- replies (1 slot)  reply
//!       applies the reply to `catalog`
//!
//! Only the UI task touches `catalog`, the screen, the settings and the LED; only the
//! bridge task touches the network (after boot, see `run_now`). So nothing needs a lock.
//! With one command in flight the reply slot is always free when the bridge task answers,
//! and the buffers a reply points into (`fresh_list`, `fresh_scenes`) stay untouched until
//! the UI has copied them: the next command can't start before `poll` returned this one.
const std = @import("std");
const microzig = @import("microzig");
const hue = @import("hue.zig");
const catalog = @import("catalog.zig");
const verify = @import("verify").verify;

const rtos = microzig.hal.rtos;
const log = std.log.scoped(.bridge);

const Id = catalog.Id;
const Ref = catalog.Ref;

pub const Context = struct {
    bridge: hue.Bridge,
    user: []const u8,
    allocator: std.mem.Allocator,
};

pub const Cmd = union(enum) {
    /// Re-read every light, or every room and zone.
    list: hue.Kind,
    /// Re-read one light or room.
    entry: Ref,
    scenes,
    change: struct { ref: Ref, change: hue.Change },
    all_off,
    /// Recall a scene on its group, then re-read the room and the selection so the screen
    /// and the LED show the result at once.
    recall: struct { scene: Id, group: Id, room: ?Ref, selected: ?Ref },
    look: Id,
};

/// Who asked: `poll` hands the outcome back to them. `look` is the screen too, apart from
/// `touch` because a scene colour that didn't load isn't worth a banner.
pub const Owner = enum { touch, look, refresh, web, button };

pub const Done = struct {
    owner: Owner,
    cmd: Cmd,
    ok: bool,
};

const Data = union(enum) {
    none,
    list: *const catalog.List,
    entry: catalog.Entry,
    scenes: *catalog.SceneList,
    recall: struct { room: ?catalog.Entry, selected: ?catalog.Entry },
    look: ?hue.Look,
};

const Reply = struct {
    owner: Owner,
    cmd: Cmd,
    data: anyerror!Data,
};

// ---- the UI side ----

var cmd_buf: [1]struct { owner: Owner, cmd: Cmd } = undefined;
var reply_buf: [1]Reply = undefined;
var cmds: rtos.Queue(@TypeOf(cmd_buf[0])) = .init(&cmd_buf);
var replies: rtos.Queue(Reply) = .init(&reply_buf);

/// Set by `submit`, cleared by `poll` once the reply is applied.
var in_flight: ?Owner = null;
/// Offline (-Ddemo), there's no bridge task: `submit` answers at once, here.
var offline_reply: ?Reply = null;
var worker: ?*rtos.Task = null;
var ui_task: ?*rtos.Task = null;

/// True when `submit` may be called.
pub fn idle() bool {
    return in_flight == null;
}

/// Hands `cmd` to the bridge task. Only one at a time: check `idle` first.
pub fn submit(owner: Owner, cmd: Cmd) void {
    check_ui_task();
    verify(in_flight == null, "one bridge command in flight");
    in_flight = owner;
    if (catalog.offline) {
        offline_reply = .{ .owner = owner, .cmd = cmd, .data = .none };
        return;
    }
    verify(worker != null, "bridge task started before submit");
    // The slot is free: the last command's reply was taken before `in_flight` cleared.
    cmds.put_one(.{ .owner = owner, .cmd = cmd }, .non_blocking) catch
        verify(false, "bridge command slot free");
}

/// The command's outcome once the bridge task is done with it, already applied to the
/// catalog. Never blocks.
pub fn poll() ?Done {
    check_ui_task();
    const r = take_reply() orelse return null;
    in_flight = null;
    return .{ .owner = r.owner, .cmd = r.cmd, .ok = apply(r.cmd, r.data) };
}

fn take_reply() ?Reply {
    if (offline_reply) |r| {
        offline_reply = null;
        return r;
    }
    if (worker == null) return null;
    return replies.get_one(.non_blocking) catch null;
}

/// Negative space for "the catalog has one owner": submit and poll from one task only.
fn check_ui_task() void {
    const current = rtos.get_current_task();
    if (ui_task == null) ui_task = current;
    verify(ui_task.? == current, "bridge used from the UI task only");
}

/// Copies what the bridge task read into the catalog. False when the bridge didn't take it.
fn apply(cmd: Cmd, data: anyerror!Data) bool {
    const d = data catch |err| {
        log_failure(cmd, err);
        // Shown dark: else the screen would ask for it again at once, and forever.
        if (cmd == .look) catalog.apply_look(cmd.look.get(), null);
        return false;
    };
    switch (cmd) {
        .list => |kind| if (d == .list) catalog.apply_list(kind, d.list),
        .entry => if (d == .entry) catalog.apply_entry(&d.entry),
        .scenes => if (d == .scenes) catalog.apply_scenes(d.scenes),
        .change => |c| if (c.ref.entry()) |e| catalog.apply_change(e, c.change),
        .all_off => catalog.apply_all_off(),
        .recall => |r| {
            catalog.apply_recall(r.scene.get());
            if (d == .recall) for ([_]?catalog.Entry{ d.recall.room, d.recall.selected }) |fresh| {
                if (fresh) |*f| catalog.apply_entry(f);
            };
        },
        .look => |id| if (d == .look) catalog.apply_look(id.get(), d.look),
    }
    return true;
}

/// Changes are errors (someone asked for them); reads only warnings: the screen keeps what
/// it had, and the next refresh tries again.
fn log_failure(cmd: Cmd, err: anyerror) void {
    switch (cmd) {
        .change => |c| log.err("set {t} {s} failed: {t}", .{ c.ref.kind, c.ref.id.get(), err }),
        .all_off => log.err("all off failed: {t}", .{err}),
        .recall => |r| log.err("recall scene {s} failed: {t}", .{ r.scene.get(), err }),
        .look => |id| log.warn("scene {s} not read: {t}", .{ id.get(), err }),
        .entry => |ref| log.warn("{t} {s} not read: {t}", .{ ref.kind, ref.id.get(), err }),
        .list, .scenes => log.warn("{t} not read: {t}", .{ cmd, err }),
    }
}

/// For boot, before the bridge task runs (finding the bridge, the first reads): the
/// request in the calling task, applied at once.
pub fn run_now(ctx: Context, cmd: Cmd) !void {
    verify(worker == null, "run_now before the bridge task starts");
    const data = run(ctx, cmd);
    _ = data catch |err| return err;
    _ = apply(cmd, data);
}

// ---- the bridge task ----

/// The bridge task's stack: what the main task's stack was when it made these requests
/// itself (see main.zig). The deepest path is a JSON parse of `/lights`; the arena it parses
/// into is on the heap.
const stack_size = 16 * 1024;

pub fn start(gpa: std.mem.Allocator, ctx: Context) !void {
    verify(worker == null, "one bridge task");
    // Below the UI task (see main.zig): a long parse here must not hold up a frame.
    worker = try rtos.spawn(gpa, task, .{ctx}, .{
        .name = "bridge",
        .stack_size = stack_size,
        .priority = .lowest,
    });
}

/// Runs forever: a command, its reply, the next command. Each request is bounded by
/// `hue.response_timeout_ms`, so a dead bridge costs a failed reply, not a stuck task.
fn task(ctx: Context) noreturn {
    while (true) {
        const c = cmds.get_one(.never) catch unreachable; // `.never` doesn't time out
        // The slot is free: the UI submits only after taking the previous reply.
        replies.put_one(.{ .owner = c.owner, .cmd = c.cmd, .data = run(ctx, c.cmd) }, .never) catch
            unreachable;
    }
}

/// Fresh reads, filled by the bridge task and copied by the UI in `poll`. Static, not on the
/// stack: a list is 2.6 KiB, the scenes 6 KiB.
var fresh_list: catalog.List = .{};
var fresh_scenes: catalog.SceneList = .{};

fn run(ctx: Context, cmd: Cmd) anyerror!Data {
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    switch (cmd) {
        .list => |kind| {
            try read_list(a, ctx, kind, &fresh_list);
            return .{ .list = &fresh_list };
        },
        .entry => |ref| return .{ .entry = try read_entry(a, ctx, ref) },
        .scenes => {
            fresh_scenes.len = 0;
            fresh_scenes.dropped = 0;
            try hue.get_scenes(a, ctx.bridge, ctx.user, &fresh_scenes);
            return .{ .scenes = &fresh_scenes };
        },
        .change => |c| try hue.set_state(a, ctx.bridge, ctx.user, c.ref.target(), c.change),
        .all_off => try hue.set_state(a, ctx.bridge, ctx.user, .{ .kind = .group, .id = "0" }, .{
            .on = false,
        }),
        .recall => |r| return try recall(a, ctx, r),
        .look => |id| return .{ .look = try hue.get_scene_look(a, ctx.bridge, ctx.user, id.get()) },
    }
    return .none;
}

/// Rooms and zones only: the other group types (LightGroup, Entertainment, Luminaire) are
/// app or bridge internals.
fn read_list(a: std.mem.Allocator, ctx: Context, kind: hue.Kind, fresh: *catalog.List) !void {
    fresh.len = 0;
    switch (kind) {
        .light => {
            const map = try hue.get_lights(a, ctx.bridge, ctx.user);
            var it = map.map.iterator();
            while (it.next()) |kv| {
                catalog.add(fresh, .light, kv.key_ptr.*, kv.value_ptr.name, kv.value_ptr.state);
            }
        },
        .group => {
            const map = try hue.get_groups(a, ctx.bridge, ctx.user);
            var it = map.map.iterator();
            while (it.next()) |kv| {
                const g = kv.value_ptr.*;
                if (!std.mem.eql(u8, g.type, "Room") and !std.mem.eql(u8, g.type, "Zone")) continue;
                catalog.add(fresh, .group, kv.key_ptr.*, g.name, g.as_light().state);
                if (fresh.len > 0) fresh.items[fresh.len - 1].set_members(g.lights);
            }
        },
    }
}

fn read_entry(a: std.mem.Allocator, ctx: Context, ref: Ref) !catalog.Entry {
    const fresh = try hue.get(a, ctx.bridge, ctx.user, ref.target());
    return .make(ref.kind, ref.id.get(), fresh.name, fresh.state);
}

fn recall(a: std.mem.Allocator, ctx: Context, r: @FieldType(Cmd, "recall")) !Data {
    try hue.recall_scene(a, ctx.bridge, ctx.user, r.group.get(), r.scene.get());
    // The recall went through: a failed re-read only means the screen catches up at the
    // next refresh.
    var out: Data = .{ .recall = .{ .room = null, .selected = null } };
    if (r.room) |ref| out.recall.room = read_entry(a, ctx, ref) catch |err| blk: {
        log.warn("room not re-read: {t}", .{err});
        break :blk null;
    };
    if (r.selected) |ref| out.recall.selected = read_entry(a, ctx, ref) catch |err| blk: {
        log.warn("selection not re-read: {t}", .{err});
        break :blk null;
    };
    return out;
}
