const std = @import("std");
const microzig = @import("microzig");
const common = @import("common");

const MicroBuild = microzig.MicroBuild(.{
    .esp = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Credentials are build options so they never end up in the source. Pass them on the
    // command line, in your own terminal.
    const options = b.addOptions();
    options.addOption([]const u8, "ssid", b.option([]const u8, "ssid", "Wi-Fi SSID") orelse "Wokwi-GUEST");
    options.addOption([]const u8, "password", b.option([]const u8, "password", "Wi-Fi password (empty: open network)") orelse "");
    // A Netatmo app (dev.netatmo.com): its client id and secret, and a first refresh token
    // with read_thermostat and write_thermostat. The refresh token is used once: Netatmo
    // replaces it on every refresh, and the board keeps the new one in flash.
    options.addOption([]const u8, "client_id", b.option([]const u8, "netatmo_client_id", "Netatmo app client id") orelse "");
    options.addOption([]const u8, "client_secret", b.option([]const u8, "netatmo_client_secret", "Netatmo app client secret") orelse "");
    options.addOption([]const u8, "refresh_token", b.option([]const u8, "netatmo_refresh_token", "First refresh token (used when flash has none)") orelse "");
    // Wokwi's flash starts blank on every run, so the rotated token would be lost: this logs
    // it, to rebuild with. A credential in the log: off by default.
    options.addOption(bool, "log_token", b.option(bool, "netatmo_log_token", "Log the new refresh token (for Wokwi)") orelse false);
    // Optional write test: set this room to this temperature for 10 min, check, then back to
    // the schedule.
    options.addOption([]const u8, "test_room", b.option([]const u8, "netatmo_test_room", "Room id for the setpoint test") orelse "");
    options.addOption([]const u8, "test_temp", b.option([]const u8, "netatmo_test_temp", "Setpoint for the test, e.g. 19.5") orelse "");

    // The ILI9341 + FT6206 touch screen (wired as in ../hue), and a demo with made-up rooms
    // and a scripted finger, to look at the screen without credentials or a network.
    options.addOption(bool, "screen", b.option(bool, "screen", "Touch screen (default: true)") orelse true);
    options.addOption(bool, "demo", b.option(bool, "demo", "Demo: made-up rooms, no network") orelse false);

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "netatmo",
        .target = mb.ports.esp.chips.esp32_c6,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    const config = options.createModule();
    fw.exe.root_module.addImport("config", config);

    // Wi-Fi, lwIP and HTTPS (../common).
    if (!common.add_net(b, mz_dep, fw, .{ .optimize = optimize, .config = config })) return;
    common.add_screen(b, fw);

    mb.install_firmware(fw, .{});
    mb.install_firmware(fw, .{ .format = .elf });

    // Host tests (the Energy API readers, common's pure parts), in Debug and ReleaseSmall.
    common.add_tests(b, b.step("test", "Run the host tests"));
}
