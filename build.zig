//! Build graph for tejedor: one module, `tejedor`, with the root `src/tejedor.zig`. It imports
//! rotor at the tag that `build.zig.zon` pins.
//!
//! `zig build` compiles the unit tests. `zig build test` runs them twice, in Debug and in
//! ReleaseSafe, because the faults of the context switch showed only in an optimized build
//! (rotor's decision 34, "Upkeep"). It also checks the format of each Zig source.
//! `zig build test-debug` and `zig build test-release` each run one mode alone, which is what a
//! mutation is measured against. `zig build fmt` formats each Zig source.
//!
//! Assertions stay on in a release build. So the build offers Debug and ReleaseSafe alone:
//! `-Drelease` selects ReleaseSafe, and no option admits ReleaseFast or ReleaseSmall.
//!
//! `zig build test-compile-fail` builds the one program of tools/compile_fail, which must not
//! compile: it hands the check of the Zig version another version. `zig build test` runs it.
const std = @import("std");
const assert = std.debug.assert;

const zig_version = @import("src/zig_version.zig");

comptime {
    // A build with another Zig version stops here, with the reason. A build file that the other
    // Zig cannot parse stops the build before this line (src/zig_version.zig).
    _ = zig_version;
}

/// The program that must not compile, and the module that it imports.
const compile_fail_source = "tools/compile_fail/zig_version_other.zig";
const zig_version_source = "src/zig_version.zig";

/// The root file of the module `tejedor`.
const root_source_file = "src/tejedor.zig";

/// What `zig build fmt` formats, and what `zig build test` checks the format of.
const format_paths = [_][]const u8{ "build.zig", "build.zig.zon", "src" };

/// One run of the unit tests: the mode, and the name of its own step, `test-<name>`.
const TestRun = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
};

/// `zig build test` runs the unit tests once for each entry.
const test_runs = [_]TestRun{
    .{ .name = "debug", .optimize = .Debug },
    .{ .name = "release", .optimize = .ReleaseSafe },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    assert(optimize == .Debug or optimize == .ReleaseSafe);

    // The module that a dependent package names.
    const tejedor = b.addModule("tejedor", .{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    tejedor.addImport("rotor", rotor_module(b, target, optimize));

    // Everything below is tejedor's own build: its tests and its checks. A project that depends
    // on tejedor stops here.
    if (b.pkg_hash.len != 0) return;

    const install_step = b.getInstallStep();
    const test_step = b.step(
        "test",
        "Run the unit tests in Debug and in ReleaseSafe, then check the format",
    );
    for (test_runs) |run| {
        const module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = run.optimize,
        });
        module.addImport("rotor", rotor_module(b, target, run.optimize));
        const unit_tests = b.addTest(.{
            .name = b.fmt("tejedor-{s}", .{run.name}),
            .root_module = module,
        });
        if (run.optimize == optimize) install_step.dependOn(&unit_tests.step);
        const run_step = &b.addRunArtifact(unit_tests).step;
        test_step.dependOn(run_step);
        const narrow_step = b.step(
            b.fmt("test-{s}", .{run.name}),
            b.fmt("Run the unit tests in {s} alone", .{@tagName(run.optimize)}),
        );
        narrow_step.dependOn(run_step);
    }

    // The check of the Zig version must stop a compile, with its message.
    test_step.dependOn(compile_fail_step(b, target));

    const fmt_step = b.step("fmt", "Format each Zig source");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &format_paths }).step);
    test_step.dependOn(&b.addFmt(.{ .paths = &format_paths, .check = true }).step);
}

/// `zig build test-compile-fail`. The program hands `zig_version.require` the pinned version with
/// the next patch number, so its compile must fail with the message of the check. A compile that
/// passes fails the step, and so does a compile that fails with another message. The build system
/// requires that an error line ends with the text below.
fn compile_fail_step(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path(compile_fail_source),
        .target = target,
        .optimize = .Debug,
    });
    module.addImport("zig_version", b.createModule(.{
        .root_source_file = b.path(zig_version_source),
        .target = target,
        .optimize = .Debug,
    }));
    const compile = b.addTest(.{ .name = "zig_version_other", .root_module = module });
    var other = zig_version.pinned;
    other.patch += 1;
    compile.expect_errors = .{ .contains = b.fmt(
        "error: tejedor builds with Zig {f} only, and this compiler is Zig {f}. " ++
            "The table of a std.Io, std.Io.VTable, differs between Zig versions, " ++
            "so each release of tejedor pins one Zig version. " ++
            "A Zig upgrade is a release of tejedor (rotor's decision 34, \"Upkeep\").",
        .{ zig_version.pinned, other },
    ) };
    const step = b.step(
        "test-compile-fail",
        "Require the check of the Zig version to stop a compile with its message",
    );
    step.dependOn(&compile.step);
    return step;
}

/// rotor's public module at the pinned tag, for `target`. rotor's build offers Debug and
/// ReleaseSafe alone, through its own `-Drelease`.
fn rotor_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    assert(optimize == .Debug or optimize == .ReleaseSafe);
    const rotor = b.dependency("rotor", .{ .target = target, .release = optimize != .Debug });
    return rotor.module("rotor");
}
