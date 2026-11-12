//! unbounded-loop: a named limit bounds each loop (CLAUDE.md, non-negotiable 1).
//!
//! Over each `.zig` file under `src/`, the rule reports two shapes:
//!   1. `while (true)` with no `break`, or with a `break` and no named limit in the loop;
//!   2. a condition that compares a length read against an integer literal, with no named limit
//!      in the loop: `while (ready.count() > 0)`. A length read is a call or a field whose last
//!      name is one of `length_reader_names`.
//!
//! A named limit is a chain that holds the segment `constants`, or that ends in `_max`.
//!
//! The rule reads the shape of the source, and not its arithmetic. So it does not prove that a
//! loop has a bound. It finds the two shapes that show no bound. The assertion on the count of
//! turns at run time proves the bound.
//!
//! The rule is pepegrillo's `unbounded_loop`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const unbounded_loop = lint.rules.unbounded_loop;

const length_reader_names = [_][]const u8{
    "remaining", "len", "size", "count", "ready", "pending",
};

pub const config: unbounded_loop.Config = .{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .forever = .unless_bounded_break,
    .length_read = true,
    .bound = .{ .segments = &.{"constants"}, .last_segment_suffixes = &.{"_max"} },
    .length_reader_names = &length_reader_names,
    .messages = .{
        .forever_without_break = "while (true) has no break; nothing ends the loop",
        .forever_without_bound = "while (true) breaks on no named limit;" ++
            " bound it with a value of constants.zig",
        .length_read = "the condition reads {[read]s} against a literal" ++
            " and the loop names no limit",
    },
};

const Rule = unbounded_loop.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/tejedor.zig", source);
    try harness.expect_messages(findings, expected);
}

test "unbounded-loop passes a loop that a value of constants.zig bounds" {
    // The name of the limit does not end in `_max`. So the segment `constants` alone bounds the
    // loop.
    try expect_findings(
        \\pub fn hand_over(events: *Events) void {
        \\    var handled: u32 = 0;
        \\    while (events.count() > 0) : (handled += 1) {
        \\        if (handled == constants.events_per_tick) break;
        \\        events.hand_over_first();
        \\    }
        \\}
    , &.{});
}

test "unbounded-loop passes a while (true) that breaks on a limit named _max" {
    try expect_findings(
        \\pub fn submit(reactor: *Reactor, tries_max: u32) void {
        \\    var tries: u32 = 0;
        \\    while (true) : (tries += 1) {
        \\        if (tries == tries_max) break;
        \\        if (reactor.submit_one()) break;
        \\    }
        \\}
    , &.{});
}

test "unbounded-loop flags a loop with no limit, and each while (true) with no named limit" {
    try expect_findings(
        \\pub fn resume_ready(list: *ReadyList) void {
        \\    while (list.count() > 0) list.resume_first();
        \\    while (true) list.resume_first();
        \\    while (true) {
        \\        if (list.resume_first()) break;
        \\    }
        \\}
    , &.{
        "the condition reads list.count against a literal and the loop names no limit",
        "while (true) has no break; nothing ends the loop",
        "while (true) breaks on no named limit; bound it with a value of constants.zig",
    });
}

test "unbounded-loop reads src/ alone" {
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(!config.scope.applies("bench/probe.zig"));
    try testing.expect(!config.scope.applies("tools/lint/main.zig"));
}
