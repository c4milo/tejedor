//! The programs that measure the package, under `bench/`. `build.zig` stays short, so this file
//! holds that part of the build.
//!
//! The steps of this file:
//!
//! - `zig build bench-switch`: builds the probe of the context switch for the host, and runs it.
//!   The arguments after `--` go to the probe.
//! - `zig build bench-linux`: builds the same probe for Linux on aarch64 and on x86-64, and
//!   installs both under zig-out/linux-bench/. It runs neither: tools/linux_bench.sh runs one in
//!   Docker. The step touches a stamp file last, and that script refuses an install that is older
//!   than a source, as tools/linux_test.sh does (build/linux.zig).
//! - `zig build test-bench`: the unit tests of the bench programs, in Debug and in ReleaseSafe.
//! - `zig build bench-timers`: builds the timer program, `bench/std_io_timers.zig`, for the host,
//!   and runs it. The arguments after `--` go to the program. It is rotor's program of the timer
//!   workload, with a branch for the package (rotor's decision 34, "The timer program").
//!
//! A probe always builds in ReleaseSafe, the mode of a release build, whatever `-Drelease` says.
//! The package gives no number for a Debug build.
//!
//! `zig build test` runs the unit tests of the bench programs, and compiles the probe for the
//! host and for both Linux targets. So a probe that no longer compiles fails the local gate.
//!
//! The probe takes the context switch as the module `switch`, which this file makes from
//! `src/switch.zig`. The module `tejedor` exports no name for the switch, and only the build of
//! the package itself makes this second module.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("linux.zig");

/// The probe of the context switch.
const switch_probe_source = "bench/switch_probe.zig";

/// The timer program, which takes the modules `tejedor` and `rotor`.
const timers_source = "bench/std_io_timers.zig";

/// A module that the timer program imports, for a target and a mode.
pub const ModuleFn = *const fn (
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module;

/// The file of the package that the probe measures.
const switch_source = "src/switch.zig";

/// The name of the installed probe. The Linux builds add the processor to it.
const switch_probe_name = "switch_probe";

/// The directory that `bench-linux` fills and tools/linux_bench.sh reads, under the install
/// prefix.
const linux_install_directory = "linux-bench";

/// The file that `bench-linux` touches last. Its time is the time at which that install finished.
const linux_stamp_name = ".bench-linux-stamp";

/// The mode of each probe.
const probe_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

/// The processors that `bench-linux` builds the probe for.
const linux_processors = [_]std.Target.Cpu.Arch{ .aarch64, .x86_64 };

pub const Options = struct {
    /// The target of `zig build`, which is the host unless `-Dtarget` names another.
    target: std.Build.ResolvedTarget,
    /// `zig build test`.
    test_step: *std.Build.Step,
    /// Each mode that `zig build test` runs the unit tests in.
    modes: []const linux.Mode,
    /// The module `tejedor`, with its import of rotor, for the timer program.
    tejedor: ModuleFn,
    /// rotor's public module, for the timer program.
    rotor: ModuleFn,
};

/// Adds each step of this file.
pub fn add(b: *std.Build, options: Options) void {
    assert(options.modes.len > 0);

    const probe = add_probe(b, options.target, switch_probe_name);
    const run = b.addRunArtifact(probe);
    if (b.args) |arguments| run.addArgs(arguments);
    const run_step = b.step(
        "bench-switch",
        "Build the probe of the context switch in ReleaseSafe, and run it",
    );
    run_step.dependOn(&run.step);
    options.test_step.dependOn(&probe.step);

    const stamp = b.addSystemCommand(&.{"touch"});
    stamp.addArg(b.pathJoin(&.{ b.install_path, linux_install_directory, linux_stamp_name }));
    // The stamp is the time at which this install finished, so each run writes it again.
    stamp.has_side_effects = true;
    for (linux_processors) |arch| {
        const name = b.fmt("{s}-{s}", .{ switch_probe_name, @tagName(arch) });
        const linux_probe = add_probe(b, linux.linux_target(b, arch), name);
        options.test_step.dependOn(&linux_probe.step);
        const install = b.addInstallArtifact(linux_probe, .{
            .dest_dir = .{ .override = .{ .custom = linux_install_directory } },
        });
        stamp.step.dependOn(&install.step);
    }
    const linux_step = b.step(
        "bench-linux",
        "Build the probe of the context switch for Linux, for tools/linux_bench.sh",
    );
    linux_step.dependOn(&stamp.step);

    const tests_step = b.step(
        "test-bench",
        "Run the unit tests of the bench programs in Debug and in ReleaseSafe",
    );
    for (options.modes) |mode| {
        const tests = b.addTest(.{
            .name = b.fmt("bench-{s}", .{mode.name}),
            .root_module = probe_module(b, options.target, mode.optimize),
        });
        const run_tests = &b.addRunArtifact(tests).step;
        tests_step.dependOn(run_tests);
        options.test_step.dependOn(run_tests);
        const timers_tests = b.addTest(.{
            .name = b.fmt("bench-timers-{s}", .{mode.name}),
            .root_module = timers_module(b, options, mode.optimize),
        });
        const run_timers_tests = &b.addRunArtifact(timers_tests).step;
        tests_step.dependOn(run_timers_tests);
        options.test_step.dependOn(run_timers_tests);
    }
    add_timers(b, options);
}

/// `zig build bench-timers`: the timer program in ReleaseSafe, for the host.
fn add_timers(b: *std.Build, options: Options) void {
    const program = b.addExecutable(.{
        .name = "std_io_timers",
        .root_module = timers_module(b, options, probe_optimize),
    });
    options.test_step.dependOn(&program.step);
    const run = b.addRunArtifact(program);
    if (b.args) |arguments| run.addArgs(arguments);
    const step = b.step("bench-timers", "Build the timer program in ReleaseSafe, and run it");
    step.dependOn(&run.step);
}

fn timers_module(b: *std.Build, options: Options, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(timers_source),
        .target = options.target,
        .optimize = optimize,
    });
    module.addImport("tejedor", options.tejedor(b, options.target, optimize));
    module.addImport("rotor", options.rotor(b, options.target, optimize));
    return module;
}

/// The probe as an executable for `target`, in the mode of each probe.
fn add_probe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = probe_module(b, target, probe_optimize),
    });
}

/// The root module of the probe, with the context switch of the package as its import `switch`.
/// `build/linux.zig` builds the unit tests of the bench programs for Linux from it too.
pub fn probe_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    assert(optimize == .Debug or optimize == .ReleaseSafe);
    const module = b.createModule(.{
        .root_source_file = b.path(switch_probe_source),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("switch", b.createModule(.{
        .root_source_file = b.path(switch_source),
        .target = target,
        .optimize = optimize,
    }));
    return module;
}
