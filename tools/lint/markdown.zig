//! markdown: each Markdown file is GitHub-flavored Markdown, and must render on GitHub as written
//! (CLAUDE.md, Conventions). A person reads the decision records there.
//!
//! Over each `.md` file, the rule makes four checks:
//!   1. a bare pseudo list item such as `3b. `, which GitHub folds into the paragraph above;
//!   2. a fenced code block that opens with no language;
//!   3. a table row whose column count differs from the count of its header. The rule splits the
//!      cells on each `|` that no backslash escapes, as GitHub does;
//!   4. whitespace at the end of a line, which is a hard line break that the source does not show.
//!
//! Checks 1, 2 and 3 skip the inside of a fenced code block. Check 4 does not.
//!
//! The rule is pepegrillo's `markdown`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const markdown = lint.rules.markdown;

pub const config: markdown.Config = .{
    .scope = .{ .extensions = &.{".md"} },
    .pseudo_list_item = true,
    .pseudo_list_letters = .any,
    .pseudo_list_column = .first,
    .fence_language = true,
    .table_columns = true,
    .trailing_whitespace = true,
    .messages = .{
        .pseudo_list_item = "bare \"{[marker]s}\" folds into the paragraph above on GitHub;" ++
            " nest it as a list item",
        .fence_language = "fenced code block opened with no language",
        .table_columns = "table row holds {[columns]d} columns;" ++
            " its header holds {[header_columns]d}",
        .trailing_whitespace = "trailing whitespace",
    },
};

const Rule = markdown.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

test "markdown passes a table, a list and a fence with a language" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "docs/results.md",
        \\# Results
        \\
        \\| workload | ns |
        \\|---|---|
        \\| one switch out and back | 0 |
        \\
        \\1. Build the probe.
        \\2. Run it.
        \\
        \\```bash
        \\zig build test
        \\```
    );
    try harness.expect_messages(findings, &.{});
}

test "markdown flags a pseudo list item, a wide row, a bare fence and trailing whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(
        arena_state.allocator(),
        Rule,
        "docs/results.md",
        "3b. step\n\n| a | b |\n|---|---|\n| 1 | 2 | 3 |\n\n```\ncode\n```\nend \n",
    );
    try harness.expect_messages(findings, &.{
        "bare \"3b.\" folds into the paragraph above on GitHub; nest it as a list item",
        "table row holds 3 columns; its header holds 2",
        "fenced code block opened with no language",
        "trailing whitespace",
    });
}

test "markdown reads each .md file and no other file" {
    try testing.expect(config.scope.applies("docs/decisions/0001-a-record.md"));
    try testing.expect(config.scope.applies("CLAUDE.md"));
    try testing.expect(config.scope.applies("README.md"));
    try testing.expect(!config.scope.applies("src/tejedor.zig"));
}
