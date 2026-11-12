//! The developer tools of tejedor, built on pepegrillo: the lint, the tests of the tools, the
//! commit linter, the hook check and the hooks step. `build.zig` stays short, so this file holds
//! that part of the build.
//!
//! pepegrillo is a lazy package of `build.zig.zon`. Only `add` asks for it, and `build.zig` calls
//! `add` only when tejedor is the root of the build. So a project that depends on tejedor never
//! fetches pepegrillo.
//!
//! The steps of this file:
//!
//! - `zig build lint`: the complexity score, then the rules of tools/lint (build/lint.zig);
//! - `zig build test-tools`: the tests of the tools alone, the target for a mutation of the
//!   configuration of a rule;
//! - `zig build hook-check`: `.githooks/pre-push` must match the hook of the pinned pepegrillo;
//! - `zig build lint-commits`: the commit messages that this branch adds to `origin/main`;
//! - `zig build install-commit-lint`: installs the commit linter alone, for the hook;
//! - `zig build hooks`: points `core.hooksPath` of this clone at `.githooks`.
//!
//! `zig build test` runs the first three, and the format check of `build/` and `tools/`. It does
//! not run `lint-commits` or `hooks`: the shape of a commit message is a property of the history,
//! and not of the code.
const std = @import("std");
const lint = @import("lint.zig");

/// Each directory that the complexity score reads, beside `build.zig`. A commit that adds a
/// directory of Zig sources adds it here.
const source_directories = [_][]const u8{ "build", "src", "tools" };

/// Each directory that the rules of tools/lint read: the sources, and the documents, which the
/// markdown rule reads.
const rule_directories = [_][]const u8{ "build", "src", "tools", "docs" };

/// The files at the top of the tree that the rules of tools/lint read.
const rule_files = [_][]const u8{ "build.zig", "CLAUDE.md", "README.md" };

/// The directories whose format this file checks. `build.zig` checks the rest of the tree.
const format_paths = [_][]const u8{ "build", "tools" };

/// Each tool whose own tests `zig build test` runs. Without them, a rule can lose the test of its
/// configuration and the build does not report it.
const tool_test_roots = [_][]const u8{
    "tools/lint/main.zig",
    "tools/cognitive_complexity.zig",
    "tools/commit_lint.zig",
};

/// The git revision range that `zig build lint-commits` checks.
const commit_lint_range = "origin/main..HEAD";

/// The directory that `zig build hooks` points `core.hooksPath` of this clone at.
const hooks_directory = ".githooks";

/// The pre-push hook: a copy of pepegrillo's, which `zig build test` compares byte for byte.
const pre_push_hook = hooks_directory ++ "/pre-push";

pub const Options = struct {
    /// `zig build test`.
    test_step: *std.Build.Step,
    /// `zig build`, which installs the commit linter for the pre-push hook.
    install_step: *std.Build.Step,
};

/// Adds each step of this file. Call it only when tejedor is the root of the build.
pub fn add(b: *std.Build, options: Options) void {
    std.debug.assert(b.pkg_hash.len == 0);
    if (b.lazyDependency("pepegrillo", .{})) |dependency| {
        add_pepegrillo_steps(b, dependency, options);
    }
    const format_check = b.addFmt(.{ .paths = &format_paths, .check = true });
    options.test_step.dependOn(&format_check.step);
}

/// The step that formats `build/` and `tools/`, for `zig build fmt`.
pub fn format(b: *std.Build) *std.Build.Step {
    return &b.addFmt(.{ .paths = &format_paths }).step;
}

fn add_pepegrillo_steps(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    options: Options,
) void {
    const pepegrillo = dependency.module("pepegrillo");

    // The lint is the first check of `zig build test`.
    options.test_step.dependOn(lint.add(b, .{
        .source_directories = &source_directories,
        .rule_directories = &rule_directories,
        .rule_files = &rule_files,
        .complexity = b.addExecutable(.{
            .name = "cognitive_complexity",
            .root_module = tool_module(b, pepegrillo, "tools/cognitive_complexity.zig"),
        }),
        .rules = b.addExecutable(.{
            .name = "lint",
            .root_module = tool_module(b, pepegrillo, "tools/lint/main.zig"),
        }),
    }));

    const tool_test_step = b.step("test-tools", "Run the tests of the tools alone");
    for (tool_test_roots) |root| {
        const tool_tests = b.addTest(.{
            .name = std.fs.path.stem(root),
            .root_module = tool_module(b, pepegrillo, root),
        });
        const run = &b.addRunArtifact(tool_tests).step;
        options.test_step.dependOn(run);
        tool_test_step.dependOn(run);
    }

    options.test_step.dependOn(add_hook_check_step(b, dependency));
    add_commit_lint_step(b, pepegrillo, options.install_step);
    add_hooks_step(b);
}

/// A module for the host that imports `pepegrillo`, in Debug. A tool checks the tree and is not
/// part of the package, so it needs no other target and no other mode.
fn tool_module(
    b: *std.Build,
    pepegrillo: *std.Build.Module,
    root_source_file: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    module.addImport("pepegrillo", pepegrillo);
    return module;
}

/// `zig build hook-check`: `.githooks/pre-push` must be byte-identical to the hook of the pinned
/// pepegrillo. After a pepegrillo bump, copy the new hook over it.
fn add_hook_check_step(b: *std.Build, pepegrillo: *std.Build.Dependency) *std.Build.Step {
    const compare = b.addSystemCommand(&.{"cmp"});
    compare.addFileArg(pepegrillo.path("hooks/pre-push"));
    compare.addFileArg(b.path(pre_push_hook));
    const step = b.step(
        "hook-check",
        "Require " ++ pre_push_hook ++ " to match pepegrillo's hooks/pre-push; copy it when not",
    );
    step.dependOn(&compare.step);
    return step;
}

/// `zig build lint-commits`: the Conventional Commit rules of CLAUDE.md over the commits that
/// this branch adds. `zig build install-commit-lint` installs the linter alone, which
/// `.githooks/pre-push` runs when `zig-out/bin/commit_lint` is missing.
fn add_commit_lint_step(
    b: *std.Build,
    pepegrillo: *std.Build.Module,
    install_step: *std.Build.Step,
) void {
    const tool = b.addExecutable(.{
        .name = "commit_lint",
        .root_module = tool_module(b, pepegrillo, "tools/commit_lint.zig"),
    });
    const install_tool = b.addInstallArtifact(tool, .{});
    install_step.dependOn(&install_tool.step);
    const install_tool_step = b.step(
        "install-commit-lint",
        "Install the commit-message linter alone",
    );
    install_tool_step.dependOn(&install_tool.step);
    const run = b.addRunArtifact(tool);
    run.addArgs(&.{ "--range", commit_lint_range });
    const step = b.step("lint-commits", "Check the commit messages that this branch adds");
    step.dependOn(&run.step);
}

/// `zig build hooks`: one `git config` call, in this clone alone.
fn add_hooks_step(b: *std.Build) void {
    const run = b.addSystemCommand(&.{ "git", "config", "core.hooksPath", hooks_directory });
    const step = b.step("hooks", "Point core.hooksPath of this clone at " ++ hooks_directory);
    step.dependOn(&run.step);
}
