# tls — HTTPS from an ESP32-C6, in Zig with MicroZig

The first step towards a Netatmo thermostat remote: Netatmo has no local API, only OAuth2 over
HTTPS to `api.netatmo.com`, so the board needs TLS. This sample does an HTTPS request with
Zig's own TLS client, no C library:

1. Joins Wi-Fi (`-Dssid=... -Dpassword=...`, default `Wokwi-GUEST`, which reaches the internet).
2. Gets the time over SNTP (`pool.ntp.org`): certificate dates need it, and the board has no
   clock.
3. Opens TLS 1.3 to `api.netatmo.com:443` (X25519 + ML-KEM-768 key exchange, AES-256-GCM,
   RSA-PSS), verifying the host name and the chain up to one pinned root: DigiCert Global
   Root G2 (`src/digicert_global_root_g2.der`, SHA-256 `CB3CCBB7…5AB1CB5F`, valid to 2038).
   Pinning the root, not the leaf: Netatmo's leaf is reissued every six months.
4. Sends `GET /api/homesdata` without a token. Netatmo answers
   `400 Missing token argument` with `{"error":{"code":1,...}}`: that proves the request went
   through encrypted and the API read it.

Logs go to UART0 (115200 baud) and end with `tls test: PASS` or `tls test: FAIL`.

## Build and run

    zig build -Doptimize=ReleaseSmall
    zig build test                      # host tests (SNTP)

Wokwi: open `diagram.json` (needs internet; the CLI's cloud runs work too). Expected log:

    [info] time: 1794341184 (Unix seconds) from pool.ntp.org
    [info] api.netatmo.com is 150.171.110.119
    [info] TLS tls_1_3 handshake in 9283 ms, chain verified to DigiCert Global Root G2
    [info] HTTP/1.1 400 Missing token argument
    [info] body: { "error": { "code": 1, "message": "Access token is missing" } }
    [info] tls test: PASS

The handshake takes about 9 s in Wokwi, whose CPU runs about 10x slower than the chip.

## Memory: what it took to fit

TLS is the most memory-hungry thing on this board, and three things had to be right:

- **Stack.** `microzig.Allocator.init_with_heap(n)` reserves `n` bytes at the top of RAM for
  the main stack; the heap gets the rest. Here `n` is 160 KiB: the handshake goes about
  130 KiB deep. The heap keeps about 70 KiB, which Wi-Fi and lwIP need.
- **A patched copy of std's TLS client** (`src/tls_client.zig`, from Zig 0.17.1, MIT, see
  `../NOTICE`). Each patch is marked `microzig patch`:
  - The handshake's 2×16 KiB cleartext buffers and the key share (ML-KEM-768, P-256, P-384 and
    X25519 key pairs, 18 KiB) are statics instead of locals.
  - `verifySignature` and `KeyShare.exchange` call each `inline` prong through a `noinline`
    function. Inlined, LLVM gave every scheme its own slots in one frame: 100 KiB and 45 KiB.
    A frame that size moves `sp` past the end of the stack in one step, without touching the
    guard area below it, and lands on the heap. That's a *stack clash*. Here it overwrote the
    lwIP thread's stack (tasks' stacks live in the heap), and the board froze with `pc` at a
    garbage address, without a panic message.
  - Re-copy and re-apply when moving to a new Zig version.
- **Buffer sizes.** Both socket buffers hold one TLS record (`min_buffer_len`, ~16.6 KiB). The
  client asks its output for that much contiguous space before encrypting a record. It
  asserts this, but ReleaseSmall drops asserts: with a smaller socket write buffer, the first
  encrypted write spins forever.

To see the stack frames: `riscv64-elf-objdump -d zig-out/firmware/tls.elf` and look for big
`sub sp, sp, …` in prologues. `init` (83 KiB) and `exchangeHybrid` (44 KiB) are the largest
left.

## Debugging in Wokwi with GDB

`wokwi.toml` opens a GDB server on port 3333. With `brew install riscv64-elf-gdb`:

1. In VS Code: **Wokwi: Start Simulator and Wait for Debugger**.
2. `./debug.sh [seconds]`: attaches, lets the board run (150 s by default), interrupts it,
   and writes `debug.log`: registers, the current RTOS task and its stack range, the main
   task's context, the stack words at `sp` with symbols, and the heap bounds. Wokwi's
   stub has no CSRs (`mstatus`, `mcause`, ...): registers and memory only.

That is how the stack clash above was found: the current task was `lwip_tcpip`, its registers
held crypto values, and the main task's saved `sp` was inside lwIP's stack.

## Next

OAuth2 refresh and the Energy API (`homesdata`, `homestatus`, `setroomthermpoint`), with the
rotating refresh token saved to NVS before each use.
