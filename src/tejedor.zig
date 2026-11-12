//! tejedor gives a `std.Io` on fibers over a reactor of rotor. With it, `io.async`,
//! `future.await`, `future.cancel` and the `Io.Group` calls work on the one thread that owns the
//! reactor. The design is rotor's decision 34. The first record of this package points at it:
//! `docs/decisions/0001-the-package-starts-from-rotors-decision-34.md`.
//!
//! The package is at step 0 of its build order: the context switch of a fiber, its tests and its
//! probe. Step 0 holds only the switch, so this file exports no name yet. Step 1 adds the fibers
//! and the `std.Io` on them.
//!
//! Each release pins one Zig version and one rotor tag. `zig_version.zig` refuses each other Zig
//! version, and `build.zig.zon` holds the rotor tag with its hash.
const std = @import("std");
const rotor = @import("rotor");

comptime {
    // A build with another Zig version stops here, with the reason.
    _ = @import("zig_version.zig");
}

const testing = std.testing;

/// Each declaration that the package asks of a reactor's type (rotor's decision 34, "What
/// `Fibers(Reactor)` asks of the reactor's type").
const reactor_names = [_][]const u8{
    "tick",
    "submit",
    "cancel",
    "now_ns",
    "add_poller",
    "remove_poller",
    "shared",
    "SharedLoop",
    "Service",
};

test "the pinned rotor gives the reactor that the package ticks" {
    const Reactor = rotor.Reactor(rotor.Loop);
    inline for (reactor_names) |name| {
        try testing.expect(@hasDecl(Reactor, name));
    }
}

test {
    _ = @import("zig_version.zig");
}
