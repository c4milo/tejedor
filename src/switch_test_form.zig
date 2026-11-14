//! The test of the form of `switch_context` (records 5 and 6). On aarch64 a plain call of it must
//! give a copy of the switch in the caller. On x86_64 it must give a direct call of the jump.
//!
//! A switch saves the address to resume at for the context that it leaves. The test reads that
//! address. It compares it with the return addresses of two calls in the caller: one before the
//! switch and one after it.
//!
//! - With a copy, the address is a label of the copy, in the code of the caller, between the two
//!   calls.
//! - With the jump, the address is the return address of the call of `jump_switch`. So it is in
//!   the code of the caller too, between the two calls. The 5 bytes before it must be a direct call
//!   whose target is `switch_context`, and the code at that target must start with the six pushes
//!   of the jump. A call through another function puts the address in that function, or calls
//!   other code, and the test fails.
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
const jump_words = @import("switch_test.zig").jump_words;

const testing = std.testing;

/// The bytes of the fiber's stack.
const stack_bytes = 64 * 1024;

/// On x86_64, the bytes of a direct call: the opcode `0xE8`, then a 32-bit offset of its target
/// from the end of the call.
const call_bytes = 5;
const call_opcode: u8 = 0xE8;

/// On x86_64, the first bytes of the jump: `pushq` of `rbp`, `rbx`, `r12`, `r13`, `r14` and `r15`.
const jump_pushes = [_]u8{ 0x55, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57 };

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

/// The address to resume at of the main context, as the fiber read it.
var resumed_in_fiber: usize = 0;

/// It reads the address to resume at of the main context, and switches back one time. The main
/// context waits at its switch while the fiber runs, so the words that the jump pushed for it are
/// whole. After the switch back, later calls of the main context write over them. The test
/// switches to the fiber one time, so it never reaches its end.
fn back_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    resumed_in_fiber = resume_address(&main_context);
    switch_context(&to_main);
    unreachable;
}

/// The address to resume at that a switch saved for `context`.
fn resume_address(context: *const Context) usize {
    return switch (builtin.cpu.arch) {
        .aarch64 => context.pc,
        .x86_64 => jump_words(context).resume_address,
        else => @compileError("no fiber switch for this architecture"),
    };
}

/// On x86_64, the target of the call that ends at `return_address`, or null when the 5 bytes
/// before it are no direct call.
fn call_target(return_address: usize) ?usize {
    const call: *const [call_bytes]u8 = @ptrFromInt(return_address - call_bytes);
    if (call[0] != call_opcode) return null;
    const offset: isize = std.mem.readInt(i32, call[1..call_bytes], .little);
    return @bitCast(@as(isize, @bitCast(return_address)) + offset);
}

test "a plain call of the switch is a copy on aarch64 and a call of the jump on x86_64" {
    if (!supported) return error.SkipZigTest;
    marks = .{ 0, 0 };
    resumed_in_fiber = 0;
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(@intFromPtr(&stack) + stack_bytes, 0, back_fiber);
    switch_between_marks(&to_fiber);

    // The switch to the fiber saved where the main context resumes.
    const resumed = resumed_in_fiber;
    try testing.expect(marks[0] != 0);
    try testing.expect(marks[0] < marks[1]);
    try testing.expect(marks[0] < resumed and resumed < marks[1]);
    switch (builtin.cpu.arch) {
        .aarch64 => {},
        .x86_64 => {
            const target = call_target(resumed) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@intFromPtr(switch_context), target);
            const code: *const [jump_pushes.len]u8 = @ptrFromInt(target);
            try testing.expectEqualSlices(u8, &jump_pushes, code);
        },
        else => unreachable,
    }
}
