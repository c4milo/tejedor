//! `zig build test-linux`: builds the unit tests of the package for Linux, and installs them under
//! zig-out/linux/. It runs none of them: tools/linux_test.sh runs them in Docker. `build.zig`
//! stays short, so this file holds that part of the build.
//!
//! The step builds one test executable for each processor of `processors` and each mode of the
//! build: aarch64 and x86-64, in Debug and in ReleaseSafe. The check of step 0 of the build order
//! names both processors, and the faults of the context switch showed only in an optimized build
//! (rotor's decision 34, "Build order" and "Upkeep").
//!
//! The ABI is musl and nothing links libc, so each executable is static and takes nothing from
//! the image of its container. The CPU model is the baseline of the architecture, so an
//! executable that one machine built runs on each other machine of that architecture.
//!
//! The development machine is a Mac on aarch64. Docker runs the aarch64 executables on the
//! kernel of its virtual machine, and it runs the x86-64 executables under an emulator. A real
//! x86-64 processor runs the tests in CI, where `zig build test` runs on a Linux runner.
//!
//! The step writes two files beside the executables, and tools/linux_test.sh reads both:
//!
//! - `manifest_name` lists each executable that this build installed, one for each line, in the
//!   order in which they run. Each line holds the Docker platform and the name. The script runs
//!   what the manifest lists. So it never runs an executable that is there from an earlier
//!   build, and an executable that is listed and missing fails the run.
//! - `stamp_name` is touched last, after each install. The script compares each source with it,
//!   and refuses an install that is older than a source. An executable cannot serve as the stamp:
//!   an install that did not change keeps its old time.
//!
//! `zig build test` depends on the compile of these executables, and installs none of them. So a
//! change that does not compile or assemble for Linux fails the local gate on a Mac.
const std = @import("std");
const assert = std.debug.assert;

/// The directory that the step fills and tools/linux_test.sh reads, under the install prefix.
const install_directory = "linux";

/// The file that the step touches last. Its time is the time at which this install finished.
const stamp_name = ".test-linux-stamp";

/// The file that lists the installed test executables.
const manifest_name = "tests.manifest";

/// One processor that the Linux gate runs the tests on.
const Processor = struct {
    arch: std.Target.Cpu.Arch,
    /// The platform that `docker run --platform` takes for this processor.
    docker_platform: []const u8,
};

const processors = [_]Processor{
    .{ .arch = .aarch64, .docker_platform = "linux/arm64" },
    .{ .arch = .x86_64, .docker_platform = "linux/amd64" },
};

/// One mode of the unit tests, with the word that the name of its executable ends in.
pub const Mode = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
};

pub const Options = struct {
    /// Each mode that `zig build test` runs the unit tests in.
    modes: []const Mode,
    /// Makes the root module of the unit tests for a target and a mode, with its imports.
    test_module: *const fn (
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module,
};

/// The steps that this file adds.
pub const Steps = struct {
    /// Compiles each Linux test executable, and installs none. `zig build test` depends on it.
    compile: *std.Build.Step,
};

/// Adds the steps `test-linux` and `test-linux-compile`.
pub fn add(b: *std.Build, options: Options) Steps {
    assert(options.modes.len > 0);
    const stamp = b.addSystemCommand(&.{"touch"});
    stamp.addArg(b.pathJoin(&.{ b.install_path, install_directory, stamp_name }));
    // The stamp is the time at which this install finished, so each run writes it again.
    stamp.has_side_effects = true;

    const compile_step = b.step(
        "test-linux-compile",
        "Compile the unit tests for Linux on aarch64 and x86-64, and install none",
    );

    var manifest: []const u8 = "";
    for (processors) |processor| {
        const target = linux_target(b, processor.arch);
        for (options.modes) |mode| {
            const name = b.fmt("tejedor-{s}-{s}", .{ @tagName(processor.arch), mode.name });
            const tests = b.addTest(.{
                .name = name,
                .root_module = options.test_module(b, target, mode.optimize),
            });
            compile_step.dependOn(&tests.step);
            const install = b.addInstallArtifact(tests, .{
                .dest_dir = .{ .override = .{ .custom = install_directory } },
            });
            stamp.step.dependOn(&install.step);
            manifest = b.fmt("{s}{s} {s}\n", .{ manifest, processor.docker_platform, name });
        }
    }
    assert(manifest.len > 0);

    const manifest_file = b.addWriteFiles().add(manifest_name, manifest);
    const install_manifest = b.addInstallFileWithDir(
        manifest_file,
        .{ .custom = install_directory },
        manifest_name,
    );
    stamp.step.dependOn(&install_manifest.step);

    const step = b.step(
        "test-linux",
        "Build the unit tests for Linux on aarch64 and x86-64, for tools/linux_test.sh",
    );
    step.dependOn(&stamp.step);
    return .{ .compile = compile_step };
}

/// Linux on `arch`, with the musl ABI and the baseline CPU model.
pub fn linux_target(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.ResolvedTarget {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .linux,
        .abi = .musl,
        .cpu_model = .baseline,
    });
    assert(target.result.os.tag == .linux);
    assert(target.result.cpu.arch == arch);
    return target;
}
