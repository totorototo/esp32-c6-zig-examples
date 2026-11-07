//! Wi-Fi station + lwIP bring-up, adapted from MicroZig's `tcp_server` example.
//! `up()` returns once DHCP has assigned an address.
const std = @import("std");
const microzig = @import("microzig");
const config = @import("config");

const hal = microzig.hal;
const rtos = hal.rtos;
const radio = hal.radio;

pub const exports = @import("lwip/exports.zig");
pub const lwip = @import("lwip/include.zig");

const log = std.log.scoped(.net);

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
    while (!radio.wifi.get_sta_state().is_started()) rtos.sleep(.from_ms(100));

    log.info("connecting to `{s}`", .{config.ssid});
    try radio.wifi.connect();
    while (radio.wifi.get_sta_state() != .connected) rtos.sleep(.from_ms(100));
    _ = lwip.c.netifapi_netif_common(&netif, lwip.c.netif_set_link_up, null);

    ip_ready.wait();
    log.info("got address {f}", .{ip()});
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
    const pbuf: *lwip.c.struct_pbuf = lwip.c.pbuf_alloc(lwip.c.PBUF_RAW, @intCast(data.len), lwip.c.PBUF_POOL) orelse {
        log.err("failed to allocate receive pbuf", .{});
        return;
    };
    lwip.c_err(lwip.c.pbuf_take(pbuf, data.ptr, @intCast(data.len))) catch unreachable;
    if (!netif_ready) {
        _ = lwip.c.pbuf_free(pbuf);
        return;
    }
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
    n.mtu = 1500;
    n.flags = lwip.c.NETIF_FLAG_BROADCAST | lwip.c.NETIF_FLAG_ETHARP | lwip.c.NETIF_FLAG_ETHERNET | lwip.c.NETIF_FLAG_IGMP | lwip.c.NETIF_FLAG_MLD6;
    @memcpy(&n.hwaddr, &radio.read_mac(.sta));
    n.hwaddr_len = 6;
    lwip.c.netif_create_ip6_linklocal_address(n, 1);
    lwip.c.netif_set_status_callback(n, netif_status_callback);
    lwip.c.netif_set_default(n);
    lwip.c.netif_set_up(n);
    return lwip.c.ERR_OK;
}

var packet_buf: [1600]u8 = undefined;

fn netif_output(_: [*c]lwip.c.struct_netif, pbuf_c: [*c]lwip.c.struct_pbuf) callconv(.c) lwip.c.err_t {
    const pbuf: *lwip.c.struct_pbuf = pbuf_c;
    std.debug.assert(pbuf.tot_len < packet_buf.len);

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
