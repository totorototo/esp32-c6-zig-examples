//! What the remote remembers across reboots, in the flash's `nvs` partition (namespace
//! "hue", ESP-IDF's NVS format):
//!
//!   bridge_ip   the bridge's IPv4 address, found by mDNS or given with -Dhue_ip
//!   user        the API username from pairing: a bridge credential, stored unencrypted
//!   selected    the light or room last opened: "l3", "g1", ...
//!
//! Only the main task uses the store (Wi-Fi keeps its own config in RAM here), so there is
//! no locking. If the partition is missing or unreadable, everything still works, but
//! nothing is remembered.
const std = @import("std");
const microzig = @import("microzig");
const flash = microzig.hal.flash;

const log = std.log.scoped(.settings);

pub const Key = enum { bridge_ip, user, selected };

const namespace = "hue";

// A global: the store holds a 4 KiB page buffer.
var store: flash.Nvs = undefined;
var handle: ?flash.Nvs.Handle = null;

pub fn init() void {
    const partition = (flash.partition_table.find_data(.nvs, null) catch null) orelse {
        log.warn("no nvs partition: settings won't be remembered", .{});
        return;
    };
    store.init(partition.region(), partition.size) catch |err| {
        log.warn("nvs partition unusable ({t}): settings won't be remembered", .{err});
        return;
    };
    handle = store.open(namespace, .read_write) catch |err| {
        log.warn("nvs namespace not opened ({t}): settings won't be remembered", .{err});
        return;
    };
}

/// The stored value, copied into `buf`, or null when there is none.
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

/// Stores `value` unless it is already the stored one, so repeated calls cost no flash
/// writes.
pub fn set(key: Key, value: []const u8) void {
    const h = handle orelse return;
    var buf: [64]u8 = undefined;
    if (get(key, &buf)) |old| if (std.mem.eql(u8, old, value)) return;
    h.set_str(@tagName(key), value) catch |err| {
        log.warn("saving {t} failed: {t}", .{ key, err });
        return;
    };
    // Checked on the way back too, so a bad write shows now rather than as a lost pairing
    // at the next boot.
    const stored = get(key, &buf) orelse "";
    if (!std.mem.eql(u8, stored, value)) log.err("saving {t}: reads back different", .{key});
}

pub fn erase(key: Key) void {
    const h = handle orelse return;
    h.erase_key(@tagName(key)) catch |err| switch (err) {
        error.NotFound => {},
        else => log.warn("erasing {t} failed: {t}", .{ key, err }),
    };
}
