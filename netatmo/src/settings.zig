//! What the board remembers, in the flash's `nvs` partition (namespace "netatmo"), through
//! ../common's `settings` store:
//!
//!   refresh   the current OAuth refresh token. Netatmo replaces it on every refresh and
//!             the old one stops working, so the new one is written here before the new
//!             access token is used: a reset in between must not lose the only valid one.
//!   home_id   the home last used.
//!
//! Stored unencrypted. Only the main task uses the store.
pub const Key = enum { refresh, home_id };

/// 128: a refresh token is about 60 characters, a home id 24.
const store = @import("settings").Store(.{
    .namespace = "netatmo",
    .Key = Key,
    .value_max = 128,
});

pub const init = store.init;
pub const get = store.get;
pub const set = store.set;
pub const erase = store.erase;
