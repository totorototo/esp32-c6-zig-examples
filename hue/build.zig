const std = @import("std");
const microzig = @import("microzig");
const common = @import("common");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

const Ui = enum { list, field };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Wi-Fi credentials are build options so they never end up in the source.
    // Defaults join Wokwi's simulated open access point.
    const options = b.addOptions();
    options.addOption([]const u8, "ssid", b.option([]const u8, "ssid", "Wi-Fi SSID") orelse "Wokwi-GUEST");
    options.addOption([]const u8, "password", b.option([]const u8, "password", "Wi-Fi password (empty: open network)") orelse "");
    // Hue bridge settings. Both are optional: without them the board finds the bridge over
    // mDNS, pairs, and saves both in flash. Given, they win over what is saved.
    options.addOption([]const u8, "hue_ip", b.option([]const u8, "hue_ip", "Hue bridge IPv4 address (default: saved, else mDNS search)") orelse "");
    options.addOption([]const u8, "hue_user", b.option([]const u8, "hue_user", "Hue API username (default: saved, else pairing)") orelse "");
    // On-board LED level, 1..255. A WS2812 at full power is blinding on a desk, but Wokwi
    // draws the raw value, so low levels look black there: use 255 in the simulator.
    options.addOption(u8, "led_level", b.option(u8, "led_level", "On-board LED level 1..255 (default: 40)") orelse 40);
    // Touch screen (ILI9341 + FT6206) on SPI2; the LED is on RMT, so both work.
    options.addOption(bool, "screen", b.option(bool, "screen", "ILI9341 + FT6206 touch screen (default: true)") orelse true);
    // The touch UI: lists and a settings page, or the gesture-only experiment (src/field.zig).
    options.addOption(Ui, "ui", b.option(Ui, "ui", "Touch UI: list (default) or field (experimental, gestures only)") orelse .list);
    // Made-up rooms instead of Wi-Fi and a bridge, to look at the UI in a simulator. The
    // field UI also plays its gestures by itself.
    options.addOption(bool, "demo", b.option(bool, "demo", "Demo: made-up rooms, no network") orelse false);
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

    // The pure parts (mDNS packets, the scenes JSON, UTF-8 folding) run on the host:
    // `zig build test`.
    const test_step = b.step("test", "Run the host tests");
    for ([_][]const u8{ "src/mdns.zig", "src/scenes.zig", "src/font.zig" }) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = b.graph.host,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
