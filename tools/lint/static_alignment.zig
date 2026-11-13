//! static-alignment: a container-level `var` states its own alignment (CLAUDE.md, Conventions).
//!
//! Zig 0.16's own x86-64 backend builds Debug on x86-64. It places a static without the alignment
//! that its type takes from an aligned field, unless the variable declares it. rotor found this
//! on 2026-09-23, when a new static moved a test fixture 32 bytes off its 64-byte boundary. So
//! over each `.zig` file that the lint reads, the rule reports a container-level `var` of a named
//! type that declares no `align(...)`. It asks for `align(@alignOf(T))`.
//!
//! The build makes the tests, the bench programs and the tools for x86-64, as it makes the
//! package, so no directory of them is exempt. `docs/zig-report/` is exempt. It holds the
//! attachments of the draft of a report to Zig: the programs that ran, which the build does not
//! compile.
//!
//! The rule is pepegrillo's `static_alignment`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const static_alignment = lint.rules.static_alignment;

pub const config: static_alignment.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .exclude_directories = &.{"docs/zig-report"},
    },
};

const Rule = static_alignment.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

const failing_fixture: [:0]const u8 = "var context: Context = undefined;";
const failing_message = "var context declares no alignment: write align(@alignOf(Context))";

test "static-alignment asks a static of a named type for its alignment in each directory" {
    try expect_findings("src/tejedor.zig", failing_fixture, &.{failing_message});
    try expect_findings("src/tejedor_test.zig", failing_fixture, &.{failing_message});
    try expect_findings("bench/probe.zig", failing_fixture, &.{failing_message});
    try expect_findings("tools/lint/main.zig", failing_fixture, &.{failing_message});
    try expect_findings("build/tools.zig", failing_fixture, &.{failing_message});
    try expect_findings("build.zig", failing_fixture, &.{failing_message});
}

test "static-alignment does not read the attachments of the report to Zig" {
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(config.scope.applies("docs/other.zig"));
    try testing.expect(!config.scope.applies("docs/zig-report/fiber_switch.zig"));
}

test "static-alignment passes a static that states its alignment, and a buffer of bytes" {
    try expect_findings("src/tejedor_test.zig",
        \\var context: Context align(@alignOf(Context)) = undefined;
        \\var stack: [stack_bytes]u8 align(16) = undefined;
        \\var bytes: [16]u8 = undefined;
    , &.{});
}
