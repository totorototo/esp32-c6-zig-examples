//! hue: toggle a Philips Hue light from the ESP32-C6 through the bridge's local API.
//!
//!   1. Fetches `/api/config` and logs the bridge name (no pairing needed).
//!   2. Without `-Dhue_user`: pairing mode. Press the bridge's link button; the board logs
//!      the username to rebuild with.
//!   3. With `-Dhue_user`: lists the lights. With `-Dhue_light` too, the BOOT button (GPIO9)
//!      toggles that light, and the on-board LED mirrors its state.
//! Logs go to UART0 (115200 baud).
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");
const net = @import("net.zig");
const hue = @import("hue.zig");

const hal = microzig.hal;
const gpio = hal.gpio;
const rtos = hal.rtos;
const radio = hal.radio;
const WS2812 = microzig.drivers.led.WS2812;
const Color = microzig.drivers.led.ws2812.Color;

comptime {
    _ = net.exports;
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    },
    .logFn = uart_log,
});

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{ .wifi = .{ .on_packet_received = net.on_packet_received } },
    },
};

var log_mutex: rtos.Mutex = .{};
var log_buf: [256]u8 = undefined;

fn uart_log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    const prefix = comptime "[" ++ level.asText() ++ "] " ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    const line = std.fmt.bufPrint(&log_buf, prefix ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

const devicetype = "microzig_hue#esp32c6";
const button = gpio.num(9); // BOOT button on the DevKitC-1, active low
const poll_ms = 20;
const refresh_ms = 5000;

const Led = WS2812(.{ .max_led_count = 1, .DatagramDevice = hal.drivers.SPI_Device });
var led: Led = undefined;

var heap: microzig.Allocator = undefined;

pub fn main() !void {
    std.log.info("hue on ESP32-C6, bridge {s}", .{config.hue_ip});
    init_led();
    show(.{ .r = 0, .g = 0, .b = 8 }); // blue: starting up
    button.apply(.{ .input_enable = true, .pull = .up });

    heap = try .init_with_heap(16384);
    try net.up(heap.allocator());

    const bridge = try hue.Bridge.init(config.hue_ip);
    {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        const cfg = hue.get_config(arena.allocator(), bridge) catch |err| {
            std.log.err("bridge at {s} not reachable: {t}", .{ config.hue_ip, err });
            show(.{ .r = 16, .g = 0, .b = 0 });
            return err;
        };
        std.log.info("bridge `{s}` id {s}, API {s}", .{ cfg.name, cfg.bridgeid, cfg.apiversion });
    }

    if (config.hue_user.len == 0) return pair(bridge);

    try list_lights(bridge);
    if (config.hue_light.len == 0) {
        std.log.info("rebuild with -Dhue_light=<id> to toggle one of these with the BOOT button", .{});
        show(.{ .r = 0, .g = 8, .b = 0 });
        return;
    }
    try control(bridge);
}

fn pair(bridge: hue.Bridge) !void {
    std.log.info("pairing: press the round link button on the bridge (trying for 60 s)", .{});
    show(.{ .r = 16, .g = 8, .b = 0 });
    for (0..30) |_| {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        if (try hue.create_user(arena.allocator(), bridge, devicetype)) |user| {
            // The username is a bridge credential: it goes on the build command line only.
            std.log.info("paired. Rebuild with: zig build -Doptimize=ReleaseSmall -Dhue_user={s}", .{user});
            show(.{ .r = 0, .g = 8, .b = 0 });
            return;
        }
        rtos.sleep(.from_ms(2000));
    }
    std.log.err("link button not pressed in time; restart to try again", .{});
    show(.{ .r = 16, .g = 0, .b = 0 });
}

fn list_lights(bridge: hue.Bridge) !void {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    const lights = try hue.get_lights(arena.allocator(), bridge, config.hue_user);
    std.log.info("{} lights:", .{lights.map.count()});
    var it = lights.map.iterator();
    while (it.next()) |e| {
        const s = e.value_ptr.state;
        std.log.info("  {s}: {s} ({s}{s})", .{ e.key_ptr.*, e.value_ptr.name, if (s.on) "on" else "off", if (s.reachable) "" else ", unreachable" });
    }
}

fn control(bridge: hue.Bridge) !void {
    const initial = try fetch(bridge);
    var on = initial.on;
    std.log.info("light {s} is {s}", .{ config.hue_light, if (on) "on" else "off" });
    var was_pressed = false;
    var handled = false; // this press already toggled; wait for release
    var since_refresh: u32 = 0;
    std.log.info("press BOOT to toggle light {s}", .{config.hue_light});

    while (true) : (rtos.sleep(.from_ms(poll_ms))) {
        // Debounce: a press counts once, when the pin reads low on two polls in a row.
        const pressed = button.read() == 0;
        defer was_pressed = pressed;
        if (!pressed) handled = false;

        if (pressed and was_pressed and !handled) {
            handled = true;
            var arena: std.heap.ArenaAllocator = .init(heap.allocator());
            defer arena.deinit();
            if (hue.set_on(arena.allocator(), bridge, config.hue_user, config.hue_light, !on)) {
                on = !on;
                std.log.info("light {s} -> {s}", .{ config.hue_light, if (on) "on" else "off" });
                show_state(on);
            } else |err| std.log.err("toggle failed: {t}", .{err});
            since_refresh = 0;
            continue;
        }

        // Pick up changes made from the Hue app or a wall switch.
        since_refresh += poll_ms;
        if (since_refresh < refresh_ms) continue;
        since_refresh = 0;
        const state = fetch(bridge) catch |err| {
            std.log.warn("refresh failed: {t}", .{err});
            continue;
        };
        if (state.on != on) {
            on = state.on;
            std.log.info("light {s} is now {s} (changed elsewhere)", .{ config.hue_light, if (on) "on" else "off" });
        }
    }
}

fn fetch(bridge: hue.Bridge) !hue.LightState {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    const light = try hue.get_light(arena.allocator(), bridge, config.hue_user, config.hue_light);
    std.log.debug("light {s} `{s}`: {s}", .{ config.hue_light, light.name, if (light.state.on) "on" else "off" });
    show_state(light.state.on);
    return light.state;
}

fn show_state(on: bool) void {
    show(if (on) .{ .r = 24, .g = 12, .b = 2 } else .{ .r = 0, .g = 0, .b = 0 });
}

fn init_led() void {
    const pin = gpio.num(8);
    const spi = hal.spi.instance.SPI2;
    pin.apply(.{ .output_enable = true });
    spi.connect_pins(.{ .data = .{ .single_one_wire = pin } });
    spi.apply(.{ .clock_config = hal.clock_config, .baud_rate = 3_000_000, .bit_order = .msb_first });
    led = .init(.init(spi, .single_one_wire, null), hal.drivers.clock_device());
}

fn show(color: Color) void {
    led.write(&.{color}) catch {};
}
