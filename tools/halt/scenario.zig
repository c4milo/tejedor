//! What each executable of halt scenarios shares (rotor's decision 34, "Upkeep"). A scenario
//! breaks one assertion of the package on purpose. `tools/halt_check.zig` runs it in a child
//! process, and that process must die by a signal. A Zig test cannot expect a panic in its own
//! process, so this is the one way to test that an assertion halts.
//!
//! Run:  <scenarios> --list          prints the name of each scenario, one on each line
//!       <scenarios> NAME            prepares the scenario, prints `marker`, then breaks the rule
//!
//! A scenario calls `reached_violation` right before the statement that must halt. The check
//! requires the marker on standard output, so a scenario that dies during its preparation does not
//! pass as a halt. Each scenario also names a text that the panic prints on standard error. The
//! check requires it too, so a halt of another kind, such as an integer overflow after the deleted
//! assertion, does not pass either. This file is rotor's `tools/halt/scenario.zig`, with that text.
const std = @import("std");
const Io = std.Io;

/// Printed right before the statement that breaks the rule.
pub const marker = "violating";

/// The text of the panic of a failed `assert`, in Debug and in ReleaseSafe.
pub const assertion = "reached unreachable code";

pub const Scenario = struct {
    name: []const u8,
    run: *const fn () void,
    /// A text that standard error holds when the process dies as the scenario expects. An empty
    /// text matches each death by a signal, for a fault that no panic handler reports.
    expected: []const u8,
};

/// The exit status of a scenario that ran to its end: the assertion did not halt.
pub const exit_did_not_halt = 0;
/// The exit status for a name that no scenario has, or for no argument.
pub const exit_usage = 2;
/// The exit status of a scenario that still ran when the watchdog woke: the assertion did not
/// halt, and the process waited with no end.
pub const exit_hung = 3;

/// The seconds that a scenario may run. A scenario whose check is deleted can wait with no end,
/// such as a second `await` of one future. The watchdog ends it, so the check reports it.
const watchdog_s = 10;

const output_bytes = 256;

var stdout_buffer: [output_bytes]u8 = undefined;
var stdout_writer: ?Io.File.Writer align(@alignOf(Io.File.Writer)) = null;

/// Prints the marker and flushes it, so it is in the pipe before the process dies.
pub fn reached_violation() void {
    const writer = &stdout_writer.?.interface;
    writer.print("{s}\n", .{marker}) catch {};
    writer.flush() catch {};
}

/// Lists each scenario as a line `NAME<tab>EXPECTED`, or runs the one that the argument names.
pub fn main(init: std.process.Init, comptime scenarios: []const Scenario) !void {
    stdout_writer = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout_writer.?.interface;
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const wanted = arguments.next() orelse std.process.exit(exit_usage);
    if (std.mem.eql(u8, wanted, "--list")) {
        inline for (scenarios) |scenario| try writer.print("{s}\t{s}\n", .{ scenario.name, scenario.expected });
        return writer.flush();
    }
    inline for (scenarios) |scenario| {
        if (std.mem.eql(u8, wanted, scenario.name)) {
            const watchdog = try std.Thread.spawn(.{}, watch, .{init.io});
            watchdog.detach();
            scenario.run();
            std.process.exit(exit_did_not_halt);
        }
    }
    std.process.exit(exit_usage);
}

/// Ends the process after `watchdog_s` seconds, with `exit_hung`.
fn watch(io: Io) void {
    io.sleep(.fromSeconds(watchdog_s), .awake) catch {};
    std.process.exit(exit_hung);
}
