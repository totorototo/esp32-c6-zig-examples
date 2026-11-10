const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    // The same firmware for the C6's three boot paths.
    const variants = [_]struct { name: []const u8, mode: []const u8, target: *const microzig.Target }{
        // ESP app image behind the 2nd stage bootloader (espflash flash, Wokwi).
        .{ .name = "boot_image", .mode = "image", .target = mb.ports.esp.chips.esp32_c6 },
        // Raw binary at flash offset 0, started by the ROM (espflash write-bin 0x0).
        .{ .name = "boot_direct", .mode = "direct boot", .target = mb.ports.esp.chips.esp32_c6_direct_boot },
        // RAM only, loaded over serial (espflash flash --ram).
        .{ .name = "boot_ram", .mode = "flashless", .target = mb.ports.esp.chips.esp32_c6_flashless },
    };

    for (variants) |v| {
        const options = b.addOptions();
        options.addOption([]const u8, "mode", v.mode);
        const fw = mb.add_firmware(.{
            .name = v.name,
            .target = v.target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        });
        fw.exe.root_module.addImport("config", options.createModule());

        // Each target's own format: ESP image, raw binary, ESP image of RAM segments.
        mb.install_firmware(fw, .{});
        mb.install_firmware(fw, .{ .format = .elf });
    }
}
