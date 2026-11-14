//! The checks of the context switch that a test cannot make, because each one is a compile.
//! `build.zig` stays short, so this file holds that part of the build.
//!
//! The form of `switch_context` (record 5). On x86_64 it is a function that is never inlined, and
//! on aarch64 it is an inline function. Zig refuses a call that asks for the other form. So each
//! program below asks for the other form, and its compile must fail with the error of Zig:
//!
//! - `tools/compile_fail/switch_copy_on_x86_64.zig` asks for a copy on x86_64 Linux.
//! - `tools/compile_fail/switch_call_on_aarch64.zig` asks for a call on aarch64 Linux.
//!
//! `zig build test-compile-fail` builds both, beside the program of the check of the Zig version.
//! The test of `src/switch_test_form.zig` checks the form that a plain call gets.
//!
//! The reserved registers (record 5). LLVM never keeps a value in a register that it reserves. It
//! prints a warning for each copy of the switch whose list names one. `zig build test-reserved`
//! builds `tools/switch_reserved.zig`, a copy of the switch, for each aarch64 target of
//! `reserved_targets`, and each compile must print nothing:
//!
//! - Linux on `neoverse_n2`, a processor with SVE, where LLVM reserves `ffr`;
//! - macOS, Android, OpenHarmony, Fuchsia, UEFI and Windows, where LLVM reserves `x18`;
//! - Linux on a processor with the feature `reserve_x18`.
//!
//! The step runs the compiler as a command, because a compile step of the build passes a warning.
//! With an output path, the compiler builds the object each time, so a warning shows on each run
//! of the step.
//!
//! Windows (record 5). `supported` is false on Windows. `zig build test-windows` compiles the tests
//! of `src/switch.zig` for Windows on x86_64 and on aarch64, and runs none. Two comptime asserts of
//! one test stop that compile. One stops it when `supported` differs from the rule of `supports`,
//! and one when `supported` is true on Windows. No compile for UEFI is here: the test runner of std
//! 0.16.0 does not compile for UEFI.
//!
//! Fuchsia (record 5). `supported` is false on Fuchsia too. The test runner of std 0.16.0 does not
//! compile for Fuchsia either, so a comptime assert outside the tests of `src/switch.zig` holds
//! the rule. `zig build test-fuchsia` compiles that file as the root of an object for Fuchsia on
//! x86_64 and on aarch64, and emits nothing. The assert stops each compile when `supported` is
//! true there.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("linux.zig");

/// The file of the package that each program takes as its module `switch`.
const switch_source = "src/switch.zig";

/// The processors that `zig build test-windows` compiles the tests of `src/switch.zig` for.
const windows_processors = [_]std.Target.Cpu.Arch{ .x86_64, .aarch64 };

/// The processors that `zig build test-fuchsia` compiles `src/switch.zig` for.
const fuchsia_processors = [_]std.Target.Cpu.Arch{ .x86_64, .aarch64 };

/// The program of `zig build test-reserved`.
const reserved_source = "tools/switch_reserved.zig";

/// One compile of `zig build test-reserved`: the target, and the processor.
const Reserved = struct {
    target: []const u8,
    cpu: []const u8,
};

/// Each target of `zig build test-reserved`. `neoverse_n2` has SVE, as the processor of GitHub's
/// runner of Linux on arm64 has.
const reserved_targets = [_]Reserved{
    .{ .target = "aarch64-linux-musl", .cpu = "neoverse_n2" },
    .{ .target = "aarch64-macos-none", .cpu = "baseline" },
    .{ .target = "aarch64-linux-android", .cpu = "baseline" },
    .{ .target = "aarch64-linux-ohos", .cpu = "baseline" },
    .{ .target = "aarch64-fuchsia-none", .cpu = "baseline" },
    .{ .target = "aarch64-uefi-msvc", .cpu = "baseline" },
    .{ .target = "aarch64-windows-gnu", .cpu = "baseline" },
    .{ .target = "aarch64-linux-musl", .cpu = "baseline+reserve_x18" },
};

/// One program that must not compile, the processor that it is built for, and the end of the
/// error line that Zig must print. The build system requires that an error line ends with it.
const CompileFail = struct {
    name: []const u8,
    source: []const u8,
    arch: std.Target.Cpu.Arch,
    error_text: []const u8,
};

const form_programs = [_]CompileFail{
    .{
        .name = "switch_copy_on_x86_64",
        .source = "tools/compile_fail/switch_copy_on_x86_64.zig",
        .arch = .x86_64,
        .error_text = "error: inline call of noinline function",
    },
    .{
        .name = "switch_call_on_aarch64",
        .source = "tools/compile_fail/switch_call_on_aarch64.zig",
        .arch = .aarch64,
        .error_text = "error: cannot perform inline call with 'never_inline' modifier",
    },
};

pub const Options = struct {
    /// `zig build test-compile-fail`.
    compile_fail_step: *std.Build.Step,
    /// `zig build test`.
    test_step: *std.Build.Step,
};

/// Adds each check of this file to its step, and the steps `test-reserved`, `test-windows` and
/// `test-fuchsia`.
pub fn add(b: *std.Build, options: Options) void {
    for (form_programs) |program| {
        options.compile_fail_step.dependOn(compile_fail(b, program));
    }
    const reserved_step = b.step(
        "test-reserved",
        "Build a copy of the switch where LLVM reserves a register, and require no warning",
    );
    for (reserved_targets) |reserved| reserved_step.dependOn(reserved_check(b, reserved));
    options.test_step.dependOn(reserved_step);

    const windows_step = b.step(
        "test-windows",
        "Compile the tests of the switch for Windows, and run none: supported must be false there",
    );
    for (windows_processors) |arch| windows_step.dependOn(windows_compile(b, arch));
    options.test_step.dependOn(windows_step);

    const fuchsia_step = b.step(
        "test-fuchsia",
        "Compile the switch for Fuchsia, and run nothing: supported must be false there",
    );
    for (fuchsia_processors) |arch| fuchsia_step.dependOn(fuchsia_compile(b, arch));
    options.test_step.dependOn(fuchsia_step);
}

/// `src/switch.zig` as the root of an object for Fuchsia on `arch`. Nothing asks for the object,
/// so the compiler checks the code and emits nothing. A comptime assert of that file stops the
/// compile when `supported` is true on Fuchsia.
fn fuchsia_compile(b: *std.Build, arch: std.Target.Cpu.Arch) *std.Build.Step {
    const target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .fuchsia, .abi = .none });
    assert(target.result.os.tag == .fuchsia);
    const compile = b.addObject(.{
        .name = b.fmt("switch-fuchsia-{s}", .{@tagName(arch)}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(switch_source),
            .target = target,
            .optimize = .Debug,
        }),
    });
    return &compile.step;
}

/// The tests of `src/switch.zig` for Windows on `arch`. Nothing asks for the executable, so the
/// compiler checks the code and emits nothing.
fn windows_compile(b: *std.Build, arch: std.Target.Cpu.Arch) *std.Build.Step {
    const target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .windows, .abi = .gnu });
    assert(target.result.os.tag == .windows);
    const compile = b.addTest(.{
        .name = b.fmt("switch-windows-{s}", .{@tagName(arch)}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(switch_source),
            .target = target,
            .optimize = .Debug,
        }),
    });
    return &compile.step;
}

/// `zig build-obj` of the program for one target. Its standard error must be empty.
fn reserved_check(b: *std.Build, reserved: Reserved) *std.Build.Step {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-obj",
        "-target",
        reserved.target,
        b.fmt("-mcpu={s}", .{reserved.cpu}),
        "-O",
        "Debug",
        "--dep",
        "switch",
    });
    run.setName(b.fmt("test-reserved {s} {s}", .{ reserved.target, reserved.cpu }));
    run.addPrefixedFileArg("-Mroot=", b.path(reserved_source));
    run.addPrefixedFileArg("-Mswitch=", b.path(switch_source));
    _ = run.addPrefixedOutputFileArg("-femit-bin=", "switch_reserved.o");
    run.expectStdErrEqual("");
    run.expectExitCode(0);
    return &run.step;
}

/// The compile of one program, for Linux on its processor, in Debug. It must fail with the text.
fn compile_fail(b: *std.Build, program: CompileFail) *std.Build.Step {
    const target = linux.linux_target(b, program.arch);
    const module = b.createModule(.{
        .root_source_file = b.path(program.source),
        .target = target,
        .optimize = .Debug,
    });
    module.addImport("switch", b.createModule(.{
        .root_source_file = b.path(switch_source),
        .target = target,
        .optimize = .Debug,
    }));
    const compile = b.addTest(.{ .name = program.name, .root_module = module });
    assert(program.error_text.len > 0);
    compile.expect_errors = .{ .contains = program.error_text };
    return &compile.step;
}
