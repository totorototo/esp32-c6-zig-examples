//! Changes on their way to the bridge: drawn at once, sent one at a time by the bridge task
//! (bridge.zig). The screen shows a light as it will be (`preview`) while its change waits
//! or is in flight, so it doesn't flick back to the old state for the length of a request.
//!
//! Changes to the same light or room merge while they wait: a slide sends only its latest
//! brightness, however slow the bridge is. Used by both touch UIs (list.zig, field.zig).
const std = @import("std");
const hue = @import("hue.zig");
const catalog = @import("catalog.zig");
const bridge = @import("bridge.zig");

const Id = catalog.Id;
const Ref = catalog.Ref;

const log = std.log.scoped(.outbox);

pub const Item = union(enum) {
    change: struct { ref: Ref, change: hue.Change },
    recall: Id,
};

/// Taps on different lights while the bridge is busy. One request takes well under a
/// second on a working bridge; a full outbox means it isn't answering.
const max_waiting = 4;

pub const Outbox = struct {
    waiting: [max_waiting]Item = undefined,
    len: u8 = 0,
    in_flight: ?Item = null,
    last_send: u64 = 0,

    /// Queues `c` for `e`, merged into a change for `e` already waiting at the end. False
    /// when the outbox is full: the change is dropped, and the caller says so.
    pub fn change(o: *Outbox, e: *const catalog.Entry, c: hue.Change) bool {
        if (o.len > 0) {
            const last = &o.waiting[o.len - 1];
            if (last.* == .change and last.change.ref.is(e)) {
                merge(&last.change.change, c);
                return true;
            }
        }
        return o.push(.{ .change = .{ .ref = .of(e), .change = c } });
    }

    pub fn recall(o: *Outbox, sc: *const catalog.Scene) bool {
        return o.push(.{ .recall = .of(sc.id()) });
    }

    fn push(o: *Outbox, item: Item) bool {
        if (o.len == max_waiting) {
            log.warn("{} changes already wait for the bridge: {t} dropped", .{
                max_waiting, item,
            });
            return false;
        }
        o.waiting[o.len] = item;
        o.len += 1;
        return true;
    }

    /// Nothing waiting and nothing in flight: what the catalog holds is what was sent.
    pub fn empty(o: *const Outbox) bool {
        return o.len == 0 and o.in_flight == null;
    }

    /// The first waiting item, as a command, now in flight. Null while `hold` (a slide
    /// throttling itself) or when nothing waits. Changes that change nothing are dropped.
    pub fn next(o: *Outbox, t: u64, hold: bool) ?bridge.Cmd {
        if (o.in_flight != null or hold) return null;
        while (o.len > 0) {
            const item = o.waiting[0];
            std.mem.copyForwards(Item, o.waiting[0 .. o.len - 1], o.waiting[1..o.len]);
            o.len -= 1;
            const cmd = command(item) orelse continue;
            o.in_flight = item;
            o.last_send = t;
            return cmd;
        }
        return null;
    }

    /// The bridge task is done with what was in flight.
    pub fn done(o: *Outbox) void {
        o.in_flight = null;
    }

    /// `e` as it will be once what waits for it is through.
    pub fn preview(o: *const Outbox, e: *const catalog.Entry) hue.LightState {
        var c: hue.Change = .{};
        if (o.in_flight) |*item| if (item.* == .change and item.change.ref.is(e)) {
            merge(&c, item.change.change);
        };
        for (o.waiting[0..o.len]) |*item| if (item.* == .change and item.change.ref.is(e)) {
            merge(&c, item.change.change);
        };
        return over(e.state, c);
    }

    /// True while a recall of `sc` waits or is in flight: the list marks it at once.
    pub fn recalling(o: *const Outbox, sc: *const catalog.Scene) bool {
        if (o.in_flight) |*item| if (is_recall_of(item, sc)) return true;
        for (o.waiting[0..o.len]) |*item| if (is_recall_of(item, sc)) return true;
        return false;
    }
};

fn is_recall_of(item: *const Item, sc: *const catalog.Scene) bool {
    return item.* == .recall and std.mem.eql(u8, item.recall.get(), sc.id());
}

/// What to send for `item`, from the catalog as it is now: the light may be gone, or
/// already as asked.
fn command(item: Item) ?bridge.Cmd {
    switch (item) {
        .change => |c| {
            const e = c.ref.entry() orelse return null;
            if (is_noop(e.state, c.change)) return null;
            return .{ .change = .{ .ref = c.ref, .change = c.change } };
        },
        .recall => |id| {
            const sc = catalog.find_scene(id.get()) orelse return null;
            // Re-read the room (when it's one of ours) and the selection (which the LED
            // mirrors) along with the recall, if that's something else.
            const room = catalog.groups.find(sc.group());
            const sel = catalog.selected();
            return .{ .recall = .{
                .scene = id,
                .group = .of(sc.group()),
                .room = if (room) |g| Ref.of(g) else null,
                .selected = if (sel != null and sel != room) Ref.of(sel.?) else null,
            } };
        },
    }
}

fn merge(into: *hue.Change, c: hue.Change) void {
    if (c.on) |v| into.on = v;
    if (c.bri) |v| into.bri = v;
    if (c.hue) |v| into.hue = v;
    if (c.sat) |v| into.sat = v;
}

pub fn over(s: hue.LightState, c: hue.Change) hue.LightState {
    var v = s;
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
