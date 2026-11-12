//! This file must not compile. `zig build test-compile-fail` builds it, and requires the message
//! of the check of the Zig version (`src/zig_version.zig`).
//!
//! That check reads the version of the compiler, and no test can change the compiler. So this
//! file hands the check another version: the pinned one, with the next patch number.
const zig_version = @import("zig_version");

comptime {
    var other = zig_version.pinned;
    other.patch += 1;
    zig_version.require(other);
}
