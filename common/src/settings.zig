//! Settings that survive a reboot: strings in the flash's `nvs` partition (ESP-IDF's NVS
//! format), one namespace per sample, as a `settings` module.
//!
//!     const Key = enum { bridge_ip, user };
//!     const store = @import("settings").Store(.{
//!         .namespace = "hue", .Key = Key, .value_max = 64,
//!     });
//!
//! One task only: nothing here locks, and `verify` stops the board if a second task calls
//! in (it would race the NVS page buffer). If the partition is missing or unreadable,
//! everything still works, but nothing is remembered.
const std = @import("std");
const microzig = @import("microzig");
const flash = microzig.hal.flash;
const rtos = microzig.hal.rtos;
const verify = @import("verify").verify;

const log = std.log.scoped(.settings);

pub const Options = struct {
    /// The NVS namespace (at most 15 bytes).
    namespace: []const u8,
    /// An enum: each tag name is a key (at most 15 bytes).
    Key: type,
    /// The longest value `set` stores; `set` reads each write back into a buffer this size.
    value_max: usize,
};

pub fn Store(comptime options: Options) type {
    comptime {
        std.debug.assert(options.namespace.len <= 15);
        for (std.meta.fieldNames(options.Key)) |name| std.debug.assert(name.len <= 15);
    }
    return struct {
        pub const Key = options.Key;

        pub fn init() void {
            open(options.namespace);
        }

        /// The stored value, copied into `buf`, or null when there is none.
        pub fn get(key: Key, buf: []u8) ?[]const u8 {
            return get_str(@tagName(key), buf);
        }

        /// Stores `value` unless it is already the stored one, so repeated calls cost no
        /// flash writes. Returns false if it isn't stored: no partition, a value over
        /// `value_max`, a failed write, or a read-back that differs. The caller decides
        /// whether that matters.
        pub fn set(key: Key, value: []const u8) bool {
            var buf: [options.value_max]u8 = undefined;
            return set_str(@tagName(key), value, &buf);
        }

        pub fn erase(key: Key) void {
            erase_str(@tagName(key));
        }
    };
}

// ---- the store itself: one per firmware, so its state is global ----

// A global: the store holds a 4 KiB page buffer.
var store: flash.Nvs = undefined;
var handle: ?flash.Nvs.Handle = null;

/// The task that opened the store. Nothing here locks: only that task may use it.
var owner: ?*rtos.Task = null;

/// Negative space for "one task only": a second task would race the NVS page buffer
/// without a lock.
fn check_owner() void {
    verify(owner == null or owner.? == rtos.get_current_task(), "settings used from one task");
}

fn open(namespace: []const u8) void {
    // A second `init` (or a second Store) would share these globals under another name.
    verify(owner == null, "one settings store per firmware, opened once");
    owner = rtos.get_current_task();
    const partition = (flash.partition_table.find_data(.nvs, null) catch null) orelse {
        log.warn("no nvs partition: nothing will be remembered", .{});
        return;
    };
    store.init(partition.region(), partition.size) catch |err| {
        log.warn("nvs partition unusable ({t}): nothing will be remembered", .{err});
        return;
    };
    handle = store.open(namespace, .read_write) catch |err| {
        log.warn("nvs namespace not opened ({t}): nothing will be remembered", .{err});
        return;
    };
}

fn get_str(key: []const u8, buf: []u8) ?[]const u8 {
    check_owner();
    const h = handle orelse return null;
    return h.get_str(key, buf) catch |err| switch (err) {
        error.NotFound => null,
        else => {
            log.warn("reading {s} failed: {t}", .{ key, err });
            return null;
        },
    };
}

/// `buf` is the read-back buffer: its length is the longest value stored.
fn set_str(key: []const u8, value: []const u8, buf: []u8) bool {
    check_owner();
    const h = handle orelse return false;
    if (value.len > buf.len) {
        log.err("saving {s}: {} bytes, over the {} it may hold", .{ key, value.len, buf.len });
        return false;
    }
    if (get_str(key, buf)) |old| if (std.mem.eql(u8, old, value)) return true;
    h.set_str(key, value) catch |err| {
        log.warn("saving {s} failed: {t}", .{ key, err });
        return false;
    };
    // Checked on the way back too, so a bad write shows now rather than as a lost pairing
    // or login at the next boot.
    const stored = get_str(key, buf) orelse "";
    if (!std.mem.eql(u8, stored, value)) {
        log.err("saving {s}: reads back different", .{key});
        return false;
    }
    return true;
}

fn erase_str(key: []const u8) void {
    check_owner();
    const h = handle orelse return;
    h.erase_key(key) catch |err| switch (err) {
        error.NotFound => {},
        else => log.warn("erasing {s} failed: {t}", .{ key, err }),
    };
}
