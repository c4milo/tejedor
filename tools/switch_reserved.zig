//! A program that holds one copy of the switch. `zig build test-reserved` builds it for eight
//! aarch64 targets where LLVM reserves a register that the list can name. Each compile must print
//! nothing (record 5).
//!
//! LLVM never keeps a value in a reserved register, so the name of one protects nothing. LLVM
//! prints one warning for each copy of the switch whose list names one. The list can name `ffr`,
//! which LLVM reserves for a processor with SVE. It can name `x18`, which LLVM reserves on the
//! systems of Apple, Android, OpenHarmony, Fuchsia, UEFI and Windows. So such a name that comes
//! back into the list fails the build here.
const switching = @import("switch");

export fn switch_reserved(message: *const switching.Switch) void {
    switching.switch_context(message);
}
