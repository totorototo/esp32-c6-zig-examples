//! The screen's backlight, on LEDC PWM (the panel's LED pin on GPIO3): full while the
//! remote is in use, dimmed after `idle_ms` without a touch. The touch that wakes it only
//! wakes it: a dimmed remote on a wall gets brushed past, and that shouldn't switch the
//! lights.
const microzig = @import("microzig");
const hal = microzig.hal;

const pin = hal.gpio.num(3);
const timer = hal.ledc.timer(0);
const channel = hal.ledc.channel(0);

const precision = 10;
const full: u15 = (1 << precision) - 1;
/// About 6%: readable in a dark room, out of the way in a bright one.
const dim: u15 = full / 16;
const idle_ms = 30_000;

var last_activity: u64 = 0;
var dimmed = false;

pub fn init() void {
    pin.apply(.{ .output_enable = true });
    channel.connect_pin(pin);
    hal.ledc.apply(.apb_clk);
    // 5 kHz: above what eyes or the camera of a phone see flicker at.
    timer.apply(.{ .clock_config = hal.clock_config, .frequency = 5000, .precision = precision }, .apb_clk);
    channel.apply(.{ .timer = timer, .initial_duty = full });
}

/// Someone is using the remote. Returns true if the backlight was dimmed: the caller then
/// ignores that touch.
pub fn wake(t: u64) bool {
    last_activity = t;
    if (!dimmed) return false;
    dimmed = false;
    channel.set_duty(full);
    return true;
}

/// Call every tick.
pub fn tick(t: u64) void {
    if (last_activity == 0) last_activity = t;
    if (!dimmed and t - last_activity >= idle_ms) {
        dimmed = true;
        channel.set_duty(dim);
    }
}
