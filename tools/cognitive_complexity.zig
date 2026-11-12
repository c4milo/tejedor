//! The cognitive complexity check of tejedor. CLAUDE.md holds the rule: a function stays at
//! cognitive complexity 15 or less, and a `test` block has the same limit.
//!
//! Run: `zig build lint`. It passes `--max 15`, then `build.zig` and each source directory.
//!
//! The scorer is pepegrillo's: SonarSource Cognitive Complexity, mapped onto Zig. It scores each
//! function and each `test` block. It prints one line for each declaration over the limit, in the
//! shape of a compile error of Zig:
//!
//!     path:line:column: error: [cognitive-complexity] name scored SCORE (max N)
//!
//! It prints one summary line when no declaration is over the limit. The limit and the paths come
//! from the build, so this entry point configures nothing.

const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.complexity.main(init);
}
