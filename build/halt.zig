//! `zig build halt-check`: proves that each assertion that a mistake of the caller can reach halts
//! (rotor's decision 34, "Upkeep"). Each executable of scenarios under tools/halt/ breaks a rule
//! on purpose, and tools/halt_check.zig runs each scenario in a child process that must die by a
//! signal, with the text that the scenario names. `zig build test` runs the step. `build.zig`
//! stays short, so this file holds that part of the build.
//!
//! Each executable of scenarios is built in each mode of the unit tests, Debug and ReleaseSafe,
//! because an assertion must halt in both. The check is a tool, and it compiles in Debug.
//!
//! The canary proves the check itself: its scenarios do not halt as a scenario must, and the check
//! must report each of them.
//!
//! `add_linux` builds the check and the scenarios for Linux, for the Linux gate. It installs them
//! under zig-out/linux/, and writes `halt.manifest` there. Each line of that file names the
//! platform, the check, the executable of scenarios, and the count of failures that the check
//! must report. tools/linux_test.sh runs each line.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("linux.zig");

/// The root file of the check.
const check_source = "tools/halt_check.zig";

/// The file of the package that the switch scenarios take as their module `switch`.
const switch_source = "src/switch.zig";

/// The directory that the Linux gate reads, under the install prefix. build/linux.zig fills it.
const install_directory = "linux";

/// The file that lists the runs of the check for the Linux gate.
const manifest_name = "halt.manifest";

/// A module that the scenarios import, for a target and a mode.
pub const ModuleFn = *const fn (
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module;

/// One executable of scenarios, and the count of failures that the check must report for it.
const Scenarios = struct {
    name: []const u8,
    /// 0 for a real check, and the count of its scenarios for the canary.
    expected_failures: u32,
    imports: Imports,
};

/// The modules that an executable of scenarios imports.
const Imports = enum { fibers, switching, none };

const scenario_files = [_]Scenarios{
    .{ .name = "fibers_scenarios", .expected_failures = 0, .imports = .fibers },
    .{ .name = "switch_scenarios", .expected_failures = 0, .imports = .switching },
    .{ .name = "canary_scenarios", .expected_failures = 3, .imports = .none },
};

pub const Options = struct {
    /// Each mode that `zig build test` runs the unit tests in.
    modes: []const linux.Mode,
    /// The module `tejedor`, with its import of rotor.
    tejedor: ModuleFn,
    /// rotor's public module.
    rotor: ModuleFn,
};

/// Adds the step `halt-check` for `target`, and returns it.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, options: Options) *std.Build.Step {
    const check = check_executable(b, b.graph.host, "halt_check");
    const step = b.step(
        "halt-check",
        "Require each halt scenario to die by a signal, with its text, in Debug and in ReleaseSafe",
    );
    for (options.modes) |mode| {
        for (scenario_files) |file| {
            const name = b.fmt("{s}-{s}", .{ file.name, mode.name });
            const executable = scenarios(b, file, target, mode, options, name);
            const run = b.addRunArtifact(check);
            run.addArtifactArg(executable);
            if (file.expected_failures != 0) {
                run.addArgs(&.{ "--expect-failures", b.fmt("{d}", .{file.expected_failures}) });
            }
            // The run is a check of its own, and not a step with side effects. So Zig caches it
            // on the content of both executables, and runs it beside the others.
            run.expectExitCode(0);
            step.dependOn(&run.step);
        }
    }
    return step;
}

/// What `add_linux` joins: the compile step of `zig build test`, and the stamp of the install.
pub const Joins = struct {
    compile_step: *std.Build.Step,
    stamp_step: *std.Build.Step,
};

/// Builds the check and each executable of scenarios for Linux on each processor of the gate, in
/// each mode. It installs them under zig-out/linux/, beside the unit tests, and writes the
/// manifest of the runs.
pub fn add_linux(b: *std.Build, options: Options, joins: Joins) void {
    var manifest: []const u8 = "";
    for (linux.processors) |processor| {
        const target = linux.linux_target(b, processor.arch);
        const check_name = b.fmt("halt_check-{s}", .{@tagName(processor.arch)});
        const check = check_executable(b, target, check_name);
        install(b, check, joins);
        for (options.modes) |mode| {
            for (scenario_files) |file| {
                const name = b.fmt("{s}-{s}-{s}", .{ file.name, @tagName(processor.arch), mode.name });
                install(b, scenarios(b, file, target, mode, options, name), joins);
                manifest = b.fmt("{s}{s} {s} {s} {d}\n", .{
                    manifest,
                    processor.docker_platform,
                    check_name,
                    name,
                    file.expected_failures,
                });
            }
        }
    }
    assert(manifest.len > 0);
    const manifest_file = b.addWriteFiles().add(manifest_name, manifest);
    const install_manifest = b.addInstallFileWithDir(
        manifest_file,
        .{ .custom = install_directory },
        manifest_name,
    );
    joins.stamp_step.dependOn(&install_manifest.step);
}

fn install(b: *std.Build, executable: *std.Build.Step.Compile, joins: Joins) void {
    joins.compile_step.dependOn(&executable.step);
    const step = b.addInstallArtifact(executable, .{
        .dest_dir = .{ .override = .{ .custom = install_directory } },
    });
    joins.stamp_step.dependOn(&step.step);
}

/// The check is a tool, and a tool never ships, so it compiles in Debug.
fn check_executable(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(check_source),
            .target = target,
            .optimize = .Debug,
        }),
    });
}

/// One executable of scenarios, for `target` in the mode of `mode`, with the name `name`.
fn scenarios(
    b: *std.Build,
    file: Scenarios,
    target: std.Build.ResolvedTarget,
    mode: linux.Mode,
    options: Options,
    name: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/halt/{s}.zig", .{file.name})),
        .target = target,
        .optimize = mode.optimize,
    });
    switch (file.imports) {
        .fibers => {
            module.addImport("tejedor", options.tejedor(b, target, mode.optimize));
            module.addImport("rotor", options.rotor(b, target, mode.optimize));
        },
        .switching => module.addImport("switch", b.createModule(.{
            .root_source_file = b.path(switch_source),
            .target = target,
            .optimize = mode.optimize,
        })),
        .none => {},
    }
    return b.addExecutable(.{ .name = name, .root_module = module });
}
