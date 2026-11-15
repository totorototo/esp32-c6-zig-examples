//! Chip-wide actions, as a `system` module.
const microzig = @import("microzig");
const hal = microzig.hal;

/// Reboots the whole chip (radio and peripherals too, like the reset button). Wokwi ignores
/// the C6 system reset, so if the chip is still running a moment later, a CPU reset (which
/// Wokwi does) takes over. On hardware the system reset always wins: a CPU-only reset would
/// leave the radio and the other peripherals running into the next boot.
pub fn reset() noreturn {
    microzig.chip.peripherals.LP_AON.SYS_CFG.modify(.{ .HPSYS_SW_RESET = 1 });
    hal.rom.delay_us(10_000);
    hal.rom.software_reset_cpu();
}
