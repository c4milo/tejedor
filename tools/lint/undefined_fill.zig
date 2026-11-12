//! undefined-fill: no function of the library sets a local array to `undefined`. In Debug and
//! ReleaseSafe, the only modes that tejedor's build offers, Zig writes a pattern over each
//! `undefined` value. So `var contexts: [32]Context = undefined;` stores the whole array each time
//! the function runs, whether the function uses one element or none. rotor's lint records the
//! cost: until 2026-09-29, two such arrays took about a quarter of the own cycles of a kqueue
//! tick (rotor's decision 12, point 6).
//!
//! What the rule reads under `src/`:
//!
//! - It reads each `var` inside a function body. It does not read one inside a `test` block, or
//!   one that is a member of a container.
//! - It stops at the line `const testing = std.testing;`, where each file of tejedor starts its
//!   tests. So it does not read a fixture, or a helper that only a test calls.
//! - It does not read a file whose stem ends in `_test` or holds `_test_`.
//! - It passes an array whose length is a number of at most 8, and an array whose declaration
//!   shows a size under 64 bytes.
//!
//! The configuration names no variable on a cold path. An entry there needs a reason beside it.
//!
//! The rule is pepegrillo's `undefined_fill`. This file holds tejedor's configuration of it, and
//! the fixtures that pin the configuration.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const undefined_fill = lint.rules.undefined_fill;

pub const config: undefined_fill.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_stem_segment = "_test",
    },
    .stop_at_testing_import = true,
};

const Rule = undefined_fill.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape of the configuration, and pepegrillo tests the rule.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

const filling_source: [:0]const u8 =
    \\const count = 32;
    \\fn resume_ready() void {
    \\    var contexts: [count]Context = undefined;
    \\    _ = &contexts;
    \\}
;

const filling_message =
    "var contexts is an array set to undefined, which Debug and ReleaseSafe fill on every call: " ++
    "write into the caller's memory, or declare it only where it is used";

test "undefined-fill reports a local array whose length is a name, in the library" {
    try expect_findings("src/tejedor.zig", filling_source, &.{filling_message});
}

test "undefined-fill passes a short array and an array under 64 bytes" {
    try expect_findings("src/tejedor.zig",
        \\fn copy() void {
        \\    var pair: [2]Context = undefined;
        \\    var bytes: [48]u8 = undefined;
        \\    _ = &pair;
        \\    _ = &bytes;
        \\}
    , &.{});
}

test "undefined-fill does not read a test file or a file outside src/" {
    try expect_findings("src/tejedor_test.zig", filling_source, &.{});
    try expect_findings("src/tejedor_test_cancel.zig", filling_source, &.{});
    try expect_findings("bench/probe.zig", filling_source, &.{});
    try expect_findings("tools/lint/main.zig", filling_source, &.{});
}

test "undefined-fill stops where a file of tejedor starts its tests" {
    try expect_findings("src/tejedor.zig",
        \\const std = @import("std");
        \\const testing = std.testing;
        \\const count = 32;
        \\fn fixture() void {
        \\    var contexts: [count]Context = undefined;
        \\    _ = &contexts;
        \\}
    , &.{});
}
