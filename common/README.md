# common — code shared by the Wi-Fi samples (`weblight`, `hue`, `tls`, `netatmo`)

Not an example on its own. `add_net` adds the `net`, `https` and `uart_log` modules; `add_screen`
adds `screen` (ILI9341 + FT6206). The `net` module:

- `net.up(allocator)`: joins the Wi-Fi network from the example's `config` (`ssid`,
  `password`) and waits for a DHCP address; `net.ip()` formats it. It retries until the
  access point answers, and leaves a task behind that reconnects whenever the link drops.
- `net.lwip`: lwIP's C API (`net.lwip.c`) and `c_err` to turn its error codes into Zig errors.
- `net.web`: one-request-per-connection HTTP helpers (`read_request`, `params`,
  `split_param`, `respond`). `read_request` gives a client 150 ms to start sending, so an
  idle browser connection can't stall a single-task server.
- `net.exports`: the OS glue lwIP links against (`sys_now`, mutexes, mailboxes, semaphores,
  threads, on MicroZig's RTOS). Reference it from the firmware's root
  (`comptime { _ = net.exports; }`) so the symbols are exported.
- `uart_log` (its own module): `.logFn = @import("uart_log").log` in `std_options`. Locks
  across tasks, and writes unlocked when interrupts are off (a trap, a panic), where waiting
  for the lock would freeze the board.
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
