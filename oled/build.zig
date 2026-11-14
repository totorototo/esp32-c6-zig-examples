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
        .name = "oled",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    // zig-out/firmware/oled.bin: ESP image, flashable after the ESP-IDF 2nd stage bootloader
    mb.install_firmware(fw, .{});
    // zig-out/firmware/oled.elf: for espflash, Wokwi and debugging
    mb.install_firmware(fw, .{ .format = .elf });

    // The font runs on the host, in Debug and in ReleaseSmall like the firmware.
    const test_step = b.step("test", "Run the host tests");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSmall }) |mode| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/font.zig"),
            .target = b.graph.host,
            .optimize = mode,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
