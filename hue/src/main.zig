//! hue: a Philips Hue remote on the ESP32-C6, through the bridge's local API.
//!
//!   1. Finds the bridge: `-Dhue_ip`, else the address saved in flash, else an mDNS search.
//!      Fetches `/api/config` and logs the bridge name (no pairing needed).
//!   2. Gets a username: `-Dhue_user`, else the one saved in flash, else pairing (press the
//!      bridge's link button). A paired username is saved, so pairing happens once.
//!   3. Logs the lights, rooms, zones and scenes, then controls them:
//!      - Touch screen (ILI9341 + FT6206, `-Dscreen=true`, the default): rooms first, each
//!        with its brightness, colour, scenes and lights (list.zig), and every light. It
//!        reopens on the last one open (or `-Dhue_light`), and dims when left alone.
//!      - Web remote on port 80, on the selected entry: on/off, brightness, colour.
//!      - The on-board LED (RMT, GPIO8) shows the status, then mirrors the selected entry.
//!      What's on screen is refreshed every 5 s.
//!   The BOOT button: a short press turns every light off. Held 3 s, the screen asks
//!   whether to forget the bridge and the username (held 10 s, or `POST /forget`, it just
//!   does), then restarts.
//! Logs go to UART0 (115200 baud).
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");
const net = @import("net");
const hue = @import("hue.zig");
const web = net.web;
const ui = @import("ui.zig");
const catalog = @import("catalog.zig");
const bridge_task = @import("bridge.zig");
/// The touch UI: rooms and lights with a page each (`-Dui=list`), or the gesture-only experiment
/// (`-Dui=field`). Both have the same interface.
const touch_ui = switch (config.ui) {
    .list => @import("list.zig"),
    .field => @import("field.zig"),
};
const ili9341 = @import("screen").lcd;
const ft6206 = @import("screen").touch;
const settings = @import("settings.zig");
const protocol = @import("protocol.zig");
const system = @import("system");
const backlight = @import("screen").backlight;
const lwip = net.lwip;

const hal = microzig.hal;
const gpio = hal.gpio;
const rtos = hal.rtos;
const radio = hal.radio;
const rmt = hal.rmt;
const WS2812 = hal.drivers.WS2812_RMT;
const Color = WS2812.Color;

comptime {
    _ = net.exports;
    _ = microzig.export_startup();
}

pub const panic = microzig.panic;

pub const std_options = net.std_options(&.{});

pub const microzig_options = net.microzig_options;

const devicetype = "microzig_hue#esp32c6";
const poll_ms = 20;
const refresh_ms = 5000;

// Touch screen wiring. GPIO22/23 match the OLED demo; none of these are strapping, JTAG or
// USB pins. MISO and the touch INT pin stay unconnected; the backlight (LED) is on GPIO3,
// dimmed by PWM (backlight.zig).
const screen_pins: ili9341.Pins = .{
    .sck = gpio.num(19),
    .mosi = gpio.num(18),
    .cs = gpio.num(20),
    .dc = gpio.num(21),
    .rst = gpio.num(2),
};
const touch_sda = gpio.num(22);
const touch_scl = gpio.num(23);

// The on-board WS2812 through RMT, so it works next to the screen (which takes SPI2).
const led_pin = gpio.num(8);
const led_channel = rmt.instance.TX0;
const rmt_config: rmt.Config = .{ .clock_config = hal.clock_config };
const led_channel_config: rmt.Tx.Config = .{};
var led: WS2812 = undefined;

/// The BOOT button: low while pressed (pulled up on the board). A short press turns all
/// lights off; held, it forgets the saved bridge and username.
const boot_button = gpio.num(9);
/// Released before this: all off.
const short_press_ms = 800;
/// Held this long: the screen asks (FORGET / CANCEL).
const ask_hold_ms = 3000;
/// Held this long: forgotten without asking (no screen, the field UI, or before the UI runs).
const forget_hold_ms = 10_000;

var heap: microzig.Allocator = undefined;

var user_buf: [64]u8 = undefined;

pub fn main() !void {
    std.log.info("hue on ESP32-C6", .{});
    init_led();
    if (config.screen) {
        backlight.init();
        ili9341.init(screen_pins);
        if (ft6206.init(touch_sda, touch_scl)) {
            touch_ui.touch_ok = true;
        } else |err| std.log.warn("touch controller not found ({t}): screen is display-only", .{err});
    }
    boot_button.apply(.{ .input_enable = true, .pull = .up });
    settings.init();
    status(.busy, "CONNECTING");

    heap = try .init_with_heap(16384);
    // Decided at runtime on purpose: with a comptime `if`, the rest of main would be dead
    // code, and lwIP's allocator (set up through net.up) would be dropped at link time.
    var demo_mode = config.demo;
    _ = &demo_mode;
    if (demo_mode) demo();
    try net.up(heap.allocator());

    const bridge = try find_bridge();

    var from_flash = false;
    const user: []const u8 = if (config.hue_user.len > 0) config.hue_user else if (settings.get(.user, &user_buf)) |u| blk: {
        from_flash = true;
        break :blk u;
    } else try pair(bridge);

    const ctx: bridge_task.Context = .{ .bridge = bridge, .user = user, .allocator = heap.allocator() };
    while (true) {
        if (bridge_task.run_now(ctx, .{ .list = .light })) |_| break else |err| {
            // The common cause: a username from another bridge, or one deleted in the Hue app.
            if (err == error.BridgeError) {
                if (from_flash) {
                    std.log.err("the bridge rejected the saved username: forgetting it, pairing again", .{});
                    settings.erase(.user);
                    restart();
                }
                std.log.err("the bridge rejected -Dhue_user: rebuild without it to pair again", .{});
                halt(.failed, "BRIDGE REJECTED\nTHE USERNAME");
            }
            // Anything else (a timeout, a bridge busy rebooting) can pass: try again.
            std.log.warn("lights not read ({t}): retrying in {} s", .{ err, retry_ms / 1000 });
            status(.failed, "BRIDGE NOT\nRESPONDING");
            wait_or_forget(retry_ms);
        }
    }
    read_rest(ctx);

    if (config.hue_light.len > 0) {
        if (!catalog.select_id(.light, config.hue_light)) {
            std.log.err("no light {s} on this bridge: rebuild with another -Dhue_light", .{config.hue_light});
            halt(.failed, "NO SUCH LIGHT\nSEE THE LOG");
        }
    } else {
        // The light or room last opened, if it still exists.
        var buf: [16]u8 = undefined;
        if (settings.get(.selected, &buf)) |sel| if (sel.len > 1) {
            const kind: hue.Kind = if (sel[0] == 'g') .group else .light;
            _ = catalog.select_id(kind, sel[1..]);
        };
    }
    if (catalog.selected()) |e| {
        if (config.screen) touch_ui.open(e);
    } else if (!config.screen) {
        // Without the screen, nothing else can pick a light.
        std.log.info("rebuild with -Dhue_light=<id> to control one of these", .{});
        halt(.ok, "LIGHTS LISTED\nSEE THE LOG");
    }
    try control(ctx);
}

/// Rooms and scenes, once the lights are read: without them the remote still works, on
/// lights only.
fn read_rest(ctx: bridge_task.Context) void {
    bridge_task.run_now(ctx, .{ .list = .group }) catch |err|
        std.log.warn("rooms and zones not read: {t}", .{err});
    bridge_task.run_now(ctx, .scenes) catch |err| std.log.warn("scenes not read: {t}", .{err});
    catalog.log_all();
}

/// The bridge to talk to: `-Dhue_ip`, else the saved address if the bridge still answers
/// there, else the first one found by mDNS. The one that answers is saved.
///
/// Never gives up: after a power cut the board boots faster than the bridge, and a remote
/// that stopped at "no bridge" would stay dead until someone resets it. Holding BOOT while
/// it waits forgets the saved address.
fn find_bridge() !hue.Bridge {
    const fixed: ?hue.Bridge = if (config.hue_ip.len > 0) try hue.Bridge.init(config.hue_ip) else null;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        if (try_bridge(fixed)) |b| return b;
        if (attempt == 0) {
            if (fixed) |b| {
                std.log.err("no bridge answering at {s} (-Dhue_ip): retrying every {} s", .{ b.host(), retry_ms / 1000 });
            } else {
                std.log.err("no Hue bridge found on this network: retrying every {} s. " ++
                    "Where mDNS can't reach the LAN (Wokwi), rebuild with -Dhue_ip=<address>", .{retry_ms / 1000});
            }
        }
        status(.failed, if (fixed != null) "BRIDGE NOT\nREACHABLE" else "NO BRIDGE FOUND\nRETRYING");
        wait_or_forget(retry_ms);
    }
}

const retry_ms = 10_000;

fn try_bridge(fixed: ?hue.Bridge) ?hue.Bridge {
    if (fixed) |b| {
        if (!reach(b)) return null;
        // Not saved: the next boot searches again, which only costs time.
        _ = settings.set(.bridge_ip, b.host());
        return b;
    }

    var buf: [16]u8 = undefined;
    if (settings.get(.bridge_ip, &buf)) |ip| {
        if (hue.Bridge.init(ip)) |b| {
            if (reach(b)) return b;
            std.log.warn("no bridge at the saved address {s}: searching", .{ip});
        } else |_| settings.erase(.bridge_ip);
    }

    status(.busy, "SEARCHING\nFOR THE BRIDGE");
    std.log.info("searching for a Hue bridge (mDNS _hue._tcp.local)", .{});
    const found = hue.discover(3) catch |err| {
        std.log.warn("mDNS search failed: {t}", .{err});
        return null;
    } orelse return null;
    std.log.info("found a bridge at {s}", .{found.host()});
    if (!reach(found)) return null;
    _ = settings.set(.bridge_ip, found.host()); // not saved: the next boot searches again
    return found;
}

/// Sleeps `ms`, restarting from scratch if BOOT is held for `forget_hold_ms` meanwhile.
fn wait_or_forget(ms: u32) void {
    const step = 100;
    var held: u32 = 0;
    for (0..ms / step) |_| {
        rtos.sleep(.from_ms(step));
        held = if (boot_button.read() == 0) held + step else 0;
        if (held >= forget_hold_ms) forget();
    }
}

/// Fetches `/api/config` (no username needed) and logs who answered.
fn reach(b: hue.Bridge) bool {
    var arena: std.heap.ArenaAllocator = .init(heap.allocator());
    defer arena.deinit();
    const cfg = hue.get_config(arena.allocator(), b) catch |err| {
        std.log.warn("no bridge answering at {s}: {t}", .{ b.host(), err });
        return false;
    };
    std.log.info("bridge `{s}` at {s}, id {s}, API {s}", .{ cfg.name, b.host(), cfg.bridgeid, cfg.apiversion });
    return true;
}

/// Pairs with the bridge and saves the username. Waits for the link button as long as it
/// takes: someone setting the remote up may be anywhere in the house.
fn pair(bridge: hue.Bridge) ![]const u8 {
    std.log.info("pairing: press the round link button on the bridge", .{});
    status(.waiting, "PRESS THE LINK\nBUTTON ON BRIDGE");
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(heap.allocator());
        defer arena.deinit();
        if (try hue.create_user(arena.allocator(), bridge, devicetype)) |user| {
            if (user.len > user_buf.len) return error.BadResponse;
            @memcpy(user_buf[0..user.len], user);
            // A bridge credential: saved in flash and logged once, never shown on screen.
            // The log line is for Wokwi, whose flash starts blank on every run.
            const saved = settings.set(.user, user);
            if (!saved) std.log.warn("username NOT saved: the next boot will pair again", .{});
            std.log.info("paired{s}. To skip pairing where flash isn't kept (Wokwi): -Dhue_user={s}", .{
                if (saved) ", username saved" else "", user,
            });
            status(.ok, "PAIRED");
            return user_buf[0..user.len];
        }
        wait_or_forget(2000);
    }
}

/// For what the board can't fix by itself (a build option that doesn't match the bridge):
/// shows `text` and stays there. Holding BOOT still forgets the settings and restarts.
fn halt(kind: Status, text: []const u8) noreturn {
    status(kind, text);
    while (true) wait_or_forget(60_000);
}

/// Forgets what pairing and discovery saved, then restarts.
fn forget() noreturn {
    std.log.info("forgetting the bridge and the username", .{});
    settings.erase(.user);
    settings.erase(.bridge_ip);
    settings.erase(.selected);
    status(.waiting, "FORGOTTEN\nRESTARTING");
    restart();
}

fn restart() noreturn {
    rtos.sleep(.from_ms(500)); // let the log and the screen catch up
    system.reset(); // the whole chip, radio included
}

// ---- demo: no Wi-Fi, no bridge, made-up rooms (-Ddemo=true) ----

/// Runs the touch UI on made-up rooms, for looking at it in a simulator. The field UI also
/// plays its gestures by itself, so it can be watched without a hand.
fn demo() noreturn {
    std.log.info("demo: made-up rooms, no bridge", .{});
    catalog.offline = true;
    const rooms = [_]struct { []const u8, []const u8, hue.LightState }{
        .{ "1", "Salon", .{ .on = true, .bri = 200, .hue = 7000, .sat = 160 } },
        .{ "3", "Bureau", .{ .on = true, .bri = 110, .hue = 46000, .sat = 200 } },
        .{ "5", "Chambre Aloïse", .{ .on = false, .bri = 90, .hue = 56000, .sat = 230 } },
        .{ "2", "Salle à manger", .{ .on = true, .bri = 254 } },
        .{ "83", "Séjour", .{ .on = true, .bri = 40, .hue = 1000, .sat = 254 } },
    };
    for (rooms) |r| catalog.add(&catalog.groups, .group, r[0], r[1], r[2]);
    const lights = [_]struct { []const u8, []const u8, hue.LightState }{
        .{ "2", "Hue color spot 1", .{ .on = true, .bri = 200, .hue = 7000, .sat = 160 } },
        .{ "4", "Hue color spot 2", .{ .on = true, .bri = 200, .hue = 7000, .sat = 160 } },
        .{ "6", "Lampadaire", .{ .on = false, .bri = 120 } },
        .{ "3", "Étoile", .{ .on = false, .bri = 120 } },
        .{ "7", "Bureau", .{ .on = true, .bri = 110, .hue = 46000, .sat = 200 } },
        .{ "8", "Veilleuse", .{ .on = false, .bri = 90, .hue = 56000, .sat = 230 } },
        .{ "9", "Prise café", .{ .on = false, .reachable = false } },
    };
    for (lights) |l| catalog.add(&catalog.lights, .light, l[0], l[1], l[2]);
    catalog.groups.items[0].set_members(&.{ "2", "4", "6", "9" }); // Salon
    catalog.groups.items[1].set_members(&.{"7"}); // Bureau
    catalog.groups.items[2].set_members(&.{ "3", "8" }); // Chambre
    const scenes = [_]struct { []const u8, []const u8, []const u8, ui.Rgb, u8 }{
        .{ "s1", "Détente", "1", .{ .r = 255, .g = 160, .b = 80 }, 150 },
        .{ "s2", "Lecture", "1", .{ .r = 255, .g = 225, .b = 180 }, 254 },
        .{ "s3", "Horizon", "1", .{ .r = 255, .g = 110, .b = 60 }, 190 },
        .{ "s4", "Explosion de couleurs", "1", .{ .r = 190, .g = 60, .b = 255 }, 220 },
        .{ "s5", "Vent de montagne", "1", .{ .r = 110, .g = 200, .b = 255 }, 200 },
        .{ "s6", "Nuit", "1", .{ .r = 70, .g = 40, .b = 160 }, 30 },
        .{ "s7", "Repos", "1", .{ .r = 255, .g = 140, .b = 60 }, 90 },
        .{ "s8", "Concentration", "3", .{ .r = 230, .g = 240, .b = 255 }, 254 },
    };
    for (scenes) |sc| {
        catalog.scenes.add(.{ .id = sc[0], .name = sc[1], .group = sc[2], .recycle = false });
        catalog.scenes.items[catalog.scenes.len - 1].look = .{ .lit = .{ .rgb = sc[3], .bri = sc[4] } };
    }
    catalog.select(&catalog.groups.items[0]);

    // Offline, `bridge.submit` answers each command at once: the same loop as with a
    // bridge, minus the web remote and the BOOT button. Runs forever, like `control`.
    var loop: Loop = .{ .last_refresh = now_ms() };
    while (true) {
        loop.tick_screen(now_ms());
        rtos.sleep(.from_ms(poll_ms));
    }
}

// ---- control: touch screen, BOOT button, refresh, in one loop on the UI task ----
//
// Three tasks, each owning what it touches:
//   - this one (the UI task): the catalog, the screen, the settings, the LED, the button.
//     It never waits on the network, so it ticks every `poll_ms` whatever the bridge does.
//   - the bridge task (bridge.zig): every request to the bridge, one command at a time.
//   - the web task (below): the web remote's connections. It asks this task for the state
//     and for changes, and waits for the answer; it never reads the catalog itself.
//
// The web remote acts on `catalog.selected()`: the light or room open on the screen, or
// -Dhue_light without one. With nothing selected (the screen's list page before any tap),
// it does nothing.

/// Above the bridge and web tasks (which run at `.lowest`), so a long JSON parse there
/// doesn't hold up a frame; level with lwIP's own thread (common/src/lwip/exports.zig),
/// which only runs briefly per packet.
const ui_priority: rtos.Priority = @fromBackingInt(2);

fn control(ctx: bridge_task.Context) !void {
    try bridge_task.start(heap.allocator(), ctx);
    try web_start();
    rtos.change_priority(rtos.get_current_task(), ui_priority);

    // Runs forever: the remote's main loop.
    var loop: Loop = .{ .last_refresh = now_ms() };
    while (true) {
        const t = now_ms();
        loop.tick_screen(t);
        loop.web();
        loop.button(t);
        if (config.screen and touch_ui.take_forget()) forget();
        rtos.sleep(.from_ms(poll_ms));
    }
}

const Loop = struct {
    last_refresh: u64,
    mirrored: ?hue.LightState = null,
    button_down_since: ?u64 = null,
    asked: bool = false,
    /// A short BOOT press, waiting for the bridge task.
    all_off_wanted: bool = false,
    /// The web request this task is working on: its change waits for, or is with, the bridge
    /// task. Others wait in `asks` until it's answered.
    web_open: ?struct { seq: u32, ref: catalog.Ref, change: ?hue.Change } = null,

    /// The screen, the bridge task's replies and the next command for it, the LED.
    fn tick_screen(l: *Loop, t: u64) void {
        while (bridge_task.poll()) |d| l.done(d);
        if (config.screen) {
            touch_ui.tick(t);
            // The field UI's demo plays gestures by itself: no dimming under it.
            if (!(config.demo and config.ui == .field)) backlight.tick(t);
        }
        l.pump(t);
        l.mirror_selected();
    }

    /// Gives the bridge task its next command, if it's free: what a finger or the button
    /// asked for first, then the web remote, then refreshes, then scene colours.
    fn pump(l: *Loop, t: u64) void {
        if (!bridge_task.idle()) return;
        if (config.screen) if (touch_ui.next_change(t)) |c| return bridge_task.submit(.touch, c);
        if (l.all_off_wanted) {
            l.all_off_wanted = false;
            return bridge_task.submit(.button, .all_off);
        }
        if (l.web_open) |*w| if (w.change) |c| {
            w.change = null; // with the bridge task now
            return bridge_task.submit(.web, .{ .change = .{ .ref = w.ref, .change = c } });
        };
        // Pick up changes made from the Hue app or a wall switch, and refresh whatever
        // the screen just navigated to. Check `busy` first: navigation happens with the
        // finger still down, and taking the request then would drop it.
        const idle = !(config.screen and touch_ui.busy());
        const asked = config.screen and idle and touch_ui.take_refresh_request();
        if (idle and (asked or t - l.last_refresh >= refresh_ms)) {
            l.last_refresh = t;
            const cmd: ?bridge_task.Cmd = if (config.screen)
                touch_ui.refresh_cmd()
            else if (catalog.selected()) |e| .{ .entry = .of(e) } else null;
            if (cmd) |c| return bridge_task.submit(.refresh, c);
        }
        if (config.screen) if (touch_ui.next_look()) |c| bridge_task.submit(.look, c);
    }

    fn done(l: *Loop, d: bridge_task.Done) void {
        if (config.screen) touch_ui.done(d);
        switch (d.owner) {
            .refresh => if (config.screen) touch_ui.report_refresh(d.ok),
            .web => if (l.web_open) |w| {
                l.web_open = null;
                answer(w.seq, if (d.ok) snapshot() else .refused);
            },
            .touch, .look, .button => {},
        }
    }

    fn mirror_selected(l: *Loop) void {
        if (catalog.selected()) |e| {
            if (l.mirrored == null or !std.meta.eql(l.mirrored.?, e.state)) mirror(e.state);
            l.mirrored = e.state;
        } else if (l.mirrored != null) {
            show(.{ .r = 0, .g = 0, .b = 0 });
            l.mirrored = null;
        }
    }

    fn button(l: *Loop, t: u64) void {
        if (boot_button.read() == 0) {
            const since = l.button_down_since orelse t;
            l.button_down_since = since;
            if (config.screen) _ = backlight.wake(t);
            const held = t - since;
            if (held >= forget_hold_ms) forget();
            const can_ask = config.screen and touch_ui.can_confirm and touch_ui.touch_ok;
            if (held >= ask_hold_ms and !l.asked and can_ask) {
                touch_ui.ask_forget();
                l.asked = true;
            }
        } else if (l.button_down_since) |since| {
            if (t - since < short_press_ms) l.all_off_wanted = true;
            l.button_down_since = null;
            l.asked = false;
        }
    }

    /// Takes the web task's next question, unless one is still being worked on.
    fn web(l: *Loop) void {
        if (l.web_open != null) return;
        const q = asks.get_one(.non_blocking) catch return; // nothing asked
        switch (q.ask) {
            .state => answer(q.seq, snapshot()),
            .forget => {
                answer(q.seq, .forgetting);
                forget(); // waits a moment before the reset: the web task answers meanwhile
            },
            .set => |change| {
                const e = catalog.selected() orelse return answer(q.seq, .no_selection);
                l.web_open = .{ .seq = q.seq, .ref = .of(e), .change = change };
            },
        }
    }
};

// ---- web remote: its own task, asking the UI task ----

const page = @embedFile("page.html");
/// Required on every POST (any value), see `serve`.
const remote_header = "X-Hue-Remote";

const Ask = union(enum) { state, set: hue.Change, forget };

/// The selection's name and state, copied: the web task never reads the catalog.
const Snapshot = struct {
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    state: hue.LightState,

    fn name(s: *const Snapshot) []const u8 {
        return s.name_buf[0..s.name_len];
    }
};

const Answer = union(enum) { state: Snapshot, no_selection, refused, forgetting };

const Question = struct { seq: u32, ask: Ask };
const Reply = struct { seq: u32, answer: Answer };

var ask_buf: [1]Question = undefined;
var answer_buf: [1]Reply = undefined;
var asks: rtos.Queue(Question) = .init(&ask_buf);
var answers: rtos.Queue(Reply) = .init(&answer_buf);

fn snapshot() Answer {
    const e = catalog.selected() orelse return .no_selection;
    var s: Snapshot = .{ .state = e.state, .name_len = e.name_len };
    @memcpy(s.name_buf[0..s.name_len], e.name());
    return .{ .state = s };
}

/// From the UI task. The web task may have given up on this one (see `ask`): an answer it
/// isn't waiting for is dropped there, by `seq`, so the slot must not stay taken.
fn answer(seq: u32, a: Answer) void {
    const r: Reply = .{ .seq = seq, .answer = a };
    answers.put_one(r, .non_blocking) catch {
        // The slot holds an answer the web task gave up waiting for: it's stale, drop it.
        const stale = answers.get_one(.non_blocking) catch r;
        std.log.warn("web answer {} dropped: its request had timed out", .{stale.seq});
        // Just emptied, and only this task puts answers.
        answers.put_one(r, .non_blocking) catch unreachable;
    };
}

/// The web task's side: one question at a time, bounded. Longer than a bridge request
/// (`hue.response_timeout_ms`) plus a refresh that may be ahead of it in the bridge task.
fn ask(q: Ask) error{Timeout}!Answer {
    const timeout_ms = 25_000;
    web_seq +%= 1;
    const seq = web_seq;
    try asks.put_one(.{ .seq = seq, .ask = q }, .{ .after = .from_ms(1000) });
    const start = now_ms();
    while (now_ms() - start < timeout_ms) {
        const left: u32 = @intCast(timeout_ms - (now_ms() - start));
        const r = try answers.get_one(.{ .after = .from_ms(left) });
        if (r.seq == seq) return r.answer;
        // A late answer to a question already given up on.
    }
    return error.Timeout;
}

var web_seq: u32 = 0;

const http_port = 80;
/// Its deepest path is `serve`: a 1 KiB request buffer and the JSON answer.
const web_stack_size = 8 * 1024;

fn web_start() !void {
    const server = lwip.c.netconn_new_with_proto_and_callback(lwip.c.NETCONN_TCP, 0, null) orelse
        return error.OutOfMemory;
    try lwip.c_err(lwip.c.netconn_bind(server, null, http_port));
    try lwip.c_err(lwip.c.netconn_listen(server));
    _ = try rtos.spawn(heap.allocator(), web_task, .{server}, .{
        .name = "web",
        .stack_size = web_stack_size,
        .priority = .lowest,
    });
    std.log.info("web remote: http://{f}:{}/", .{ net.ip(), http_port });
}

/// Runs forever: accept waits for the next connection with no timeout, which only holds
/// up this task. Each request is bounded by `web.read_request`'s timeouts and by `ask`.
fn web_task(server: *lwip.c.netconn) noreturn {
    while (true) {
        var client: ?*lwip.c.netconn = null;
        if (lwip.c_err(lwip.c.netconn_accept(server, &client))) {
            serve(client.?) catch |err| std.log.warn("request failed: {t}", .{err});
            _ = lwip.c.netconn_close(client);
            _ = lwip.c.netconn_delete(client);
        } else |err| {
            std.log.err("accept failed: {t}", .{err});
            rtos.sleep(.from_ms(poll_ms));
        }
    }
}

fn serve(conn: *lwip.c.netconn) !void {
    var buf: [1024]u8 = undefined;
    const req = web.read_request(conn, &buf, .{}) catch |err| switch (err) {
        error.BadRequest => return web.respond(conn, "400 Bad Request", "text/plain", "bad request\n"),
        else => return err,
    };
    std.log.info("{s} {s}{s}{s}", .{ req.method, req.path, if (req.query.len > 0) "?" else "", req.query });

    // Other web pages the user has open must not reach the lights (see the helper).
    if (try web.refuse_cross_site(conn, req, remote_header)) return;

    if (req.is("GET", "/")) return web.respond(conn, "200 OK", "text/html; charset=utf-8", page);
    if (req.is("GET", "/state")) return respond(conn, ask(.state));
    if (req.is("POST", "/forget")) return respond(conn, ask(.forget));
    if (req.is("POST", "/set")) {
        const change = protocol.parse_change(req.query) catch
            return web.respond(conn, "400 Bad Request", "text/plain", "bad parameter\n");
        return respond(conn, ask(.{ .set = change }));
    }
    return web.respond(conn, "404 Not Found", "text/plain", "not found\n");
}

fn respond(conn: *lwip.c.netconn, a: error{Timeout}!Answer) !void {
    const text = "text/plain";
    switch (a catch return web.respond(conn, "504 Gateway Timeout", text, "no answer\n")) {
        .no_selection => return web.respond(conn, "409 Conflict", text, "pick a light or room on the screen first\n"),
        .refused => return web.respond(conn, "502 Bad Gateway", text, "the bridge didn't take it\n"),
        .forgetting => return web.respond(conn, "200 OK", text, "forgetting the bridge and the username, restarting\n"),
        .state => |*s| {
            var body: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&body, "{f}", .{std.json.fmt(.{
                .name = s.name(),
                .on = s.state.on,
                .reachable = s.state.reachable,
                .bri = s.state.bri,
                .hue = s.state.hue,
                .sat = s.state.sat,
            }, .{})});
            return web.respond(conn, "200 OK", "application/json", json);
        },
    }
}

// ---- status: on the screen and the on-board LED ----

const Status = enum { busy, waiting, ok, failed };

fn status(kind: Status, text: []const u8) void {
    if (config.screen) ui.message(text, switch (kind) {
        .busy => ili9341.rgb(120, 170, 255),
        .waiting => ili9341.rgb(255, 180, 60),
        .ok => ili9341.rgb(110, 230, 120),
        .failed => ili9341.rgb(255, 90, 70),
    });
    // Blue = starting, orange = waiting for you, green = done, red = error.
    show(scale(switch (kind) {
        .busy => .{ .r = 0, .g = 0, .b = 255 },
        .waiting => .{ .r = 255, .g = 128, .b = 0 },
        .ok => .{ .r = 0, .g = 255, .b = 0 },
        .failed => .{ .r = 255, .g = 0, .b = 0 },
    }, config.led_level / 2 + 1));
}

/// Shows the light's colour on the LED, scaled by its brightness and `-Dled_level`.
fn mirror(light: hue.LightState) void {
    if (!light.on) return show(.{ .r = 0, .g = 0, .b = 0 });
    const v: u32 = @max(@as(u32, light.bri orelse 254) * config.led_level / 254, 2);
    if (light.hue == null or light.sat == null) return show(scale(.{ .r = 255, .g = 160, .b = 60 }, v));
    const c = ui.hsv_to_rgb(light.hue.?, light.sat.?);
    return show(scale(.{ .r = c.r, .g = c.g, .b = c.b }, v));
}

fn scale(c: Color, v: u32) Color {
    return .{
        .r = @intCast(@as(u32, c.r) * v / 255),
        .g = @intCast(@as(u32, c.g) * v / 255),
        .b = @intCast(@as(u32, c.b) * v / 255),
    };
}

fn now_ms() u64 {
    return hal.time.get_time_since_boot().to_us() / 1000;
}

fn init_led() void {
    rmt.apply(rmt_config);
    led_channel.apply(led_channel_config);
    led_channel.connect_pin(led_pin);
    led = .init(led_channel, comptime led_channel_config.tick_freq(rmt_config), .{});
}

fn show(color: Color) void {
    led.write(&.{color}) catch |err| std.log.warn("LED write failed: {t}", .{err});
}
