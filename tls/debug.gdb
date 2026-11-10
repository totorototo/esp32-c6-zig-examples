# Attach to a Wokwi simulation (wokwi.toml: gdbServerPort = 3333), run it, and when debug.sh
# interrupts it, dump where the CPU is stuck. Wokwi's stub has no CSRs: registers only.
set pagination off
set confirm off
set print pretty on
file zig-out/firmware/tls.elf
target remote localhost:3333
echo \n=== running; debug.sh interrupts after the wait ===\n
continue
echo \n=== stopped ===\n
info registers
echo \n--- current RTOS task ---\n
p 'hal.rtos.rtos_state'.current_task.name
p/x 'hal.rtos.rtos_state'.current_task.stack
p/x 'hal.rtos.rtos_state'.current_task.context
echo \n--- main task ---\n
p/x 'hal.rtos.main_task'.context
echo \n--- stack contents at sp, with symbols ---\n
python
import gdb
sp = int(gdb.parse_and_eval("$sp")) & 0xffffffff
inf = gdb.selected_inferior()
for i in range(48):
    addr = sp + 4 * i
    try:
        w = int.from_bytes(inf.read_memory(addr, 4).tobytes(), "little")
    except Exception as e:
        print(f"{addr:08x}: <{e}>"); continue
    sym = ""
    if 0x42000000 <= w < 0x42800000 or 0x40800000 <= w < 0x40810000:
        s = gdb.execute(f"info symbol {w:#x}", to_string=True).strip()
        sym = "  " + s
    print(f"{addr:08x}: {w:08x}{sym}")
end
echo \n--- heap bounds ---\n
info symbol $sp
p/x &microzig_heap_start
p/x &microzig_heap_end
detach
