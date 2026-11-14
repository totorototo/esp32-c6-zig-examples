# Style

Adapted from TigerBeetle's [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
for firmware that ships as ReleaseSmall on a 32-bit chip with 452 KB of RAM. Same order of
goals: safety, then performance, then developer experience. Each rule says why; the ones we
don't follow are at the end, with the reason.

## Safety

**Put a limit on everything.** Every loop that waits on hardware, the network or a peer has
a bound, in time or in count, and a log line when it gives up: a server that never ends its
headers, a LAN flooding mDNS answers, a peer dripping a byte every few seconds. Loops that
must run forever (a main loop, a halt, `net.join` waiting for an access point that may still
be booting) say so in a comment. Parsers walking a finite buffer are bounded by it.

**Sizes and wire values get explicit types** (`u8`, `u16`, `u32`, `i64`), not `usize`. The
host tests run on 64 bits and the board on 32: a value that fits in one may overflow in the
other. `usize` stays for indexing and lengths of slices in memory, where std requires it.

**Check relationships between constants at compile time.** Buffer sizes against what fills
them (`socket_write.len >= TlsClient.min_buffer_len`, `auth_buf` against `"Bearer "` plus
the token, `packet_buf` against the MTU). A wrong size is then a build error, not a board
that spins forever in ReleaseSmall.

**Assertions must survive ReleaseSmall.** `std.debug.assert` compiles to nothing there, so
it only checks the host tests. For an invariant whose failure would corrupt memory, use
`verify(ok, "what")` from `common/src/verify.zig`: it stops the board with a message.
Assertions are for programmer errors. Bad input from the network or a device is an error to
return, never a `verify`.

**Parsers of network input keep their bounds checks:** `@setRuntimeSafety(true)` at the top
of every function that reads bytes from outside (about 1 KB of flash per firmware). It only
covers its own scope, so helpers it calls need their own.

**Check at both ends.** What is written is checked where it is read back: settings are read
back after every NVS write, and the boot sample checks memory layout from inside the image.
Tests cover the rejected inputs as well as the accepted ones.

**Handle every error.** No `catch {}`: log it, count it, or return it. `catch unreachable`
only where the code proves it can't happen (a `bufPrint` into a buffer sized for the
largest value), and `_ = f()` only for results with nothing useful to do (closing a socket
that is being dropped).

**Always say why.** Comments explain decisions and constraints, in full sentences. The
`why` matters more than the `what`: the code already says what.

## Shape

**Functions: at most 70 lines. Lines: at most 100 columns.** `tools/style_lint.zig` measures
both, in CI. Code from before these rules is listed in `tools/style_baseline.txt` at its
size then: it may shrink but not grow, and new code has no allowance. When you touch a
listed function or file, bring it under the limits and run the lint with `--update`.

    zig run tools/style_lint.zig -- $(git ls-files '*.zig')

**Keep tests in pure modules.** A file with `test "..."` blocks is found and run by
`common.add_tests` on the host, in Debug and ReleaseSmall. It must compile without
`microzig` or `net`: put the logic in a pure file (`web/request.zig`, `hue/protocol.zig`)
and keep the I/O in another. Pure modules don't log either (the test runner fails on error
logs): they return the error with its explanation, and the I/O layer logs.

**`zig fmt`, `snake_case`** for functions, variables and files, as the code already does.

## What we don't follow, and why

- **Zero dependencies.** Impossible here: MicroZig, lwIP and Espressif's Wi-Fi blob are the
  platform.
- **All memory allocated statically at startup.** The Wi-Fi blob allocates on its own. lwIP
  could move from `malloc` to fixed pools (`MEMP_MEM_MALLOC 0`), which would make memory use
  predictable, but the pools need sizing on hardware: a project of its own.
- **Two assertions per function.** These are samples: assertion density would bury what
  they teach. `verify` goes where a broken invariant would corrupt memory.
- **Naming reorders** (`latency_ms_max`), **nested `if` trees** instead of `else if`,
  **scripts in Zig**: little gain for samples this size, and churn in every file.
