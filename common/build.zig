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

    const net = b.createModule(.{ .root_source_file = common.path("src/net.zig") });
    net.addImport("lwip", lwip);
    net.addImport("config", opts.config);
    fw.add_app_import("net", net, .{ .depend_on_microzig = true });

    // HTTPS on top of it (TLS 1.3, see src/https.zig for what the firmware must provide).
    // Only compiled into firmware that imports it.
    const https = b.createModule(.{ .root_source_file = common.path("src/https.zig") });
    https.addImport("net", net);
    fw.add_app_import("https", https, .{ .depend_on_microzig = true });
    return true;
}

/// Host tests of common's pure parts (HTTP framing, SNTP), for an example's `test` step.
pub fn add_tests(b: *std.Build, step: *std.Build.Step) void {
    const common = b.dependency("common", .{});
    for ([_][]const u8{ "src/https/http.zig", "src/https/sntp.zig" }) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = common.path(file),
            .target = b.graph.host,
        }) });
        step.dependOn(&b.addRunArtifact(t).step);
    }
}
