//! Negative-space tests for parsers (STYLE.md): from one valid input, every input that a
//! truncated or corrupted transfer could produce.
//!
//! `each(fixture, check)` calls `check` on every prefix of `fixture` (each length from 0 to
//! the whole), then on every copy of it with one byte changed (each of its 8 bits flipped,
//! then set to 0x00 and to 0xFF). A parser may return an error or a value for any of them,
//! but must never panic: with `@setRuntimeSafety(true)`, a panic here is an out-of-bounds
//! read or an overflow that the board would hit on the same bytes.
//!
//! Available to every host test as `@import("mutations")` (see `common.add_tests`). Import
//! it inside the `test` block, so firmware builds never look for it.
const std = @import("std");

/// `check` gets a mutable copy: in-place parsers (chunked decoding) may write into it.
pub fn each(fixture: []const u8, check: *const fn (input: []u8) void) !void {
    const gpa = std.testing.allocator;
    const copy = try gpa.alloc(u8, fixture.len);
    defer gpa.free(copy);

    for (0..fixture.len + 1) |len| {
        @memcpy(copy[0..len], fixture[0..len]);
        check(copy[0..len]);
    }
    for (0..fixture.len) |i| {
        for (0..10) |m| {
            @memcpy(copy, fixture);
            copy[i] = switch (m) {
                0...7 => fixture[i] ^ (@as(u8, 1) << @intCast(m)),
                8 => 0x00,
                else => 0xFF,
            };
            check(copy);
        }
    }
}

/// How many inputs `each` makes from a fixture of `len` bytes.
pub fn count(len: usize) usize {
    return (len + 1) + len * 10;
}

var calls: usize = 0;

fn count_call(input: []u8) void {
    _ = input;
    calls += 1;
}

test each {
    calls = 0;
    try each("abc", count_call);
    try std.testing.expectEqual(count(3), calls);
}
