const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Wi-Fi credentials are build options so they never end up in the source.
    // Defaults join Wokwi's simulated open access point.
    const options = b.addOptions();
    options.addOption([]const u8, "ssid", b.option([]const u8, "ssid", "Wi-Fi SSID") orelse "Wokwi-GUEST");
    options.addOption([]const u8, "password", b.option([]const u8, "password", "Wi-Fi password (empty: open network)") orelse "");
    // Hue bridge settings. The username is a bridge credential: pass it on the command line only.
    options.addOption([]const u8, "hue_ip", b.option([]const u8, "hue_ip", "Hue bridge IPv4 address") orelse "192.168.1.125");
    options.addOption([]const u8, "hue_user", b.option([]const u8, "hue_user", "Hue API username (empty: pairing mode)") orelse "");
    options.addOption([]const u8, "hue_light", b.option([]const u8, "hue_light", "Light id to toggle (empty: just list lights)") orelse "");

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "hue",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    fw.exe.root_module.addOptions("config", options);

    // lwIP, built against our lwipopts.h, plus the small libc it needs.
    const target = b.resolveTargetQuery(fw.target.zig_target);
    const foundation_dep = b.dependency("foundation_libc", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const lwip_dep = b.dependency("lwip", .{
        .target = target,
        .optimize = optimize,
        .include_dir = b.path("src/lwip/include"),
    });
    const lwip = lwip_dep.module("lwip");
    lwip.linkLibrary(foundation_dep.artifact("foundation"));
    fw.exe.root_module.addImport("lwip", lwip);

    mb.install_firmware(fw, .{});
    mb.install_firmware(fw, .{ .format = .elf });
}
