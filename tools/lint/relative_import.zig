//! relative-import: a file under `src/` imports no file outside `src/` by a path. tejedor is one
//! module, with the root `src/tejedor.zig`. The build gives that module rotor by name. An
//! `@import` that leaves `src/` by a path takes a file that the build did not give the module.
//!
//! Over each `.zig` file under `src/`, the rule resolves the path of each `@import` against the
//! directory of the file. It flags a path that names a file outside `src/`, and each absolute
//! path. A file beside the importer, a file in a subdirectory, and a file of `src/` reached from a
//! subdirectory are no finding. A module name, such as `rotor`, is no finding.
//!
//! The rule is pepegrillo's `relative_import`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const relative_import = lint.rules.relative_import;

const message_suffix =
    " leaves src/ by a path; import a module by the name that build.zig gives it";

pub const config: relative_import.Config = .{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .mode = .leaves_subsystem,
    // The top of the tree. Each of its children is one subsystem, so the whole of `src/` is the
    // subsystem of each file under it. With pepegrillo's default, `src`, a file directly under
    // `src/` has no subsystem, and each file that it imports is a finding.
    .source_root = ".",
    .message = "@import(\"{[path]s}\")" ++ message_suffix,
};

const Rule = relative_import.Rule(config);
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

test "relative-import passes a module name and a file beside the root file" {
    try expect_findings("src/tejedor.zig",
        \\const std = @import("std");
        \\const rotor = @import("rotor");
        \\const zig_version = @import("zig_version.zig");
        \\const piece = @import("pieces/piece.zig");
    , &.{});
}

test "relative-import passes a file of src/ reached from a subdirectory" {
    try expect_findings("src/pieces/piece.zig",
        \\const constants = @import("../constants.zig");
        \\const other = @import("other.zig");
    , &.{});
}

test "relative-import flags a path out of src/ and an absolute path" {
    try expect_findings("src/tejedor.zig",
        \\const tools = @import("../build/tools.zig");
        \\const pinned = @import("/Users/someone/tejedor/src/zig_version.zig");
    , &.{
        "@import(\"../build/tools.zig\")" ++ message_suffix,
        "@import(\"/Users/someone/tejedor/src/zig_version.zig\")" ++ message_suffix,
    });
    try expect_findings("src/pieces/piece.zig",
        \\const probe = @import("../../bench/probe.zig");
    , &.{
        "@import(\"../../bench/probe.zig\")" ++ message_suffix,
    });
}

test "relative-import reads src/ alone" {
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    // `build.zig` imports `src/zig_version.zig` by its path. The rule does not read it.
    try testing.expect(!config.scope.applies("build.zig"));
    try testing.expect(!config.scope.applies("build/tools.zig"));
    try testing.expect(!config.scope.applies("tools/lint/main.zig"));
}
