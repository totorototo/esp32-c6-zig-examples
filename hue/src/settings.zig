//! What the remote remembers across reboots, in the flash's `nvs` partition (namespace
//! "hue"), through ../common's `settings` store:
//!
//!   bridge_ip   the bridge's IPv4 address, found by mDNS or given with -Dhue_ip
//!   user        the API username from pairing: a bridge credential, stored unencrypted
//!   selected    the light or room last opened: "l3", "g1", ...
//!
//! Only the main task uses the store (Wi-Fi keeps its own config in RAM here).
pub const Key = enum { bridge_ip, user, selected };

/// 64: a username is 40 characters, an address 15, a selection a few.
const store = @import("settings").Store(.{
    .namespace = "hue",
    .Key = Key,
    .value_max = 64,
});

pub const init = store.init;
pub const get = store.get;
pub const set = store.set;
pub const erase = store.erase;
