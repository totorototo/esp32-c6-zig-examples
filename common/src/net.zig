//! Wi-Fi station + lwIP bring-up, adapted from MicroZig's `tcp_server` example.
//! `up()` returns once DHCP has assigned an address, and leaves a task behind that
//! reconnects whenever the connection drops. Needs a `config` import with `ssid` and
//! `password` (see common/build.zig).
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");

const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;

pub const exports = @import("lwip/exports.zig");
const uart_log = @import("uart_log");
const verify = @import("verify").verify;
pub const lwip = @import("lwip/include.zig");
pub const web = @import("web.zig");

const log = std.log.scoped(.net);

// ---- the firmware root's options, the same for every Wi-Fi sample ----
//
//     pub const std_options = net.std_options(&.{});
//     pub const microzig_options = net.microzig_options;

/// Info level, the radio driver's chatter off, `extra_scopes` on top, logs to UART0. Also a
/// page size: the HTTPS client's certificate-bundle lock wants an `std.Io`, and
/// `std.Io.failing` references file memory maps, which need one (freestanding has none;
/// it is never actually used). Harmless for samples without HTTPS.
pub fn std_options(comptime extra_scopes: []const std.log.ScopeLevel) std.Options {
    const quiet_radio = [_]std.log.ScopeLevel{
        .{ .scope = .esp_radio, .level = .err },
        .{ .scope = .esp_radio_timer, .level = .err },
        .{ .scope = .esp_radio_wifi, .level = .err },
        .{ .scope = .esp_radio_osi, .level = .err },
    };
    const scopes = quiet_radio ++ extra_scopes[0..extra_scopes.len].*;
    var o = microzig.std_options(.{
        .log_level = .info,
        .log_scope_levels = &scopes,
        .logFn = uart_log.log,
    });
    o.page_size_min = 4096;
    o.page_size_max = 4096;
    return o;
}

/// The RTOS and the radio on their interrupts, and received frames handed to lwIP.
pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt30 = radio.interrupt_handler,
        .interrupt31 = rtos.interrupt_handler,
    },
    .cpu = .{ .interrupt_stack = .{ .enable = true, .size = 8192 } },
    .hal = .{
        .rtos = .{ .enable = true },
        .radio = .{ .wifi = .{ .on_packet_received = on_packet_received } },
    },
};

var netif: lwip.c.netif = undefined;
var netif_ready = false;
var ip_ready: rtos.Signal(void) = .{};

/// Joins the configured network and waits for an IPv4 address.
pub fn up(gpa: std.mem.Allocator) !void {
    try radio.wifi.init(gpa, .{});

    exports.gpa = gpa;
    lwip.c.tcpip_init(null, null);

    _ = lwip.c.netifapi_netif_add(
        &netif,
        @ptrCast(lwip.c.IP4_ADDR_ANY),
        @ptrCast(lwip.c.IP4_ADDR_ANY),
        @ptrCast(lwip.c.IP4_ADDR_ANY),
        null,
        netif_init,
        lwip.c.tcpip_input,
    );
    netif_ready = true;
    try lwip.c_err(lwip.c.netifapi_netif_common(&netif, null, lwip.c.dhcp_start));

    try radio.wifi.apply(.{
        .sta = .{
            .ssid = config.ssid,
            .password = config.password,
            // The auth method is the weakest mode accepted; WPA2 also admits WPA3 transition APs.
            .auth_method = if (config.password.len == 0) .none else .wpa2_personal,
        },
    });

    try radio.wifi.start();
    try wait_started();

    log.info("connecting to `{s}`", .{config.ssid});
    try radio.wifi.connect();
    join();
    _ = lwip.c.netifapi_netif_common(&netif, lwip.c.netif_set_link_up, null);

    ip_ready.wait();
    log.info("got address {f}", .{ip()});

    _ = try rtos.spawn(gpa, supervise, .{}, .{ .name = "wifi_supervisor" });
}

/// How long `start` may take before the driver counts as broken (it takes milliseconds).
const start_timeout_ms = 5000;

/// Waits for the station to report started: bounded, unlike `join`, because this one
/// depends only on the driver, not on an access point that may still be booting.
fn wait_started() error{WifiStartTimeout}!void {
    const start = now_ms();
    while (!radio.wifi.get_sta_state().is_started()) {
        if (now_ms() - start >= start_timeout_ms) return error.WifiStartTimeout;
        rtos.sleep(.from_ms(100));
    }
}

/// Between connection attempts. The driver doesn't retry by itself: after a failed attempt
/// or a lost connection the station stays `disconnected` until `connect` is called again.
const retry_ms = 5000;

/// Waits until the station is connected, asking the driver again every `retry_ms`. Never
/// gives up: after a power cut the board may boot long before the access point.
fn join() void {
    var last_try = now_ms();
    while (true) {
        switch (radio.wifi.get_sta_state()) {
            .connected => return,
            .disconnected => if (now_ms() - last_try >= retry_ms) {
                last_try = now_ms();
                log.warn("not connected to `{s}`: retrying", .{config.ssid});
                radio.wifi.connect() catch |err| log.warn("connect failed: {t}", .{err});
            },
            else => {},
        }
        rtos.sleep(.from_ms(100));
    }
}

/// A task that reconnects when the access point goes away (reboot, out of range). The link
/// goes down meanwhile, so lwIP stops sending, and back up afterwards, which makes DHCP
/// confirm or renew the address.
fn supervise() void {
    while (true) {
        rtos.sleep(.from_ms(500));
        if (radio.wifi.get_sta_state() != .disconnected) continue;

        log.warn("lost `{s}`: reconnecting", .{config.ssid});
        _ = lwip.c.netifapi_netif_common(&netif, lwip.c.netif_set_link_down, null);
        radio.wifi.connect() catch |err| log.warn("connect failed: {t}", .{err});
        join();
        _ = lwip.c.netifapi_netif_common(&netif, lwip.c.netif_set_link_up, null);
        log.info("reconnected to `{s}`", .{config.ssid});
    }
}

fn now_ms() u64 {
    return microzig.hal.time.get_time_since_boot().to_us() / 1000;
}

pub fn ip() IpFormatter {
    return .{ .addr = netif.ip_addr };
}

pub const IpFormatter = struct {
    addr: lwip.c.ip_addr_t,

    pub fn format(self: IpFormatter, writer: *std.Io.Writer) !void {
        try writer.writeAll(std.mem.sliceTo(lwip.c.ip4addr_ntoa(@as(*const lwip.c.ip4_addr_t, @ptrCast(&self.addr))), 0));
    }
};

/// Called from the Wi-Fi driver for every received frame; hands it to lwIP.
pub fn on_packet_received(comptime _: radio.wifi.Interface, data: []const u8) void {
    if (!netif_ready) return;
    const pbuf: *lwip.c.struct_pbuf = lwip.c.pbuf_alloc(lwip.c.PBUF_RAW, @intCast(data.len), lwip.c.PBUF_POOL) orelse {
        log.err("failed to allocate receive pbuf", .{});
        return;
    };
    lwip.c_err(lwip.c.pbuf_take(pbuf, data.ptr, @intCast(data.len))) catch unreachable;
    lwip.c_err(netif.input.?(pbuf, &netif)) catch |err| {
        _ = lwip.c.pbuf_free(pbuf);
        log.warn("tcpip_input failed: {t}", .{err});
    };
}

fn netif_status_callback(netif_ptr: [*c]lwip.c.netif) callconv(.c) void {
    if (netif_ptr[0].ip_addr.u_addr.ip4.addr != 0) ip_ready.put({});
}

fn netif_init(netif_ptr: [*c]lwip.c.struct_netif) callconv(.c) lwip.c.err_t {
    const n = &netif_ptr[0];
    @memcpy(&n.name, "w0");
    n.linkoutput = netif_output;
    n.output = lwip.c.etharp_output;
    n.output_ip6 = lwip.c.ethip6_output;
    n.mtu = mtu;
    n.flags = lwip.c.NETIF_FLAG_BROADCAST | lwip.c.NETIF_FLAG_ETHARP | lwip.c.NETIF_FLAG_ETHERNET | lwip.c.NETIF_FLAG_IGMP | lwip.c.NETIF_FLAG_MLD6;
    @memcpy(&n.hwaddr, &radio.read_mac(.sta));
    n.hwaddr_len = 6;
    lwip.c.netif_create_ip6_linklocal_address(n, 1);
    lwip.c.netif_set_status_callback(n, netif_status_callback);
    lwip.c.netif_set_default(n);
    lwip.c.netif_set_up(n);
    return lwip.c.ERR_OK;
}

const mtu = 1500;
/// One Ethernet frame: the IP packet plus the 14-byte Ethernet header lwIP prepends.
var packet_buf: [1600]u8 = undefined;
comptime {
    std.debug.assert(packet_buf.len >= mtu + 14);
}

fn netif_output(_: [*c]lwip.c.struct_netif, pbuf_c: [*c]lwip.c.struct_pbuf) callconv(.c) lwip.c.err_t {
    const pbuf: *lwip.c.struct_pbuf = pbuf_c;
    // lwIP never builds a frame over the MTU; if it did, the copy below would overrun.
    verify(pbuf.tot_len <= packet_buf.len, "outgoing frame fits packet_buf");

    var off: usize = 0;
    while (off < pbuf.tot_len) {
        const cnt = lwip.c.pbuf_copy_partial(pbuf, packet_buf[off..].ptr, @as(u15, @intCast(pbuf.tot_len - off)), @as(u15, @intCast(off)));
        if (cnt == 0) {
            log.err("failed to copy network packet", .{});
            return lwip.c.ERR_BUF;
        }
        off += cnt;
    }

    radio.wifi.send_packet(.sta, packet_buf[0..pbuf.tot_len]) catch |err| {
        log.err("failed to send packet: {}", .{err});
        return lwip.c.ERR_IF;
    };
    return lwip.c.ERR_OK;
}
