//! This file must not compile. `zig build test-compile-fail` builds it for x86_64 Linux, and
//! requires the error of Zig for a call that asks to inline a function that is never inlined.
//!
//! On x86_64 each caller calls `switch_context`, and no caller holds a copy of it (record 5). The
//! calling convention then covers the registers that the clobber list cannot name. If this file
//! compiles, a caller can get a copy, and can lose an `f80` value across the switch.
const switching = @import("switch");

test "a caller asks for a copy of the switch on x86_64" {
    var message: switching.Switch = undefined;
    @call(.always_inline, switching.switch_context, .{&message});
}
