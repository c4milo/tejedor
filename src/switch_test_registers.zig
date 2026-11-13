//! The test of the registers that a switch must keep (rotor's decision 34, "Build order", step 0).
//!
//! The assembly of the switch saves three things: the stack pointer, the frame pointer, and the
//! address to resume at. Each other register is in its clobber list. So the compiler saves each
//! callee-saved register in a function that holds the switch, before the assembly runs, and
//! restores it after. The compiler does not save a register that the list misses, and the context
//! that runs in between can then change it.
//!
//! The test calls the switch from assembly, so it needs a function that is out of line:
//! `switch_context` on x86_64, and `switch_other_form` on aarch64 (`switch_test.zig`).
//!
//! The test gives each callee-saved register a value of its own, and switches to a fiber. The
//! fiber gives each of those registers another value, and switches back. Then each side reads
//! its registers again. Only assembly can set and read a named register, so one naked function
//! does all three steps.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const switching = @import("switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const supported = switching.supported;
const switch_out_of_line = @import("switch_test.zig").switch_out_of_line;

const testing = std.testing;

/// The callee-saved general registers of the C calling convention, without the frame pointer:
/// `x19` to `x28` on aarch64 (AAPCS64), and `rbx` and `r12` to `r15` on x86_64 (System V).
const general_count = switch (builtin.cpu.arch) {
    .aarch64 => 10,
    .x86_64 => 5,
    else => 0,
};

/// The callee-saved floating-point registers: the low 64 bits of `v8` to `v15` on aarch64, and
/// none on x86_64.
const float_count = switch (builtin.cpu.arch) {
    .aarch64 => 8,
    else => 0,
};

/// The values that `switch_with_registers` sets before a switch, or reads after it. The assembly
/// below names each offset as a number.
const Registers = extern struct {
    general: [general_count]u64,
    /// `x29` or `rbp`.
    frame: u64,
    float: [float_count]u64,
    /// The stack pointer before the switch, and after it. The function only writes them.
    stack_before: u64,
    stack_after: u64,
};

comptime {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            assert(@offsetOf(Registers, "general") == 0);
            assert(@offsetOf(Registers, "frame") == 80);
            assert(@offsetOf(Registers, "float") == 88);
            assert(@offsetOf(Registers, "stack_before") == 152);
            assert(@offsetOf(Registers, "stack_after") == 160);
        },
        .x86_64 => {
            assert(@offsetOf(Registers, "general") == 0);
            assert(@offsetOf(Registers, "frame") == 40);
            assert(@offsetOf(Registers, "stack_before") == 48);
            assert(@offsetOf(Registers, "stack_after") == 56);
        },
        else => {},
    }
}

/// Its arguments are those of `switch_with_registers`, in the first three argument registers.
///
/// 1. It saves each callee-saved register of its caller, and the pointer `seen`, on the stack.
/// 2. It writes the stack pointer to `seen.stack_before`.
/// 3. It loads each callee-saved register from `set`.
/// 4. It calls the switch with the message.
/// 5. After the switch back, it writes each of those registers, and the stack pointer, to `seen`.
/// 6. It restores the registers of its caller, and returns.
fn set_switch_and_read() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ pushq %%rbx
            \\ pushq %%rbp
            \\ pushq %%r12
            \\ pushq %%r13
            \\ pushq %%r14
            \\ pushq %%r15
            \\ pushq %%rdx
            \\ movq %%rsp, 48(%%rdx)
            \\ movq 0(%%rsi), %%rbx
            \\ movq 8(%%rsi), %%r12
            \\ movq 16(%%rsi), %%r13
            \\ movq 24(%%rsi), %%r14
            \\ movq 32(%%rsi), %%r15
            \\ movq 40(%%rsi), %%rbp
            \\ callq %[switch_out_of_line:P]
            \\ movq (%%rsp), %%rdx
            \\ movq %%rbx, 0(%%rdx)
            \\ movq %%r12, 8(%%rdx)
            \\ movq %%r13, 16(%%rdx)
            \\ movq %%r14, 24(%%rdx)
            \\ movq %%r15, 32(%%rdx)
            \\ movq %%rbp, 40(%%rdx)
            \\ movq %%rsp, 56(%%rdx)
            \\ addq $8, %%rsp
            \\ popq %%r15
            \\ popq %%r14
            \\ popq %%r13
            \\ popq %%r12
            \\ popq %%rbp
            \\ popq %%rbx
            \\ retq
            :
            : [switch_out_of_line] "X" (switch_out_of_line),
        ),
        .aarch64 => asm volatile (
            \\ sub sp, sp, #176
            \\ stp x19, x20, [sp, #0]
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ stp x29, x30, [sp, #80]
            \\ stp d8, d9, [sp, #96]
            \\ stp d10, d11, [sp, #112]
            \\ stp d12, d13, [sp, #128]
            \\ stp d14, d15, [sp, #144]
            \\ str x2, [sp, #160]
            \\ mov x9, sp
            \\ str x9, [x2, #152]
            \\ ldp x19, x20, [x1, #0]
            \\ ldp x21, x22, [x1, #16]
            \\ ldp x23, x24, [x1, #32]
            \\ ldp x25, x26, [x1, #48]
            \\ ldp x27, x28, [x1, #64]
            \\ ldr x29, [x1, #80]
            \\ ldp d8, d9, [x1, #88]
            \\ ldp d10, d11, [x1, #104]
            \\ ldp d12, d13, [x1, #120]
            \\ ldp d14, d15, [x1, #136]
            \\ bl %[switch_out_of_line]
            \\ ldr x9, [sp, #160]
            \\ stp x19, x20, [x9, #0]
            \\ stp x21, x22, [x9, #16]
            \\ stp x23, x24, [x9, #32]
            \\ stp x25, x26, [x9, #48]
            \\ stp x27, x28, [x9, #64]
            \\ str x29, [x9, #80]
            \\ stp d8, d9, [x9, #88]
            \\ stp d10, d11, [x9, #104]
            \\ stp d12, d13, [x9, #120]
            \\ stp d14, d15, [x9, #136]
            \\ mov x10, sp
            \\ str x10, [x9, #160]
            \\ ldp x19, x20, [sp, #0]
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x29, x30, [sp, #80]
            \\ ldp d8, d9, [sp, #96]
            \\ ldp d10, d11, [sp, #112]
            \\ ldp d12, d13, [sp, #128]
            \\ ldp d14, d15, [sp, #144]
            \\ add sp, sp, #176
            \\ ret
            :
            : [switch_out_of_line] "X" (switch_out_of_line),
        ),
        else => @compileError("no fiber switch for this architecture"),
    }
}

/// Switches with `message` while each callee-saved register holds its value of `set`. After the
/// switch back, it writes to `seen` what each of those registers holds.
fn switch_with_registers(message: *const Switch, set: *const Registers, seen: *Registers) void {
    const call: *const fn (*const Switch, *const Registers, *Registers) callconv(.c) void =
        @ptrCast(&set_switch_and_read);
    call(message, set, seen);
}

/// A frame with no caller. While a context is in the switch, its frame pointer names one of
/// these, so a walk of the frames stops there.
var main_frame: [2]usize = .{ 0, 0 };
var fiber_frame: [2]usize = .{ 0, 0 };

/// The values of one context: a pattern that differs for each register, and for each context.
fn values_of(frame: *const [2]usize, seed: u64) Registers {
    var registers: Registers = undefined;
    for (&registers.general, 1..) |*general, number| {
        general.* = seed ^ (0x0101_0101_0101_0101 * @as(u64, number));
    }
    for (&registers.float, 1..) |*float, number| {
        float.* = seed ^ (0x1010_1010_1010_1010 * @as(u64, number));
    }
    registers.frame = @intFromPtr(frame);
    registers.stack_before = 0;
    registers.stack_after = 0;
    return registers;
}

fn expect_kept(set: *const Registers, seen: *const Registers) !void {
    try testing.expectEqualSlices(u64, &set.general, &seen.general);
    try testing.expectEqual(set.frame, seen.frame);
    try testing.expectEqualSlices(u64, &set.float, &seen.float);
    try testing.expect(seen.stack_before != 0);
    try testing.expectEqual(seen.stack_before, seen.stack_after);
}

/// The bytes of the fiber's stack.
const stack_bytes = 64 * 1024;

/// The switches that the test makes to the fiber. The first one starts the fiber, and each
/// other one resumes it inside `switch_with_registers`.
const rounds = 4;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;
var fiber_set: Registers align(@alignOf(Registers)) = undefined;
var fiber_seen: Registers align(@alignOf(Registers)) = undefined;
var fiber_rounds: usize = 0;

/// It switches back with values of its own in the callee-saved registers. So the main context
/// gets its values back only if the switch keeps them.
fn registers_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    for (0..rounds) |_| {
        fiber_rounds += 1;
        switch_with_registers(&to_main, &fiber_set, &fiber_seen);
    }
    unreachable;
}

test "a switch out and back keeps each callee-saved register and the stack pointer" {
    if (!supported) return error.SkipZigTest;
    const set = values_of(&main_frame, 0x0F0F_0F0F_0F0F_0F0F);
    fiber_set = values_of(&fiber_frame, 0xF0F0_F0F0_F0F0_F0F0);
    fiber_seen = std.mem.zeroes(Registers);
    fiber_rounds = 0;
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(@intFromPtr(&stack) + stack_bytes, 0, registers_fiber);

    for (1..rounds + 1) |round| {
        var seen = std.mem.zeroes(Registers);
        switch_with_registers(&to_fiber, &set, &seen);
        try testing.expectEqual(round, fiber_rounds);
        try expect_kept(&set, &seen);
        // From the second round, the fiber read its own registers after the switch back to it.
        if (round > 1) try expect_kept(&fiber_set, &fiber_seen);
    }
}
