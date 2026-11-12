//! file-length: a source file that a person wrote stays at or under 500 lines, with its tests
//! (CLAUDE.md, Conventions). Split the file, and do not raise the limit. Name each piece after the
//! file that it came from, and keep the first name as the entry point. The file that holds the
//! context switch has the same limit.
//!
//! Over each `.zig` and `.sh` file under `src/`, `tools/`, `build/` and `bench/`, the rule counts
//! the lines as an editor numbers them. It reports a file over the limit once, at the first line
//! past it. Markdown is exempt: the audited unit of a document is the section.
//!
//! The rule is pepegrillo's `file_length`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const file_length = lint.rules.file_length;

/// The most lines that one file may hold.
pub const lines_max: u32 = 500;

pub const config: file_length.Config = .{
    .scope = .{
        .extensions = &.{ ".zig", ".sh" },
        .include_directories = &.{ "src", "tools", "build", "bench" },
    },
    .lines_max = lines_max,
    .message_suffix = "; split the file",
};

const Rule = file_length.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

const fixture_line = "//\n";

test "file-length passes a file at the limit and flags a file one line over it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at_limit = try harness.run(arena, Rule, "src/tejedor.zig", fixture_line ** lines_max);
    try harness.expect_messages(at_limit, &.{});
    const over_limit = fixture_line ** (lines_max + 1);
    const over = try harness.run(arena, Rule, "src/tejedor.zig", over_limit);
    try harness.expect_messages(over, &.{"501 lines, over the 500-line limit; split the file"});
    try testing.expectEqual(lines_max + 1, over[0].line);
}

test "file-length reads .zig and .sh under src, tools, build and bench" {
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(config.scope.applies("tools/lint/main.zig"));
    try testing.expect(config.scope.applies("build/tools.zig"));
    try testing.expect(config.scope.applies("bench/run.sh"));
    try testing.expect(!config.scope.applies("docs/decisions/0001-a-record.md"));
    try testing.expect(!config.scope.applies("build.zig"));
}
