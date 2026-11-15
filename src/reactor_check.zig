//! The check that `Fibers(Reactor)` makes at comptime, before it makes a type (rotor's decision 34,
//! "What `Fibers(Reactor)` asks of the reactor's type"). It collects each declaration that
//! `Reactor` lacks, and stops the build with one compile error that names them all, as rotor's
//! check of a twin does (rotor's `src/reactor/reactor_check.zig`).
//!
//! The check sees names, not signatures. A wrong signature fails where the package calls it.
const std = @import("std");

/// A declaration that the package asks of a reactor's type, and what it is for.
const Need = struct { name: []const u8, what: []const u8 };

/// Each declaration of the table of decision 34, in its order. This is the whole list.
pub const needs = [_]Need{
    .{ .name = "tick", .what = "the tick, which only the package calls while the value lives" },
    .{ .name = "submit", .what = "the submit of an operation of a context" },
    .{ .name = "cancel", .what = "the cancel of an operation of a context" },
    .{ .name = "now_ns", .what = "the clock of the last tick, for the awake and boot clocks" },
    .{ .name = "add_poller", .what = "the add of the poller of the package" },
    .{ .name = "remove_poller", .what = "the remove of the poller of the package" },
    .{ .name = "shared", .what = "the view, for a cross-core call" },
    .{ .name = "SharedLoop", .what = "the type of the view" },
    .{ .name = "Service", .what = "the cross-core calls of the reactor, for a call" },
};

/// The last line of the message, which says what to pass.
const advice = "A program passes rotor.Reactor(rotor.Loop), and a test can pass " ++
    "rotor.Reactor(Twin) for a twin (rotor's decision 34, \"Over a twin\").";

/// Stops the build when `Reactor` lacks a declaration that the package needs, and names each one.
pub fn check(comptime Reactor: type) void {
    if (comptime message(Reactor)) |text| @compileError(text);
}

/// The message of `check`, or null when `Reactor` declares each name. Each name that it lacks is
/// one line.
pub fn message(comptime Reactor: type) ?[]const u8 {
    comptime {
        var lines: []const u8 = "";
        var count: usize = 0;
        for (needs) |need| {
            if (@hasDecl(Reactor, need.name)) continue;
            lines = lines ++ "\n  " ++ need.name ++ ": " ++ need.what;
            count += 1;
        }
        if (count == 0) return null;
        const noun = if (count == 1) "declaration" else "declarations";
        const heading = std.fmt.comptimePrint(
            "tejedor.Fibers({s}): the type lacks {d} {s} that the package needs:",
            .{ @typeName(Reactor), count, noun },
        );
        return heading ++ lines ++ "\n" ++ advice;
    }
}

const testing = std.testing;
const rotor = @import("rotor");

test "the reactor of the host declares each name that the package needs" {
    try testing.expectEqual(null, comptime message(rotor.Reactor(rotor.Loop)));
}

/// A type that declares each name but `tick` and `shared`.
const Partial = struct {
    pub const submit = {};
    pub const cancel = {};
    pub const now_ns = {};
    pub const add_poller = {};
    pub const remove_poller = {};
    pub const SharedLoop = {};
    pub const Service = {};
};

test "the message names each declaration that a type lacks, one for each line" {
    const text = comptime message(Partial).?;
    try testing.expect(std.mem.indexOf(u8, text, "lacks 2 declarations") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n  tick: ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n  shared: ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n  submit: ") == null);
}
