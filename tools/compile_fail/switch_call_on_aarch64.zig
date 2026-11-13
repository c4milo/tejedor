//! This file must not compile. `zig build test-compile-fail` builds it for aarch64 Linux, and
//! requires the error of Zig for a call that asks not to inline an inline function.
//!
//! On aarch64 each caller holds a copy of `switch_context` (record 5). So the clobber list decides
//! what a caller keeps across the switch. The mutations of the list in records 3 and 5 ran with
//! such a copy in each caller. If this file compiles, a caller can get a call, and those mutations
//! do not cover it.
const switching = @import("switch");

test "a caller asks for a call of the switch on aarch64" {
    var message: switching.Switch = undefined;
    @call(.never_inline, switching.switch_context, .{&message});
}
