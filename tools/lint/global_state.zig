//! global-state: a container-level `var` under `src/` is `threadlocal` (CLAUDE.md, non-negotiable
//! 2: one thread owns a value of the package, and the package starts no thread). A `var` that
//! each thread shares is one copy for the whole process. A program with one reactor for each core
//! makes one value of the package for each, and two values would race on that copy. So the rule
//! refuses it: hand the state over at `init`, or make it the thread's own.
//!
//! The rule does not read a file whose stem ends in `_test` or holds `_test_`. Such a file is a
//! test from its first line to its last. Its `var`s are fixtures, such as the memory that a test
//! hands to the package. No file of the library imports one.
//!
//! The rule is pepegrillo's `global_state`. This file holds tejedor's configuration of it, and the
//! fixtures that pin the configuration.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const global_state = lint.rules.global_state;

pub const config: global_state.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_stem_segment = "_test",
    },
};

const Rule = global_state.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape of the configuration.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

const shared_fixture: [:0]const u8 = "var shared: u32 = 0;";
const shared_message =
    "var shared is state every thread shares: make it threadlocal, or hand it in";

test "global-state flags a var that each thread shares, and passes a var of the thread" {
    try expect_findings("src/tejedor.zig", shared_fixture, &.{shared_message});
    try expect_findings("src/tejedor.zig", "threadlocal var marker: u8 = 0;", &.{});
}

test "global-state flags a var of a container that a function declares" {
    try expect_findings("src/tejedor.zig",
        \\fn count() u32 {
        \\    const Counter = struct {
        \\        var shared: u32 = 0;
        \\    };
        \\    Counter.shared += 1;
        \\    return Counter.shared;
        \\}
    , &.{shared_message});
}

test "global-state reads the library under src/, and not a test file or a file outside src/" {
    try expect_findings("src/tejedor_test.zig", shared_fixture, &.{});
    try expect_findings("src/tejedor_test_cancel.zig", shared_fixture, &.{});
    try expect_findings("bench/probe.zig", shared_fixture, &.{});
    try expect_findings("tools/lint/main.zig", shared_fixture, &.{});
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(config.scope.applies("src/zig_version.zig"));
}
