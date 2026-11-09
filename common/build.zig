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
    return true;
}
