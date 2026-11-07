const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "blinky",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    // zig-out/firmware/blinky.bin: ESP image, flashable after the ESP-IDF 2nd stage bootloader
    mb.install_firmware(fw, .{});
    // zig-out/firmware/blinky.elf: for espflash, Wokwi and debugging
    mb.install_firmware(fw, .{ .format = .elf });
}
