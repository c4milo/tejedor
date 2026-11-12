//! defer-order: a `defer` that a function registers under a statement that can fail. When that
//! statement returns its error, the function has not registered the `defer` yet. So what the
//! function acquired above the statement leaks.
//!
//! rotor found this shape in a bench program on 2026-09-22. The program opened one socket for
//! each connection, and registered the cleanup under the call that can fail. A server that did
//! not start made each connect fail, and one run ended with no descriptor left.
//!
//! The rule reads `src/` and `bench/`: the package, and each program that measures it. It does
//! not read `tools/`. A developer tool runs once and exits, so a leak there costs a process that
//! ends at once.
//!
//! The rule is pepegrillo's `defer_order`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const defer_order = lint.rules.defer_order;

pub const config: defer_order.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{ "src", "bench" },
    },
};

const Rule = defer_order.Rule(config);
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

test "defer-order passes a cleanup that names what the statement before it produced" {
    try expect_findings("src/tejedor.zig",
        \\pub fn run(path: []const u8) !void {
        \\    const file = try open_file(path);
        \\    defer close_now(file);
        \\    var reactor: Reactor = undefined;
        \\    try reactor.init(&memory);
        \\    defer reactor.deinit();
        \\}
    , &.{});
}

/// The finding of the rule. The harness matches the whole text.
const message = "a defer after a statement that can fail; anything acquired above it leaks when" ++
    " that statement returns";

test "defer-order reads src and bench, and does not read tools" {
    const leaking: [:0]const u8 =
        \\pub fn run() !void {
        \\    try connect_all(&client);
        \\    defer close_all();
        \\}
    ;
    try expect_findings("src/tejedor.zig", leaking, &.{message});
    try expect_findings("bench/probe.zig", leaking, &.{message});
    try expect_findings("tools/lint/main.zig", leaking, &.{});
    try expect_findings("build/tools.zig", leaking, &.{});
}
