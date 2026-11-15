//! tejedor gives a `std.Io` on fibers over a reactor of rotor. With it, `io.async`,
//! `future.await`, `future.cancel` and the `Io.Group` calls work on the one thread that owns the
//! reactor. The design is rotor's decision 34. The first record of this package points at it:
//! `docs/decisions/0001-the-package-starts-from-rotors-decision-34.md`.
//!
//! A program makes its reactor, and a `Fibers` value over it:
//!
//! ```zig
//! const Reactor = rotor.Reactor(rotor.Loop);
//! const Fibers = tejedor.Fibers(Reactor);
//!
//! var fibers: Fibers = undefined;
//! try fibers.init(&reactor, memory, rest, &.{});
//! defer fibers.deinit();
//! const io = fibers.io();
//! ```
//!
//! The package is at step 1 of its build order: contexts, std tasks, `Io.Group`s, cancel, futexes,
//! `now`, `sleep` and the `netLookup` wrapper, on one thread. Camilo ruled each name of this file
//! on 2026-11-14 (record 7).
//!
//! Each release pins one Zig version and one rotor tag. `zig_version.zig` refuses each other Zig
//! version, and `build.zig.zon` holds the rotor tag with its hash.
const std = @import("std");
const fibers = @import("fibers.zig");
const switching = @import("switch.zig");

comptime {
    // A build with another Zig version stops here, with the reason.
    _ = @import("zig_version.zig");
}

/// A `std.Io` on fibers over a reactor of type `Reactor`: `rotor.Reactor(rotor.Loop)`, or the
/// reactor of a twin (rotor's decision 34, question 14).
pub const Fibers = fibers.Fibers;

/// Takes each event that a tick returns and no record of the package takes.
pub const EventHandler = fibers.EventHandler;

/// The alignment of the memory that `Fibers.init` takes.
pub const memory_alignment = fibers.memory_alignment;

/// The named limits of the package.
pub const constants = @import("constants.zig");

/// True where the context switch has a form for the target of the build (record 5). `Fibers`
/// fails to compile where it is false.
pub const supported = switching.supported;

test {
    _ = @import("zig_version.zig");
    _ = @import("switch.zig");
    _ = @import("switch_test.zig");
    _ = @import("lists.zig");
    _ = @import("memory.zig");
    _ = @import("reactor_check.zig");
    _ = @import("fibers_test.zig");
}
