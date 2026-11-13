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
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("linux.zig");

/// The file of the package that each program takes as its module `switch`.
const switch_source = "src/switch.zig";

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
};

/// Adds each check of this file to its step.
pub fn add(b: *std.Build, options: Options) void {
    for (form_programs) |program| {
        options.compile_fail_step.dependOn(compile_fail(b, program));
    }
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
