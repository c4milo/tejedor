//! The halt check: proves that an assertion halts (rotor's decision 34, "Upkeep"). A Zig test
//! cannot expect a panic in its own process, so each scenario runs in a child process that must
//! die. This file is rotor's `tools/halt_check.zig`, with one more requirement.
//!
//! Run:  halt_check SCENARIOS [--expect-failures COUNT]
//!
//! SCENARIOS is an executable built on tools/halt/scenario.zig. The check lists its scenarios, runs
//! each in a child process, and requires three things of each:
//!
//! - the marker on its standard output, which shows that the scenario reached the statement that
//!   breaks the rule;
//! - a death by a signal, which is what a failed assertion is in Debug and in ReleaseSafe;
//! - the text that the scenario names, on its standard error. So a halt of another kind does not
//!   pass, such as an integer overflow after a deleted assertion.
//!
//! It prints one line for each scenario that did not halt as it must, and nothing for one that
//! did, because the build renders a step that writes to standard error as a failure.
//!
//! Exit status: 0 when each scenario halted; 1 when one did not; 2 on a usage error or for an
//! executable that lists no scenario. With `--expect-failures COUNT` the meaning flips, for the
//! canary: 0 when exactly COUNT scenarios did not halt, 1 otherwise.
//!
//! This program is a developer tool. The build links no part of it into the package, so it
//! allocates, and the rules of the package do not bind it.
const std = @import("std");
const Io = std.Io;
const scenario = @import("halt/scenario.zig");

/// The most scenarios that one executable may list.
const scenarios_max = 256;

const exit_ok = 0;
const exit_not_halted = 1;
const exit_usage = 2;

const Arguments = struct {
    executable: []const u8,
    /// Null for a real check. For the canary, how many scenarios must not halt.
    expected_failures: ?u32,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = parse(try init.minimal.args.toSlice(arena)) orelse {
        std.process.exit(exit_usage);
    };
    var error_buffer: [512]u8 = undefined;
    var errors = Io.File.stderr().writerStreaming(init.io, &error_buffer);
    const failures = try run_all(arena, init.io, arguments, &errors.interface);
    try errors.interface.flush();
    const wanted = arguments.expected_failures orelse 0;
    std.process.exit(if (failures == wanted) exit_ok else exit_not_halted);
}

fn parse(arguments: []const [:0]const u8) ?Arguments {
    if (arguments.len == 2) return .{ .executable = arguments[1], .expected_failures = null };
    if (arguments.len != 4) return null;
    if (!std.mem.eql(u8, arguments[2], "--expect-failures")) return null;
    const count = std.fmt.parseInt(u32, arguments[3], 10) catch return null;
    return .{ .executable = arguments[1], .expected_failures = count };
}

/// Runs each scenario that the executable lists, and returns how many did not halt as they must.
/// Exits with a usage error when the executable lists none, or more than `scenarios_max`.
fn run_all(arena: std.mem.Allocator, io: Io, arguments: Arguments, errors: *Io.Writer) !u32 {
    const executable = arguments.executable;
    const listing = try std.process.run(arena, io, .{ .argv = &.{ executable, "--list" } });
    var lines = std.mem.tokenizeScalar(u8, listing.stdout, '\n');
    var ran: u32 = 0;
    var failures: u32 = 0;
    while (lines.next()) |line| : (ran += 1) {
        if (ran == scenarios_max) std.process.exit(exit_usage);
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse std.process.exit(exit_usage);
        const name = line[0..tab];
        const verdict = try run_one(arena, io, executable, name, line[tab + 1 ..]);
        if (verdict == .halted) continue;
        failures += 1;
        if (arguments.expected_failures == null) {
            try errors.print("halt_check: {s}: {s}\n", .{ name, verdict.text() });
        }
    }
    if (ran == 0) std.process.exit(exit_usage);
    return failures;
}

const Verdict = enum {
    halted,
    exited,
    died_before_the_violation,
    died_another_way,

    fn text(verdict: Verdict) []const u8 {
        return switch (verdict) {
            .halted => "halted",
            .exited => "DID NOT HALT: the statement that breaks the rule returned",
            .died_before_the_violation => "DID NOT HALT: the scenario died during its preparation",
            .died_another_way => "DID NOT HALT: the process died, and standard error lacks the text of the scenario",
        };
    }
};

fn run_one(arena: std.mem.Allocator, io: Io, executable: []const u8, name: []const u8, expected: []const u8) !Verdict {
    const result = try std.process.run(arena, io, .{ .argv = &.{ executable, name } });
    const reached = std.mem.indexOf(u8, result.stdout, scenario.marker) != null;
    const said = std.mem.indexOf(u8, result.stderr, expected) != null;
    return switch (result.term) {
        .signal => if (!reached) .died_before_the_violation else if (said) .halted else .died_another_way,
        else => .exited,
    };
}
