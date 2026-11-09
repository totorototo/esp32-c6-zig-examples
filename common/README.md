# common — networking shared by `weblight` and `hue`

Not an example on its own. One `net` module:

- `net.up(allocator)`: joins the Wi-Fi network from the example's `config` (`ssid`,
  `password`) and waits for a DHCP address; `net.ip()` formats it.
- `net.lwip`: lwIP's C API (`net.lwip.c`) and `c_err` to turn its error codes into Zig errors.
- `net.web`: one-request-per-connection HTTP helpers (`read_request`, `params`,
  `split_param`, `respond`).
- `net.exports`: the OS glue lwIP links against (`sys_now`, mutexes, mailboxes, semaphores,
  threads, on MicroZig's RTOS). Reference it from the firmware's root
  (`comptime { _ = net.exports; }`) so the symbols are exported.
- `net.on_packet_received`: hand it to the radio driver
  (`.hal.radio.wifi.on_packet_received` in `microzig_options`) to feed frames to lwIP.

From an example's `build.zig`:

    const common = @import("common");
    ...
    const config = options.createModule();
    fw.exe.root_module.addImport("config", config);
    if (!common.add_net(b, mz_dep, fw, .{ .optimize = optimize, .config = config })) return;

with `.common = .{ .path = "../common" }` in its `build.zig.zon`. `lwip_include_dir` swaps in
another `lwipopts.h` for one example.
