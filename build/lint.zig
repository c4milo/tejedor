//! `zig build lint`: the cognitive complexity score, then the rules of tools/lint over the tree,
//! then the same rules over a canary tree.
//!
//! The rules run with no `--rule` argument, so each rule of tools/lint/main.zig checks the build.
//! A clean tree cannot show that. A run that lost a rule passes a tree that the rule would pass
//! too. The canary tree shows it. The build writes that tree into its cache, with one violation
//! of each rule. The lint must exit 1 over it, and print each rule of `canary_rules` on stdout.
//!
//! The complexity score has a canary of its own: a function that scores one over the limit, which
//! the scorer must refuse.
const std = @import("std");

/// The cognitive complexity limit of CLAUDE.md (Conventions). Never raise it: split the function.
const cognitive_complexity_max = "15";

/// What the scorer prints for `canary_complex_source`: its score, one over the limit.
const canary_complex_report = "scored 16 (max 15)";

/// Each rule that the canary run must report: each rule of tools/lint/main.zig.
const canary_rules = [_][]const u8{
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
};

/// The most lines that a source file may hold (tools/lint/file_length.zig).
const file_length_lines_max = 500;

/// One violation of each Zig rule that reads `src/`, then enough comment lines to pass the limit
/// of file-length.
const canary_source =
    \\const std = @import("std");
    \\const other = @import("/canary/other.zig");
    \\var canary_allocator: std.mem.Allocator = undefined;
    \\var shared: u32 = 0;
    \\pub fn canary(allocator: std.mem.Allocator) !void {
    \\    _ = allocator;
    \\    _ = std.time;
    \\    while (true) {}
    \\    var buffer: [4096]u8 = undefined;
    \\    _ = &buffer;
    \\    try connect_all(&client);
    \\    defer close_all();
    \\}
    \\
++ "//\n" ** file_length_lines_max;

/// One violation of `unreleased-acquire`, and of no other rule. That rule reads `bench/` alone
/// (tools/lint/unreleased_acquire.zig), so the canary of `src/` cannot hold it.
const canary_bench_source =
    \\pub fn canary() !void {
    \\    const socket = try open_socket(.ipv4);
    \\    try connect_now(socket);
    \\}
    \\
;

/// A function that scores one over `cognitive_complexity_max`. Five nested `if`s score
/// 1 + 2 + 3 + 4 + 5, and the sixth `if` scores 1. The complexity run over it must exit 1. So a
/// limit that is one higher fails the build.
const canary_complex_source =
    \\pub fn canary(a: bool, b: bool, c: bool, d: bool, e: bool, f: bool) u32 {
    \\    if (a) {
    \\        if (b) {
    \\            if (c) {
    \\                if (d) {
    \\                    if (e) return 5;
    \\                }
    \\            }
    \\        }
    \\    }
    \\    if (f) return 1;
    \\    return 0;
    \\}
    \\
;

/// A fence with no language, which the markdown rule refuses.
const canary_markdown =
    \\# canary
    \\
    \\```
    \\code
    \\```
    \\
;

pub const Options = struct {
    /// Each directory that the complexity score reads, beside `build.zig`.
    source_directories: []const []const u8,
    /// Each directory that the rules of tools/lint read.
    rule_directories: []const []const u8,
    /// Each single file that the rules of tools/lint read beside those directories.
    rule_files: []const []const u8,
    /// The complexity tool, built on pepegrillo.
    complexity: *std.Build.Step.Compile,
    /// The driver of tools/lint, built on pepegrillo.
    rules: *std.Build.Step.Compile,
};

/// Adds the step `lint` and returns it.
pub fn add(b: *std.Build, options: Options) *std.Build.Step {
    const complexity_run = b.addRunArtifact(options.complexity);
    complexity_run.addArgs(&.{ "--max", cognitive_complexity_max });
    complexity_run.addFileArg(b.path("build.zig"));
    for (options.source_directories) |directory| {
        complexity_run.addDirectoryArg(b.path(directory));
    }

    const complexity_canary = b.addWriteFiles();
    const complexity_canary_run = b.addRunArtifact(options.complexity);
    complexity_canary_run.addArgs(&.{ "--max", cognitive_complexity_max });
    complexity_canary_run.addFileArg(complexity_canary.add("canary.zig", canary_complex_source));
    complexity_canary_run.expectExitCode(1);
    complexity_canary_run.addCheck(.{ .expect_stdout_match = canary_complex_report });
    complexity_canary_run.step.dependOn(&complexity_run.step);

    const tree_run = b.addRunArtifact(options.rules);
    for (options.rule_directories) |directory| tree_run.addDirectoryArg(b.path(directory));
    for (options.rule_files) |file| tree_run.addFileArg(b.path(file));
    tree_run.step.dependOn(&complexity_canary_run.step);

    const canary_run = b.addRunArtifact(options.rules);
    canary_run.addDirectoryArg(add_canary_tree(b));
    canary_run.expectExitCode(1);
    for (canary_rules) |rule| {
        canary_run.addCheck(.{ .expect_stdout_match = b.fmt("[{s}]", .{rule}) });
    }
    canary_run.step.dependOn(&tree_run.step);

    const lint_step = b.step(
        "lint",
        "Score the cognitive complexity, then run the rules of tools/lint",
    );
    lint_step.dependOn(&canary_run.step);
    return lint_step;
}

/// The canary tree: one file for each directory that a rule reads.
fn add_canary_tree(b: *std.Build) std.Build.LazyPath {
    const tree = b.addWriteFiles();
    _ = tree.add("src/canary.zig", canary_source);
    _ = tree.add("bench/canary.zig", canary_bench_source);
    _ = tree.add("docs/canary.md", canary_markdown);
    return tree.getDirectory();
}
