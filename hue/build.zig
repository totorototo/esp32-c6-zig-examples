const std = @import("std");
const microzig = @import("microzig");
const common = @import("common");

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
    // Touch screen (ILI9341 + FT6206). It takes SPI2 from the on-board LED.
    options.addOption(bool, "screen", b.option(bool, "screen", "ILI9341 + FT6206 touch screen (default: true)") orelse true);
    options.addOption([]const u8, "hue_light", b.option([]const u8, "hue_light", "Light id to open on (required with -Dscreen=false)") orelse "");

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "hue",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    const config = options.createModule();
    fw.exe.root_module.addImport("config", config);

    // Wi-Fi, lwIP and the HTTP helpers, shared with the other Wi-Fi example (../common).
    if (!common.add_net(b, mz_dep, fw, .{ .optimize = optimize, .config = config })) return;

    mb.install_firmware(fw, .{});
    mb.install_firmware(fw, .{ .format = .elf });
}
