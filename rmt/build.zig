const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // On-board LED level, 1..255, as in ../hue. A WS2812 at full power is blinding on a desk,
    // but Wokwi draws the raw value, so low levels look black there: use 255 in the simulator.
    const options = b.addOptions();
    const led_level = b.option(u8, "led_level", "On-board LED level 1..255 (default: 40)");
    options.addOption(u8, "led_level", led_level orelse 40);

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "rmt",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    fw.exe.root_module.addImport("config", options.createModule());

    // zig-out/firmware/rmt.bin: ESP image, flashable after the ESP-IDF 2nd stage bootloader
    mb.install_firmware(fw, .{});
    // zig-out/firmware/rmt.elf: for espflash, Wokwi and debugging
    mb.install_firmware(fw, .{ .format = .elf });
}
