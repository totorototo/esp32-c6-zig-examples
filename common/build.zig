//! Shared networking for the Wi-Fi examples: Wi-Fi bring-up, the lwIP OS glue and small
//! HTTP helpers, as one `net` module.
//!
//! An example depends on this directory (`.common = .{ .path = "../common" }`) and calls
//! `add_net` from its build.zig. The module is created in the example's own builder and
//! attached to its firmware, so it shares the firmware's `microzig` module rather than
//! compiling against a second copy.
const std = @import("std");

pub fn build(_: *std.Build) void {}

pub const Options = struct {
    optimize: std.builtin.OptimizeMode,
    /// The example's `config` module (its build options); `net.zig` reads `ssid` and
    /// `password` from it. Pass the module the firmware imports, not the Options step:
    /// wrapping one options file in two modules is a compile error.
    config: *std.Build.Module,
    /// Directory holding `lwipopts.h` and `arch/`. Defaults to common's own; override it
    /// to tune lwIP for one example.
    lwip_include_dir: ?std.Build.LazyPath = null,
};

/// Builds lwIP for `fw` and adds the `net` import to it. Returns false on the first pass,
/// while Zig fetches lwIP's sources (a lazy dependency of MicroZig); the build then runs
/// again. `b` is the example's builder, whose build.zig.zon must name this package `common`.
pub fn add_net(b: *std.Build, mz_dep: *std.Build.Dependency, fw: anytype, opts: Options) bool {
    const common = b.dependency("common", .{});
    const target = b.resolveTargetQuery(fw.target.zig_target);

    // lwIP, built against lwipopts.h, plus the small libc it needs.
    const foundation_dep = mz_dep.builder.lazyDependency("modules/foundation-libc", .{
        .target = target,
        .optimize = opts.optimize,
        .single_threaded = true,
    }) orelse return false;
    const lwip_dep = mz_dep.builder.lazyDependency("modules/lwip", .{
        .target = target,
        .optimize = opts.optimize,
        .include_dir = opts.lwip_include_dir orelse common.path("src/lwip/include"),
    }) orelse return false;
    const lwip = lwip_dep.module("lwip");
    lwip.linkLibrary(foundation_dep.artifact("foundation"));

    // The UART0 logger the RTOS samples share (safe to call from a trap or a panic), also
    // wired into net.std_options.
    const uart_log = b.createModule(.{ .root_source_file = common.path("src/uart_log.zig") });
    fw.add_app_import("uart_log", uart_log, .{ .depend_on_microzig = true });

    // An assertion that stays on in ReleaseSmall (see STYLE.md).
    const verify = b.createModule(.{ .root_source_file = common.path("src/verify.zig") });
    fw.add_app_import("verify", verify, .{});

    const net = b.createModule(.{ .root_source_file = common.path("src/net.zig") });
    net.addImport("lwip", lwip);
    net.addImport("config", opts.config);
    net.addImport("uart_log", uart_log);
    net.addImport("verify", verify);
    fw.add_app_import("net", net, .{ .depend_on_microzig = true });

    // HTTPS on top of it (TLS 1.3, see src/https.zig for what the firmware must provide).
    // Only compiled into firmware that imports it.
    const https = b.createModule(.{ .root_source_file = common.path("src/https.zig") });
    https.addImport("net", net);
    https.addImport("verify", verify);
    fw.add_app_import("https", https, .{ .depend_on_microzig = true });
    return true;
}

/// The touch screen (ILI9341 + FT6206), font, colours and text drawing, as a `screen` module.
pub fn add_screen(b: *std.Build, fw: anytype) void {
    const common = b.dependency("common", .{});
    const screen = b.createModule(.{ .root_source_file = common.path("src/screen.zig") });
    fw.add_app_import("screen", screen, .{ .depend_on_microzig = true });
}

/// Host tests for an example's `test` step: every `.zig` file under its `src/` and under
/// common's `src/` that holds a top-level `test` block.
///
/// Found by scanning rather than listed, so a new test file can't be left out (a hand-kept
/// list once missed one). Configure re-runs when a file or directory there changes, so a
/// test added later is picked up too. A file with tests must therefore compile on the host
/// on its own: keep tests in pure modules.
///
/// Each file runs twice: in Debug, and in ReleaseSmall like the firmware, where asserts are
/// gone and only `@setRuntimeSafety(true)` code keeps its checks. Each can import
/// `mutations` (src/testing/mutations.zig), the negative-space input generator.
pub fn add_tests(b: *std.Build, step: *std.Build.Step) void {
    const common = b.dependency("common", .{}).builder;
    add_tests_under(b, b, step);
    add_tests_under(b, common, step);
}

const mutations_path = "src/testing/mutations.zig";

fn add_tests_under(b: *std.Build, pkg: *std.Build, step: *std.Build.Step) void {
    const common = b.dependency("common", .{}).builder;
    const io = b.graph.io;
    const root_path = if (pkg.root.sub_path.len == 0) "." else pkg.root.sub_path;
    const root = pkg.root.root_dir.handle.openDir(io, root_path, .{}) catch |err|
        std.debug.panic("opening {s}: {t}", .{ root_path, err });
    defer root.close(io);
    const src = root.openDir(io, "src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => std.debug.panic("opening src/: {t}", .{err}),
    };
    defer src.close(io);
    b.dependOnDirectoryContents(pkg.path("src"));

    var walker = src.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("listing src/: {t}", .{err})) |entry| {
        const sub_path = b.fmt("src/{s}", .{entry.path});
        switch (entry.kind) {
            .directory => b.dependOnDirectoryContents(pkg.path(sub_path)),
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                b.dependOnFileContents(pkg.path(sub_path));
                const limit: std.Io.Limit = .limited(1 << 20);
                const text = src.readFileAlloc(io, entry.path, b.allocator, limit) catch |err|
                    std.debug.panic("reading {s}: {t}", .{ sub_path, err });
                // Any top-level test: `test "name" {`, `test decl {` or `test {`.
                const has_test = std.mem.startsWith(u8, text, "test ") or
                    std.mem.indexOf(u8, text, "\ntest ") != null;
                if (!has_test) continue;
                // The generator's own test can't import itself: a file belongs to one module.
                const is_mutations = pkg == common and std.mem.eql(u8, sub_path, mutations_path);
                for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSmall }) |mode| {
                    const module = b.createModule(.{
                        .root_source_file = pkg.path(sub_path),
                        .target = b.graph.host,
                        .optimize = mode,
                    });
                    if (!is_mutations) module.addImport("mutations", b.createModule(.{
                        .root_source_file = common.path(mutations_path),
                        .target = b.graph.host,
                        .optimize = mode,
                    }));
                    const t = b.addTest(.{
                        .name = b.fmt("{s}-{t}", .{ std.fs.path.stem(entry.basename), mode }),
                        .root_module = module,
                    });
                    step.dependOn(&b.addRunArtifact(t).step);
                }
            },
            else => {},
        }
    }
}
