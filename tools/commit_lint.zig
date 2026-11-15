//! The commit-message linter of tejedor, for the Conventional Commit rules of CLAUDE.md
//! (Commits). It reads commit messages out of git, or one message from a file. It prints one line
//! for each finding, and it changes nothing.
//!
//! Run:  zig build lint-commits            # the commits that this branch adds to origin/main
//!       zig-out/bin/commit_lint --range REV [REV...]
//!       zig-out/bin/commit_lint --message PATH
//!
//! The linter is pepegrillo's. This file holds tejedor's configuration of it: the scopes of
//! CLAUDE.md, and the first words that it refuses because they are not imperative. The limits are
//! the limits that CLAUDE.md states, which are pepegrillo's defaults.
//!
//! `error` marks a rule of CLAUDE.md that a message broke. `warning` marks a scope outside the
//! table of CLAUDE.md, and it never changes the exit status: the table says which parts exist,
//! and this tool does not.
//!
//! Exit status: 0 when no message broke a rule, warnings included, and 1 when a message broke
//! one. It is 2 for a usage error, a message file that it cannot read, or a git log that failed.

const std = @import("std");
const pepegrillo = @import("pepegrillo");

/// The scopes that CLAUDE.md names: one for each part of the package.
pub const part_scopes = [_][]const u8{
    "switch",
    "fibers",
    "bench",
    "tools",
};

/// First words that describe the commit, where the rule asks for a command.
const third_person_forms = [_][]const u8{
    "adds",    "fixes", "updates", "removes", "implements", "splits",
    "renames", "moves", "makes",   "drops",   "lands",      "keeps",
};

/// Commands that end in `ed` or `ing`.
const imperative_exceptions = [_][]const u8{
    "bring",  "embed", "seed", "speed", "feed", "exceed", "proceed", "succeed", "shed", "ring",
    "string",
};

/// The keys that a trailer paragraph may name: pepegrillo's default set without `Co-Authored-By`,
/// because CLAUDE.md forbids that trailer.
///
/// **This does not refuse the trailer, and the tests below say so.** `trailer_keys` names the keys
/// that a trailer may use. A last paragraph that names another key counts as body. So the trailer
/// takes one of the three paragraphs that CLAUDE.md allows a body: the linter refuses a message
/// whose body is full, and passes a shorter one. A refusal needs a rule for a forbidden trailer,
/// which the pinned pepegrillo does not have.
const trailer_keys = [_][]const u8{ "Signed-off-by", "Reviewed-by", "Refs", "Closes" };

pub const config: pepegrillo.commit.Config = .{
    .scope_admits_digits = false,
    .trailer_keys = &trailer_keys,
    .known_scopes = &part_scopes,
    .unknown_scope_reason = "is not a part of the package",
    .third_person_forms = &third_person_forms,
    .imperative_exceptions = &imperative_exceptions,
};

pub fn main(init: std.process.Init) !void {
    return pepegrillo.commit.main(init, config);
}

// Tests. pepegrillo tests the rules, and these tests pin tejedor's configuration of them.

const testing = std.testing;
const commit = pepegrillo.commit;

fn expect_findings(text: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var findings: commit.Findings = .{ .arena = arena, .findings_max = config.findings_max };
    try commit.lint_message_text(arena, config, &findings, "message", text);
    try testing.expectEqual(expected.len, findings.items.items.len);
    for (findings.items.items, expected) |finding, wanted| {
        const line = try std.fmt.allocPrint(arena, "{s}: {s}: {s}", .{
            finding.severity.text(), finding.rule, finding.message,
        });
        try testing.expectEqualStrings(wanted, line);
    }
}

test "each scope that CLAUDE.md names passes" {
    // The scopes are written out here and not read from `part_scopes`. So this test fails when a
    // scope leaves that list.
    const scopes = [_][]const u8{ "switch", "fibers", "bench", "tools" };
    try testing.expectEqual(scopes.len, part_scopes.len);
    for (scopes) |scope| {
        var buffer: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "feat({s}): add the probe\n", .{scope});
        try expect_findings(text, &.{});
    }
}

test "a subject with no scope passes" {
    try expect_findings("build: add the package skeleton on rotor v0.11.0\n", &.{});
    try expect_findings("ci: run the tests on three kinds of runner\n", &.{});
}

test "a well-formed scope outside the table draws a warning" {
    // `windows` cannot become a part of the package: the package runs on macOS and Linux alone.
    try expect_findings("feat(windows): add the completion port\n", &.{
        "warning: scope-known: the scope \"windows\" is not a part of the package" ++
            " (switch, fibers, bench, tools)",
    });
}

test "a third-person subject is refused" {
    try expect_findings("feat(switch): adds the entry of a fiber\n", &.{
        "error: subject-description: \"adds\" is a third-person form, not imperative",
    });
}

test "a command that ends in ed passes, and a past tense is refused" {
    try expect_findings("feat(switch): embed the size of the stack\n", &.{});
    try expect_findings("feat(switch): added the entry of a fiber\n", &.{
        "error: subject-description: \"added\" is a past tense, not imperative",
    });
}

test "a scope that holds a digit is refused" {
    try expect_findings("feat(h2): add the frame\n", &.{
        "error: subject-format: the scope holds a byte that is not a lowercase letter" ++
            " or a hyphen: \"feat(h2): add the frame\"",
    });
}

test "a type outside the list of CLAUDE.md is refused" {
    try expect_findings("feature: add the probe\n", &.{
        "error: subject-format: the type is not one of" ++
            " feat, fix, docs, test, refactor, perf, build, ci, chore: \"feature: add the probe\"",
    });
}

test "the types are the nine types of CLAUDE.md" {
    const types = [_][]const u8{
        "feat", "fix", "docs", "test", "refactor", "perf", "build", "ci", "chore",
    };
    try testing.expectEqual(types.len, config.commit_types.len);
    for (types) |commit_type| {
        var buffer: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{s}: add the probe\n", .{commit_type});
        try expect_findings(text, &.{});
    }
}

test "the limits are the limits of CLAUDE.md" {
    try testing.expectEqual(72, config.subject_columns_max);
    try testing.expectEqual(100, config.body_columns_max);
    try testing.expectEqual(3, config.body_paragraphs_max);
    try testing.expectEqual(100, config.body_words_max);
}

test "a Co-Authored-By paragraph is body, and one alone breaks no rule" {
    // The linter does not refuse the trailer, and this test records that fact. A message with
    // room in its body still passes with the trailer on it.
    //
    // When a pinned pepegrillo refuses a forbidden trailer key, this expectation changes from no
    // finding to one. This test then fails until a person writes the new finding here.
    try expect_findings(
        "feat(bench): do a thing\n\nOne paragraph that says why.\n\n" ++
            "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\n",
        &.{},
    );
}

test "a Co-Authored-By paragraph takes one of the three paragraphs of the body" {
    // The trailer is body, so it takes a paragraph. A commit with a full body and the trailer is
    // refused. The finding names the size of the body, and not the trailer.
    try expect_findings(
        "feat(bench): do a thing\n\nOne.\n\nTwo.\n\nThree.\n\n" ++
            "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\n",
        &.{"error: body-size: the body has 4 paragraphs, over the limit of 3"},
    );
}

test "the keys that remain are trailers" {
    // The same body of three paragraphs passes with a key that the set still names. So the change
    // removed one key, and trailers still work.
    try expect_findings("feat(bench): do a thing\n\nOne.\n\nTwo.\n\nThree.\n\nRefs: #4\n", &.{});
}
