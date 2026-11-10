//! What the board remembers, in the flash's `nvs` partition (namespace "netatmo"):
//!
//!   refresh   the current OAuth refresh token. Netatmo replaces it on every refresh and
//!             the old one stops working, so the new one is written here before the new
//!             access token is used: a reset in between must not lose the only valid one.
//!   home_id   the home last used.
//!
//! Stored unencrypted. Only the main task uses the store.
const std = @import("std");
const microzig = @import("microzig");
const flash = microzig.hal.flash;

const log = std.log.scoped(.settings);

pub const Key = enum { refresh, home_id };

var store: flash.Nvs = undefined;
var handle: ?flash.Nvs.Handle = null;

pub fn init() void {
    const partition = (flash.partition_table.find_data(.nvs, null) catch null) orelse {
        log.warn("no nvs partition: nothing will be remembered", .{});
        return;
    };
    store.init(partition.region(), partition.size) catch |err| {
        log.warn("nvs partition unusable ({t}): nothing will be remembered", .{err});
        return;
    };
    handle = store.open("netatmo", .read_write) catch |err| {
        log.warn("nvs namespace not opened ({t})", .{err});
        return;
    };
}

pub fn get(key: Key, buf: []u8) ?[]const u8 {
    const h = handle orelse return null;
    return h.get_str(@tagName(key), buf) catch |err| switch (err) {
        error.NotFound => null,
        else => {
            log.warn("reading {t} failed: {t}", .{ key, err });
            return null;
        },
    };
}

/// Stores `value` unless it is already the stored one. Returns false if it could not be
/// written (the caller decides whether that matters).
pub fn set(key: Key, value: []const u8) bool {
    const h = handle orelse return false;
    var buf: [128]u8 = undefined;
    if (get(key, &buf)) |old| if (std.mem.eql(u8, old, value)) return true;
    h.set_str(@tagName(key), value) catch |err| {
        log.warn("saving {t} failed: {t}", .{ key, err });
        return false;
    };
    return true;
}

pub fn erase(key: Key) void {
    const h = handle orelse return;
    h.erase_key(@tagName(key)) catch {};
}
