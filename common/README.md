# common — code shared by the samples

Not an example on its own. `add_base` adds `uart_log`, `verify` and `system` (`reset()`, the
whole chip) to any sample; `add_net` calls it and adds the Wi-Fi samples' (`weblight`, `hue`,
`tls`, `netatmo`) `net`, `https` and `settings` modules; `add_screen`
adds `screen` (ILI9341 + FT6206, and `screen.backlight`, PWM on GPIO3). The `net` module:

- `net.up(allocator)`: joins the Wi-Fi network from the example's `config` (`ssid`,
  `password`) and waits for a DHCP address; `net.ip()` formats it. It retries until the
  access point answers, and leaves a task behind that reconnects whenever the link drops.
- `net.lwip`: lwIP's C API (`net.lwip.c`) and `c_err` to turn its error codes into Zig errors.
- `net.web`: one-request-per-connection HTTP helpers (`read_request`, `params`,
  `split_param`, `respond`, `refuse_cross_site`). `read_request` gives a client 150 ms to
  start sending, so an idle browser connection can't stall a single-task server.
  `refuse_cross_site` answers 403 to a POST without the sample's custom header, so other
  web pages open in the browser can't reach the board.
- `net.exports`: the OS glue lwIP links against (`sys_now`, mutexes, mailboxes, semaphores,
  threads, on MicroZig's RTOS). Reference it from the firmware's root
  (`comptime { _ = net.exports; }`) so the symbols are exported.
- `verify` (its own module): `verify(ok, "what")`, an assertion that stays in ReleaseSmall,
  for invariants whose failure would corrupt memory (see STYLE.md).
- `settings` (its own module): `Store(.{ .namespace, .Key, .value_max })`, strings in the
  flash's NVS partition. `set` returns false when a value isn't stored (it reads every write
  back); one task only, checked with `verify`. `hue` and `netatmo` each wrap one.
- `uart_log` (its own module): `.logFn = @import("uart_log").log` in `std_options`. Locks
  across tasks, and writes unlocked when interrupts are off (a trap, a panic), where waiting
  for the lock would freeze the board. `log_unlocked` for firmware without the RTOS. A line
  over 256 bytes is cut and marked ` [cut]`, not dropped.
- `net.std_options(extra_scopes)` and `net.microzig_options`: the firmware root's options.
  The latter already hands received frames to lwIP (`net.on_packet_received`).
- HTTPS (`https`): each read and each write times out after 10 s, the whole exchange after
  60 s, so a server dripping bytes (or not taking them) can't hold the task. Connecting
  isn't bounded: lwIP's netconn has no connect timeout, and TCP gives up after its SYN
  retries.

From an example's `build.zig`:

    const common = @import("common");
    ...
    const config = options.createModule();
    fw.exe.root_module.addImport("config", config);
    if (!common.add_net(b, mz_dep, fw, .{ .optimize = optimize, .config = config })) return;

with `.common = .{ .path = "../common" }` in its `build.zig.zon`. `lwip_include_dir` swaps in
another `lwipopts.h` for one example.

For host tests:

    common.add_tests(b, b.step("test", "Run the host tests"));

runs every file with a `test "..."` block under the example's `src/` and common's `src/`,
in Debug and ReleaseSmall. They're found by scanning, so keep tests in pure modules (no
`microzig`, no `net`): `web/request.zig` next to `web.zig` is the pattern.
