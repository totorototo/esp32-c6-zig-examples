//! An assertion that stays in ReleaseSmall, as a `verify` module (see STYLE.md).
//!
//! `std.debug.assert` compiles to nothing in ReleaseSmall, which is what the firmware ships
//! as, so an invariant checked with it is only checked by the host tests. `verify` keeps the
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
