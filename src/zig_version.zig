//! The one Zig version that this release of tejedor builds with.
//!
//! tejedor gives a `std.Io`, and the table of a `std.Io`, `std.Io.VTable`, differs between Zig
//! versions. So each release of tejedor pins one Zig version, and a Zig upgrade is a release of
//! the package (rotor's decision 34, "Upkeep"). `build.zig` and `tejedor.zig` each import this
//! file. A build with another Zig stops at the comptime check below, and the message gives the
//! reason.
//!
//! Zig parses each build file before it runs that check. So a build file that the other Zig
//! cannot parse stops the build first, with a parse error and no reason. With Zig 0.17.1 that is
//! `build/lint.zig` of the pinned rotor. `zig test src/zig_version.zig` with that Zig shows the
//! message.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The Zig version that this release pins: a release of Zig, and no development build.
pub const pinned: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };

comptime {
    assert(pinned.pre == null);
    assert(pinned.build == null);
}

/// True for the pinned version. A development build of the pinned version is another version,
/// because its table can differ from the table of the release. A version that differs from the
/// pinned one in its build metadata alone passes too, because `order` does not read that part.
pub fn accepts(version: std.SemanticVersion) bool {
    return version.order(pinned) == .eq;
}

/// Stops the compile, with the reason, when `accepts` refuses `version`. `version` is the
/// version of the compiler. `tools/compile_fail/zig_version_other.zig` hands it another version,
/// and `zig build test-compile-fail` requires that compile to fail with this message.
pub fn require(comptime version: std.SemanticVersion) void {
    if (!accepts(version)) @compileError(std.fmt.comptimePrint(
        "tejedor builds with Zig {f} only, and this compiler is Zig {f}. " ++
            "The table of a std.Io, std.Io.VTable, differs between Zig versions, " ++
            "so each release of tejedor pins one Zig version. " ++
            "A Zig upgrade is a release of tejedor (rotor's decision 34, \"Upkeep\").",
        .{ pinned, version },
    ));
}

comptime {
    require(builtin.zig_version);
}

const testing = std.testing;

test "the pinned version is accepted" {
    try testing.expect(accepts(pinned));
}

test "a version above the pinned one is refused" {
    var next_patch = pinned;
    next_patch.patch += 1;
    try testing.expect(!accepts(next_patch));

    var next_minor = pinned;
    next_minor.minor += 1;
    try testing.expect(!accepts(next_minor));

    var next_major = pinned;
    next_major.major += 1;
    try testing.expect(!accepts(next_major));
}

test "a version below the pinned one is refused" {
    // 0.0.0 is below each version that a release can pin.
    comptime assert(pinned.major + pinned.minor + pinned.patch > 0);
    try testing.expect(!accepts(.{ .major = 0, .minor = 0, .patch = 0 }));

    // A development build of the pinned version sorts below its release.
    var development = pinned;
    development.pre = "dev.1";
    try testing.expect(!accepts(development));
}
