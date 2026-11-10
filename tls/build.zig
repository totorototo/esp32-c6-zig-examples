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

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "tls",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    const config = options.createModule();
    fw.exe.root_module.addImport("config", config);

    // Wi-Fi, lwIP and HTTPS, shared with the other Wi-Fi examples (../common).
    if (!common.add_net(b, mz_dep, fw, .{ .optimize = optimize, .config = config })) return;

    mb.install_firmware(fw, .{});
    mb.install_firmware(fw, .{ .format = .elf });

    // Host tests of the HTTPS stack's pure parts (in ../common).
    common.add_tests(b, b.step("test", "Run the host tests"));
}
