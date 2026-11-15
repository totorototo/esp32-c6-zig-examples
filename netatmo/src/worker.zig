//! The screen and the network on separate tasks, so a request never freezes the screen: a
//! TLS handshake alone is about a second of CPU on the chip, ~9 s in Wokwi.
//!
//! The pattern of ../hue/src/bridge.zig, with the roles swapped. HTTPS needs the 112 KiB
//! main stack (a handshake takes ~86 KiB of it) and the heap can't spare a second one, so
//! the requests stay on the main task and the screen gets a small task of its own.
//!
//!   UI task                          main task
//!   submit(cmd) -- cmds (1 slot) --> serve(run): the request, read into its own home
//!   poll(shown) <-- replies (1 slot) reply
//!       copies the result into the home the screen shows
//!
//! Only the UI task touches the shown home, the screen and the backlight; only the main
//! task touches the network, the settings and its own home. So nothing needs a lock. With
//! one command in flight the reply slot is always free when the main task answers, and the
//! home a reply points to isn't written again until `poll` has copied it: the next command
//! can't start before `poll` returned this one.
const std = @import("std");
const microzig = @import("microzig");
const energy = @import("energy.zig");
const verify = @import("verify").verify;

const rtos = microzig.hal.rtos;
const log = std.log.scoped(.worker);

pub const RoomId = @FieldType(energy.Room, "id");

/// A room's setpoint from the screen. `temp` null: back to the schedule.
pub const Set = struct { room: RoomId, temp: ?f32 };

pub const Cmd = union(enum) {
    /// Re-read every room's status.
    refresh,
    set: Set,
};

/// What `run` answers: the home as it just read it, or null when it read none (a manual
/// setpoint, which `poll` then applies to the shown home itself).
pub const Result = anyerror!?*const energy.Home;

pub const Done = struct { cmd: Cmd, ok: bool };

const Reply = struct { cmd: Cmd, result: Result };

var cmd_buf: [1]Cmd = undefined;
var reply_buf: [1]Reply = undefined;
var cmds: rtos.Queue(Cmd) = .init(&cmd_buf);
var replies: rtos.Queue(Reply) = .init(&reply_buf);

/// Set by `submit`, cleared by `poll` once the reply is applied.
var in_flight = false;
var ui_task: ?*rtos.Task = null;
var net_task: ?*rtos.Task = null;

// ---- the UI side ----

/// True when `submit` may be called.
pub fn idle() bool {
    return !in_flight;
}

/// Hands `cmd` to the main task. One at a time: check `idle` first.
pub fn submit(cmd: Cmd) void {
    check_task(&ui_task, "worker submitted to and polled from the UI task only");
    verify(!in_flight, "one netatmo command in flight");
    in_flight = true;
    // The slot is free: the last command's reply was taken before `in_flight` cleared.
    cmds.put_one(cmd, .non_blocking) catch verify(false, "netatmo command slot free");
}

/// The command's outcome once the main task is done with it, already applied to `shown`.
/// Never blocks.
pub fn poll(shown: *energy.Home) ?Done {
    check_task(&ui_task, "worker submitted to and polled from the UI task only");
    const r = replies.get_one(.non_blocking) catch return null;
    in_flight = false;
    const fresh = r.result catch |err| {
        log_failure(shown, r.cmd, err);
        return .{ .cmd = r.cmd, .ok = false };
    };
    if (fresh) |h| {
        // Byte for byte: an assignment of a 4 KiB struct may go through a temporary on the
        // stack, and this task's is 8 KiB.
        @memcpy(std.mem.asBytes(shown), std.mem.asBytes(h));
    } else if (r.cmd == .set) {
        apply_set(shown, r.cmd.set);
    }
    return .{ .cmd = r.cmd, .ok = true };
}

/// What Netatmo accepted, without reading the room back: the next refresh confirms it.
fn apply_set(shown: *energy.Home, s: Set) void {
    const room = shown.room(s.room.slice()) orelse return;
    if (s.temp) |t| {
        room.setpoint = t;
        room.mode.set("manual");
    } else room.mode.set("schedule");
}

fn log_failure(shown: *energy.Home, cmd: Cmd, err: anyerror) void {
    switch (cmd) {
        .refresh => log.warn("refresh failed: {t}", .{err}),
        .set => |s| {
            const name = if (shown.room(s.room.slice())) |room| room.name.slice() else s.room.slice();
            log.err("sending to `{s}` failed: {t}", .{ name, err });
        },
    }
}

// ---- the main task's side ----

/// Runs forever: a command, its reply, the next command. Each request is bounded by the
/// HTTPS deadlines (../common/src/https.zig), so a dead API costs a failed reply, not a
/// stuck screen.
pub fn serve(run: fn (Cmd) Result) noreturn {
    check_task(&net_task, "worker served from one task");
    while (true) {
        const cmd = cmds.get_one(.never) catch unreachable; // `.never` doesn't time out
        // The slot is free: the UI submits only after taking the previous reply.
        replies.put_one(.{ .cmd = cmd, .result = run(cmd) }, .never) catch unreachable;
    }
}

/// Negative space for "each side has one owner": the first task to call in becomes it.
fn check_task(owner: *?*rtos.Task, comptime what: []const u8) void {
    const current = rtos.get_current_task();
    if (owner.* == null) owner.* = current;
    verify(owner.*.? == current, what);
}
