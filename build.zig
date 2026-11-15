//! Build graph for tejedor: one module, `tejedor`, with the root `src/tejedor.zig`. It imports
//! rotor at the tag that `build.zig.zon` pins.
//!
//! `zig build` compiles the unit tests. `zig build test` runs them twice, in Debug and in
//! ReleaseSafe, because the faults of the context switch showed only in an optimized build
//! (rotor's decision 34, "Upkeep"). It also checks the format of each Zig source, but the
//! attachments of `docs/zig-report/`. `zig build test-debug` and `zig build test-release` each run
//! one mode alone, which is what a mutation is measured against. `zig build fmt` formats each Zig
//! source that the test checks.
//!
//! Assertions stay on in a release build. So the build offers Debug and ReleaseSafe alone:
//! `-Drelease` selects ReleaseSafe, and no option admits ReleaseFast or ReleaseSmall.
//!
//! `zig build test-compile-fail` builds each program of tools/compile_fail, and none may compile.
//! One hands the check of the Zig version another version. Two ask for a form of the context
//! switch that the package does not use on their architecture (build/switch_checks.zig). `zig
//! build test` runs them.
//!
//! `zig build lint` scores the cognitive complexity of each function, and runs the rules of
//! tools/lint over the tree. `zig build test` runs the lint too. The tools are built on
//! pepegrillo, a lazy package of `build.zig.zon` that only the root build asks for. So a project
//! that depends on tejedor never fetches it. `build/tools.zig` holds that part of the build.
//!
//! `zig build test-linux` builds the unit tests of the package and of the bench programs for Linux
//! on aarch64 and on x86-64, in both modes, under zig-out/linux/. It runs none of them:
//! tools/linux_test.sh runs them in Docker.
//! `zig build test` compiles them too, and installs none (build/linux.zig).
//!
//! `zig build bench-switch` builds the probe of the context switch in ReleaseSafe, and runs it.
//! `zig build test` runs the unit tests of the bench programs (build/bench.zig).
const std = @import("std");
const assert = std.debug.assert;
const bench = @import("build/bench.zig");
const halt = @import("build/halt.zig");
const linux = @import("build/linux.zig");
const switch_checks = @import("build/switch_checks.zig");
const tools = @import("build/tools.zig");

const zig_version = @import("src/zig_version.zig");

comptime {
    // A build with another Zig version stops here, with the reason. A build file that the other
    // Zig cannot parse stops the build before this line (src/zig_version.zig).
    _ = zig_version;
}

/// The program that must not compile, and the module that it imports.
const compile_fail_source = "tools/compile_fail/zig_version_other.zig";
const zig_version_source = "src/zig_version.zig";

/// The program that hands `Fibers` a type that lacks two declarations.
const fibers_compile_fail_source = "tools/compile_fail/fibers_without_tick.zig";

/// The root file of the module `tejedor`.
const root_source_file = "src/tejedor.zig";

/// What `zig build fmt` formats, and what `zig build test` checks the format of.
const format_paths = [_][]const u8{ "build.zig", "build.zig.zon", "src", "bench" };

/// `zig build test` runs the unit tests once for each entry: the mode, and the word that names
/// its own step, `test-<name>`.
const test_modes = [_]linux.Mode{
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
    // The lint and the other developer tools, built on pepegrillo (build/tools.zig).
    tools.add(b, .{ .test_step = test_step, .install_step = install_step });
    for (test_modes) |mode| {
        const unit_tests = b.addTest(.{
            .name = b.fmt("tejedor-{s}", .{mode.name}),
            .root_module = test_module(b, target, mode.optimize),
        });
        if (mode.optimize == optimize) install_step.dependOn(&unit_tests.step);
        const run_step = &b.addRunArtifact(unit_tests).step;
        test_step.dependOn(run_step);
        const narrow_step = b.step(
            b.fmt("test-{s}", .{mode.name}),
            b.fmt("Run the unit tests in {s} alone", .{@tagName(mode.optimize)}),
        );
        narrow_step.dependOn(run_step);
    }
    // The same tests for Linux, and those of the bench programs, which tools/linux_test.sh runs in
    // Docker.
    const linux_steps = linux.add(b, .{ .modes = &test_modes, .suites = &.{
        .{ .name = "tejedor", .module = test_module },
        .{ .name = "bench", .module = bench.probe_module },
    }, .rotor = .{ .name = "rotor", .module = rotor_module } });
    test_step.dependOn(linux_steps.compile);
    // The halt scenarios, on the host and for the Linux gate (build/halt.zig).
    const halt_options: halt.Options = .{ .modes = &test_modes, .tejedor = test_module, .rotor = rotor_module };
    test_step.dependOn(halt.add(b, target, halt_options));
    halt.add_linux(b, halt_options, .{ .compile_step = linux_steps.compile, .stamp_step = linux_steps.stamp });
    // The programs that measure the package.
    bench.add(b, .{
        .target = target,
        .test_step = test_step,
        .modes = &test_modes,
        .tejedor = test_module,
        .rotor = rotor_module,
    });

    // The check of the Zig version must stop a compile, with its message. So must a call of the
    // context switch in a form that the package does not use on its architecture.
    const compile_fail = compile_fail_step(b, target);
    switch_checks.add(b, .{ .compile_fail_step = compile_fail, .test_step = test_step });
    test_step.dependOn(compile_fail);

    const fmt_step = b.step("fmt", "Format each Zig source");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &format_paths }).step);
    test_step.dependOn(&b.addFmt(.{ .paths = &format_paths, .check = true }).step);
    fmt_step.dependOn(tools.format(b));
}

/// The root module of the unit tests for `target` in `optimize`, with rotor as its import.
fn test_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("rotor", rotor_module(b, target, optimize));
    return module;
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
        "Require each program of tools/compile_fail to stop its compile with its message",
    );
    step.dependOn(&compile.step);
    step.dependOn(fibers_compile_fail(b, target));
    return step;
}

/// The program of `tools/compile_fail/fibers_without_tick.zig` hands `Fibers` a type that lacks
/// `tick` and `shared`. Its compile must fail, and the message must name both (rotor's decision
/// 34, step 1).
fn fibers_compile_fail(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path(fibers_compile_fail_source),
        .target = target,
        .optimize = .Debug,
    });
    module.addImport("tejedor", test_module(b, target, .Debug));
    const compile = b.addTest(.{ .name = "fibers_without_tick", .root_module = module });
    // Each line of the errors ends with the line of the same place here.
    compile.expect_errors = .{ .exact = &.{
        "error: tejedor.Fibers(fibers_without_tick.NoTick): " ++
            "the type lacks 2 declarations that the package needs:",
        "tick: the tick, which only the package calls while the value lives",
        "shared: the view, for a cross-core call",
        "A program passes rotor.Reactor(rotor.Loop), and a test can pass " ++
            "rotor.Reactor(Twin) for a twin (rotor's decision 34, \"Over a twin\").",
        "note: called at comptime here",
        "note: called at comptime here",
    } };
    return &compile.step;
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
