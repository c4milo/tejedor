//! magic-numbers: each limit has a name, and no limit is written inline (CLAUDE.md, non-negotiable
//! 1).
//!
//! Over each `.zig` file under `src/`, the rule reports an integer literal greater than 1. It does
//! not report a literal that is the whole value of a `const` declaration or of a container field,
//! because that declaration names it. It does not read a `test` block or a `comptime` block: a
//! test states the numbers that it checks, and a layout assert checks a number.
//!
//! The rule does not read three kinds of file:
//!
//! - `constants.zig`, which holds the names;
//! - a file whose stem ends in `_test` or holds `_test_`, which is a test from its first line
//!   to its last, helpers included;
//! - `src/zig_version.zig`. Its one number is the minor number of the pinned Zig version. The
//!   field `minor` of the constant `pinned` names it. The rule reads syntax, and a field of a
//!   struct literal is no name to it.
//!
//! The rule is pepegrillo's `magic_numbers`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const magic_numbers = lint.rules.magic_numbers;

pub const config: magic_numbers.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_paths = &.{"src/zig_version.zig"},
        .exclude_basenames = &.{"constants.zig"},
        .exclude_stem_segment = "_test",
    },
};

const Rule = magic_numbers.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

const failing_fixture: [:0]const u8 =
    \\pub fn resume_ready(list: *ReadyList) void {
    \\    var contexts: [256]u32 = undefined;
    \\    _ = list.copy(&contexts);
    \\}
;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

test "magic-numbers passes a named limit, a comptime layout assert and a test block" {
    try expect_findings("src/tejedor.zig",
        \\const resumes_per_copy = 256;
        \\pub fn resume_ready(list: *ReadyList) void {
        \\    var contexts: [resumes_per_copy]u32 = undefined;
        \\    comptime std.debug.assert(@sizeOf(Context) == 16);
        \\    _ = list.copy(&contexts);
        \\}
        \\test "a list holds 4 contexts" {
        \\    try std.testing.expectEqual(4, resume_ready(&list));
        \\}
    , &.{});
}

test "magic-numbers flags an inline array length under src" {
    try expect_findings("src/tejedor.zig", failing_fixture, &.{"integer literal 256"});
}

test "magic-numbers skips constants.zig, the pinned version, a test file and other trees" {
    try expect_findings("src/constants.zig", failing_fixture, &.{});
    try expect_findings("src/zig_version.zig", failing_fixture, &.{});
    try expect_findings("src/tejedor_test.zig", failing_fixture, &.{});
    try expect_findings("src/tejedor_test_cancel.zig", failing_fixture, &.{});
    try expect_findings("bench/probe.zig", failing_fixture, &.{});
    try expect_findings("tools/lint/main.zig", failing_fixture, &.{});
}
