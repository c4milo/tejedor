//! heap: tejedor names no allocator (CLAUDE.md, non-negotiable 1). The program hands the package
//! its memory at `init`. No file under `src/` names an allocator, so no code path there can
//! allocate.
//!
//! Over each `.zig` file under `src/`, the rule makes two checks:
//!   1. a chain that starts with one of `forbidden_prefixes` at a dot boundary: `std.heap`, and
//!      the allocators of `std.testing`. A test that needs memory declares a fixed array;
//!   2. a parameter whose type names `Allocator`, on each function, `init` included.
//!
//! The rule cannot see an allocator that a function takes as `anytype`.
//!
//! The rule is pepegrillo's `forbidden_references`. This file holds tejedor's configuration of it,
//! and the fixtures that pin the configuration.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const forbidden_references = lint.rules.forbidden_references;

/// Each chain that names an allocator. The list names `std.testing` member by member, because
/// each test uses the rest of it.
const forbidden_prefixes = [_][]const u8{
    "std.heap",
    "std.testing.allocator",
    "std.testing.allocator_instance",
    "std.testing.failing_allocator",
    "std.testing.FailingAllocator",
};

comptime {
    // Each name above must still name a declaration of the standard library. A Zig upgrade that
    // removes one stops this build, so no entry stays that guards nothing.
    lint.assert_all_resolve(std, "std", &forbidden_prefixes);
}

const reason = "tejedor names no allocator; the program hands over the memory at init";

/// The one call of `std.heap` that the package makes: the size of a page of the host, for the
/// guard page of each stack (rotor's decision 34, question 5). It names no allocator. The
/// exception is a choice of the session of 2026-11-14 (record 7).
const exceptions = [_]forbidden_references.Exception{
    .{ .prefix = "std.heap", .last_segment_prefixes = &.{"pageSize"} },
};

/// The configuration. It reads `src/` alone, because the build links no file outside `src/` into
/// the package.
pub const config: forbidden_references.Config = .{
    .name = "heap",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .prefixes = &forbidden_prefixes,
    .exceptions = &exceptions,
    .parameter_check = .{ .type_segment = "Allocator", .description = "an allocator parameter" },
    .reason = reason,
};

const Rule = forbidden_references.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape from the header.

const testing = std.testing;
const harness = lint.harness;

const failing_fixture: [:0]const u8 =
    \\const std = @import("std");
    \\const arena_type = std.heap.ArenaAllocator;
    \\pub fn init(allocator: std.mem.Allocator, stack_bytes: u32) !void {
    \\    _ = allocator;
    \\    _ = stack_bytes;
    \\}
;

test "heap passes an init that takes its memory as a slice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/tejedor.zig",
        \\pub fn init(stack: *Stack, memory: []align(page_bytes) u8) void {
        \\    stack.memory = memory;
        \\}
    );
    try harness.expect_messages(findings, &.{});
}

test "heap flags std.heap and an allocator parameter, init included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const findings = try harness.run(arena, Rule, "src/tejedor.zig", failing_fixture);
    try harness.expect_messages(findings, &.{
        "reference to std.heap.ArenaAllocator: " ++ reason,
        "init takes an allocator parameter: " ++ reason,
    });
}

test "heap passes the size of a page, and flags each other name of std.heap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/memory.zig",
        \\const std = @import("std");
        \\pub fn page_bytes() usize {
        \\    return std.heap.pageSize();
        \\}
        \\const page = std.heap.page_allocator;
    );
    try harness.expect_messages(findings, &.{
        "reference to std.heap.page_allocator: " ++ reason,
    });
}

test "heap flags an allocator of std.testing inside a test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/tejedor.zig",
        \\const std = @import("std");
        \\test "a stack holds bytes" {
        \\    const bytes = try std.testing.allocator.alloc(u8, 16);
        \\    defer std.testing.allocator.free(bytes);
        \\}
    );
    try harness.expect_messages(findings, &.{
        "reference to std.testing.allocator.alloc: " ++ reason,
        "reference to std.testing.allocator.free: " ++ reason,
    });
}

test "heap reads src/ alone" {
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(config.scope.applies("src/zig_version.zig"));
    try testing.expect(!config.scope.applies("tools/lint/main.zig"));
    try testing.expect(!config.scope.applies("bench/probe.zig"));
    try testing.expect(!config.scope.applies("build/tools.zig"));
    try testing.expect(!config.scope.applies("build.zig"));
}
