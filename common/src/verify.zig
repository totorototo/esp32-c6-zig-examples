//! An assertion that stays in ReleaseSmall, as a `verify` module (see STYLE.md).
//!
//! In ReleaseSmall, which the firmware ships as, `std.debug.assert` is `unreachable`: not
//! checked, and assumed true by the optimizer, so a false one is undefined behaviour. Only
//! the Debug host tests check it. `verify` keeps the
//! check: a broken invariant stops the board with a message, instead of corrupting memory
//! and failing somewhere else later. For programmer errors only. Bad input from the network
//! or a device is an error to return, not a reason to stop.
const std = @import("std");

/// Stops with "verify failed: <what>" when `ok` is false.
pub inline fn verify(ok: bool, comptime what: []const u8) void {
    if (!ok) @panic("verify failed: " ++ what);
}

test verify {
    verify(true, "never shown");
}
