//! switch-form: the package calls the context switch only in the form of record 3 (record 5).
//! `switch_context` has that form. `switch_other_form` has the other one: a call on aarch64, and
//! a copy on x86_64. On x86_64 a copy loses an `f80` value across the switch. So only
//! `src/switch.zig`, the tests and the probe may name `switch_other_form`.
//!
//! Over each `.zig` file under `src/`, the rule flags a chain that holds `switch_other_form` as one
//! segment, such as `switching.switch_other_form`. It does not read `src/switch.zig`, which
//! declares the name, or a test file: a file whose stem ends in `_test`, or holds `_test_`. The
//! probe is under `bench/`, which the rule does not read.
//!
//! What the rule cannot see:
//!
//! - a name that another file exports under another name;
//! - a field that `@field` reads by a string;
//! - a chain that starts with an `@import` written in place, such as
//!   `@import("switch.zig").switch_other_form`;
//! - a name written as a quoted identifier, such as `switching.@"switch_other_form"`.
//!
//! The rule is pepegrillo's `forbidden_references`. This file holds tejedor's configuration of it,
//! and the fixtures that pin the configuration.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const forbidden_references = lint.rules.forbidden_references;

/// The name of the other form of the switch, in `src/switch.zig`.
const other_form_names = [_][]const u8{"switch_other_form"};

const reason = "only the tests and the probe call the other form of the switch (record 5)";

pub const config: forbidden_references.Config = .{
    .name = "switch-form",
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_paths = &.{"src/switch.zig"},
        .exclude_stem_segment = "_test",
    },
    .segment_names = &other_form_names,
    .reason = reason,
};

const Rule = forbidden_references.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape from the header.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

test "switch-form passes a call of switch_context" {
    try expect_findings("src/fibers.zig",
        \\const switching = @import("switch.zig");
        \\pub fn block(message: *const switching.Switch) void {
        \\    switching.switch_context(message);
        \\}
    , &.{});
}

test "switch-form flags the other form, in a call and in an alias" {
    try expect_findings("src/fibers.zig",
        \\const switching = @import("switch.zig");
        \\const other = switching.switch_other_form;
        \\pub fn block(message: *const switching.Switch) void {
        \\    switching.switch_other_form(message);
        \\    other(message);
        \\}
    , &.{
        "reference to switching.switch_other_form: " ++ reason,
        "reference to switching.switch_other_form: " ++ reason,
    });
}

test "switch-form reads src/ alone, and not the switch or a test file" {
    try testing.expect(config.scope.applies("src/fibers.zig"));
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(!config.scope.applies("src/switch.zig"));
    try testing.expect(!config.scope.applies("src/switch_test.zig"));
    try testing.expect(!config.scope.applies("src/switch_test_form.zig"));
    try testing.expect(!config.scope.applies("bench/switch_probe.zig"));
    try testing.expect(!config.scope.applies("tools/compile_fail/switch_copy_on_x86_64.zig"));
}
