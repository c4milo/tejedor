//! The test of the form of `switch_context` (record 5). On aarch64 a plain call of it must give a
//! copy of the switch in the caller. On x86_64 it must give a call of `switch_context`.
//!
//! A switch saves the address to resume at in the context that it leaves. With a copy, that
//! address is in the code of the caller, between the call before the switch and the call after it.
//! With a call, it is in the code of `switch_context`, which is another function. So the test
//! reads the address that the switch saved. It compares that address with the return addresses of
//! two calls in the caller: one before the switch and one after it.
//!
//! `zig build test-compile-fail` holds the other half of the proof. A program that asks for a copy
//! of `switch_context` on x86_64 must not compile. A program that asks for a call of it on aarch64
//! must not compile either.
const std = @import("std");
const builtin = @import("builtin");
const switching = @import("switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const supported = switching.supported;
const switch_context = switching.switch_context;

const testing = std.testing;

/// The bytes of the fiber's stack.
const stack_bytes = 64 * 1024;

/// On x86_64, the most bytes from the start of `switch_context` to the address that it resumes
/// at. The function saves the callee-saved registers, and then runs the nine instructions of the
/// switch. On x86_64 Linux the disassembly of 2026-11-13 showed 51 bytes in ReleaseSafe, and 69 in
/// Debug.
const call_bytes_max = 256;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;

/// The return addresses of the call before the switch and of the call after it.
var marks: [2]usize = .{ 0, 0 };

/// Writes its return address to `marks[index]`. The write is volatile, so the compiler keeps each
/// call on its side of the switch.
noinline fn mark(index: usize) void {
    const slot: *volatile usize = &marks[index];
    slot.* = @returnAddress();
}

/// The caller of the test: one call of `mark`, the switch, and one more call of `mark`. The last
/// call is no tail call, so its return address is in this function too.
noinline fn switch_between_marks(message: *const Switch) void {
    mark(0);
    switch_context(message);
    @call(.never_tail, mark, .{1});
}

/// It switches back one time. The test switches to it one time, so it never reaches its end.
fn back_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    switch_context(&to_main);
    unreachable;
}

/// The address to resume at that a switch saved in `context`.
fn resume_address(context: *const Context) usize {
    return switch (builtin.cpu.arch) {
        .aarch64 => context.pc,
        .x86_64 => context.rip,
        else => @compileError("no fiber switch for this architecture"),
    };
}

test "a plain call of the switch is a copy on aarch64 and a call on x86_64" {
    if (!supported) return error.SkipZigTest;
    marks = .{ 0, 0 };
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(@intFromPtr(&stack) + stack_bytes, 0, back_fiber);
    switch_between_marks(&to_fiber);

    // The switch to the fiber saved where the main context resumes. The switch back left it.
    const resumed = resume_address(&main_context);
    try testing.expect(marks[0] != 0);
    try testing.expect(marks[0] < marks[1]);
    const in_caller = marks[0] < resumed and resumed < marks[1];
    switch (builtin.cpu.arch) {
        .aarch64 => try testing.expect(in_caller),
        .x86_64 => {
            try testing.expect(!in_caller);
            const start = @intFromPtr(&switch_context);
            try testing.expect(resumed > start);
            try testing.expect(resumed - start < call_bytes_max);
        },
        else => unreachable,
    }
}
