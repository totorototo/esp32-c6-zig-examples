//! Checks the two limits of STYLE.md that a machine can measure: functions of at most
//! `function_lines_max` lines, and lines of at most `line_columns_max` columns.
//!
//!     zig run tools/style_lint.zig -- $(git ls-files '*.zig')            # check
//!     zig run tools/style_lint.zig -- --update $(git ls-files '*.zig')   # rewrite the baseline
//!
//! Code written before the rules is listed in `tools/style_baseline.txt`, with its size at
//! the time: it may shrink, but not grow, and anything not listed must meet the limits. So
//! CI fails only on new violations, and old ones go away as files are touched. Functions are
//! measured on the syntax tree (`std.zig.Ast`), from the line of `fn` to the closing brace.
const std = @import("std");
const Ast = std.zig.Ast;

const function_lines_max = 70;
const line_columns_max = 100;
const baseline_path = "tools/style_baseline.txt";

/// Not ours: copied from Zig's std, kept as close to upstream as possible.
const skipped = [_][]const u8{"common/src/https/tls_client.zig"};

/// One file's violations: functions over the limit, and how many lines are too long.
const Violation = union(enum) {
    function: struct { path: []const u8, name: []const u8, lines: u32 },
    long_lines: struct { path: []const u8, count: u32 },

    fn key(v: Violation, arena: std.mem.Allocator) ![]const u8 {
        return switch (v) {
            .function => |f| std.fmt.allocPrint(arena, "fn {s} {s}", .{ f.path, f.name }),
            .long_lines => |l| std.fmt.allocPrint(arena, "columns {s}", .{l.path}),
        };
    }

    fn size(v: Violation) u32 {
        return switch (v) {
            .function => |f| f.lines,
            .long_lines => |l| l.count,
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var update = false;
    var violations: std.ArrayList(Violation) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--update")) {
            update = true;
            continue;
        }
        if (is_skipped(arg)) continue;
        const limit: std.Io.Limit = .limited(1 << 22);
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, arg, arena, limit, .of(u8), 0);
        try check_file(arena, arg, source, &violations);
    }

    if (update) {
        var text: std.Io.Writer.Allocating = .init(arena);
        try text.writer.writeAll(
            "# Code from before STYLE.md, at its size then: `<kind> <path> [name] <size>`.\n" ++
                "# Rewritten by `zig run tools/style_lint.zig -- --update <files>`.\n",
        );
        for (violations.items) |v| {
            try text.writer.print("{s} {}\n", .{ try v.key(arena), v.size() });
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = text.written() });
        std.debug.print("{s}: {} entries\n", .{ baseline_path, violations.items.len });
        return 0;
    }

    const baseline = try read_baseline(arena, io);
    var failures: u32 = 0;
    for (violations.items) |v| {
        const allowed = baseline.get(try v.key(arena));
        if (allowed != null and v.size() <= allowed.?) continue;
        failures += 1;
        const note = if (allowed) |a| baseline_note(arena, a) else "";
        switch (v) {
            .function => |f| std.debug.print("{s}: fn {s} is {} lines (max {}{s})\n", .{
                f.path, f.name, f.lines, function_lines_max, note,
            }),
            .long_lines => |l| std.debug.print("{s}: {} lines over {} columns{s}\n", .{
                l.path, l.count, line_columns_max, note,
            }),
        }
    }
    if (failures > 0) {
        std.debug.print("style: {} new violation(s), see STYLE.md\n", .{failures});
        return 1;
    }
    std.debug.print("style: ok ({} baseline entries)\n", .{baseline.count()});
    return 0;
}

fn baseline_note(arena: std.mem.Allocator, allowed: u32) []const u8 {
    const text = "; the baseline allows {} and it may only shrink";
    return std.fmt.allocPrint(arena, text, .{allowed}) catch "";
}

fn is_skipped(path: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, path, s)) return true;
    return false;
}

fn check_file(
    arena: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(Violation),
) !void {
    var tree = try Ast.parse(arena, source, .{});
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const lines = line_of(source, tree.tokenStart(tree.lastToken(node))) -
            line_of(source, tree.tokenStart(tree.firstToken(node))) + 1;
        if (lines <= function_lines_max) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node).?;
        const name = if (proto.name_token) |t| tree.tokenSlice(t) else "(anonymous)";
        try out.append(arena, .{ .function = .{ .path = path, .name = name, .lines = lines } });
    }
    const count = long_lines(source);
    if (count > 0) try out.append(arena, .{ .long_lines = .{ .path = path, .count = count } });
}

/// 1-based line of byte `offset`.
fn line_of(source: []const u8, offset: u32) u32 {
    return @intCast(std.mem.count(u8, source[0..offset], "\n") + 1);
}

/// Lines longer than `line_columns_max`, counted in code points (`é` is one column).
fn long_lines(source: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const columns = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (columns > line_columns_max) count += 1;
    }
    return count;
}

fn read_baseline(arena: std.mem.Allocator, io: std.Io) !std.StringHashMapUnmanaged(u32) {
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    const limit: std.Io.Limit = .limited(1 << 20);
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, baseline_path, arena, limit) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.BadBaseline;
        try map.put(arena, line[0..space], try std.fmt.parseInt(u32, line[space + 1 ..], 10));
    }
    return map;
}

test "function length and long lines" {
    const body = repeat("    _ = 1;\n", function_lines_max);
    const long_string = repeat("é", line_columns_max - 12); // é: 2 bytes, 1 column
    const source = "fn short() void {}\n" ++
        "fn long() void {\n" ++ body ++ "}\n" ++
        "const s = \"" ++ long_string ++ "\";\n";
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Violation) = .empty;
    try check_file(arena, "x.zig", source, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("long", out.items[0].function.name);
    try std.testing.expectEqual(@as(u32, function_lines_max + 2), out.items[0].function.lines);
    try std.testing.expectEqual(@as(u32, 1), out.items[1].long_lines.count);
}

test "a line of exactly the limit passes" {
    try std.testing.expectEqual(@as(u32, 0), long_lines(repeat("a", line_columns_max)));
    try std.testing.expectEqual(@as(u32, 1), long_lines(repeat("a", line_columns_max + 1)));
    try std.testing.expectEqual(@as(u32, 0), long_lines(repeat("é", line_columns_max)));
}

/// `s` repeated `n` times, at compile time.
inline fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (0..n) |_| out = out ++ s;
        return out;
    }
}
