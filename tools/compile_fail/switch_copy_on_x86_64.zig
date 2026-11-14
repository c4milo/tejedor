//! This file must not compile. `zig build test-compile-fail` builds it for x86_64 Linux. It
//! requires the note of Zig for an inline call of a function that Zig cannot resolve at compile
//! time. `switch_context` is a cast of the naked jump to a function type of the C calling
//! convention. Zig 0.16.0 cannot resolve the function behind that cast.
//!
//! On x86_64 `switch_context` is the address of the jump, a naked function in assembly, with the C
//! calling convention (record 6). So each caller calls the jump, and no caller holds a copy of it.
//! The calling convention then covers each caller-saved register. If this file compiles, Zig can
//! copy `switch_context` into a caller. A caller can then get something other than a call of the
//! jump.
const switching = @import("switch");

test "a caller asks for a copy of the switch on x86_64" {
    var message: switching.Switch = undefined;
    @call(.always_inline, switching.switch_context, .{&message});
}
