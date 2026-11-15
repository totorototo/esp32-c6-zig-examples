const std = @import("std");
const microzig = @import("microzig");
const common = @import("common");

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
    // The UART0 logger and the chip reset, shared with the other samples (../common).
    _ = common.add_base(b, fw);

    // zig-out/firmware/oled.bin: ESP image, flashable after the ESP-IDF 2nd stage bootloader
    mb.install_firmware(fw, .{});
    // zig-out/firmware/oled.elf: for espflash, Wokwi and debugging
    mb.install_firmware(fw, .{ .format = .elf });

    // The font and common's pure parts run on the host, in Debug and in ReleaseSmall like
    // the firmware. Every src/ file with tests is found, as in the other samples.
    common.add_tests(b, b.step("test", "Run the host tests"));
}
