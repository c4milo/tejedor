//! The lint of tejedor: the rules of CLAUDE.md that a parser and a line scanner can check. Each
//! rule has one file under tools/lint/.
//!
//! Run: `zig build lint`. It passes no `--rule`, so each rule in the list below runs.
//! `--rule NAME` runs one rule by hand.
//!
//! The driver is pepegrillo's. It walks each PATH and hands each regular file to each rule. It
//! reports a `.zig` file that does not parse under the pseudo-rule `parse`. It prints one line for
//! each finding, in the shape of a compile error of Zig:
//!
//!     path:line:column: error: [rule-name] message
//!
//! Exit status: 0 for no finding, 1 for a finding or for a file that it cannot read, and 2 for a
//! usage error.
//!
//! This program is a developer tool. The build links no part of it into the package. So it
//! allocates and reads the filesystem, and the rules that it applies to `src/` do not bind it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");

/// Each rule, in the order in which `--rule` looks a name up. Each exports a `name` and a
/// `check(context, file)`.
const rules = .{
    @import("heap.zig"),
    @import("determinism.zig"),
    @import("unbounded_loop.zig"),
    @import("relative_import.zig"),
    @import("markdown.zig"),
    @import("file_length.zig"),
    @import("magic_numbers.zig"),
    @import("defer_order.zig"),
    @import("unreleased_acquire.zig"),
    @import("static_alignment.zig"),
    @import("global_state.zig"),
    @import("undefined_fill.zig"),
    @import("switch_form.zig"),
};

const Linter = pepegrillo.lint.Linter(rules);

pub fn main(init: std.process.Init) !void {
    return Linter.main(init);
}

// Tests. Each rule carries its own, and pepegrillo tests the driver.

const testing = std.testing;

test "the driver holds each rule that CLAUDE.md names, in order" {
    const expected = [_][]const u8{
        "heap",
        "determinism",
        "unbounded-loop",
        "relative-import",
        "markdown",
        "file-length",
        "magic-numbers",
        "defer-order",
        "unreleased-acquire",
        "static-alignment",
        "global-state",
        "undefined-fill",
        "switch-form",
    };
    try testing.expectEqual(expected.len, Linter.count);
    inline for (rules, 0..) |rule, index| {
        try testing.expectEqualStrings(expected[index], rule.name);
        try testing.expectEqual(index, Linter.rule_index_of(rule.name).?);
    }
}

test {
    inline for (rules) |rule| _ = rule;
}
