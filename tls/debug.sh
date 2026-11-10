#!/bin/bash
# Usage: ./debug.sh [seconds]  (default 150)
# Start the simulation in VS Code with "Wokwi: Start Simulator and Wait for Debugger" first.
# Lets the board run for the given wall-clock time, interrupts it, and saves the dump to
# debug.log.
cd "$(dirname "$0")"
wait=${1:-150}
riscv64-elf-gdb -batch -x debug.gdb > debug.log 2>&1 &
gdb_pid=$!
sleep "$wait"
kill -INT "$gdb_pid" 2>/dev/null
wait "$gdb_pid"
echo "dump written to $(pwd)/debug.log"
