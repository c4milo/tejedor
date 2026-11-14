//! The tests of std's switch on x86_64 with the clobber list of the package, in its two forms
//! (`std_switch_x86_64.zig`). Each test runs on x86_64 alone. `zig build test-bench` runs them, and
//! the Linux gate runs them for x86-64 Linux.
//!
//! - The test of the message register proves that the list does not name `rsi` (rotor's decision
//!   22). It calls the switch out of line, so it calls `switch_called`.
//! - The test of the callee-saved registers proves the names `rbx` and `r12` to `r15` of the list.
//!   `switch_called` saves each one that the list names, around its copy of the switch.
//! - The test of 32 values proves the names `xmm0` to `xmm15` (record 2). It runs the copy: under a
//!   call, a caller keeps no value in a caller-saved register, and the test cannot see a name.
//! - The test of an `f80` value runs the call. The copy loses that value in ReleaseSafe (record 3),
//!   because no name of the clobber type of Zig 0.16.0 covers the x87 registers. So the test does
//!   not run the copy. To see that failure, make `extended_fiber` and the test call the copy.
//! - The test of the first stack proves the first context of record 4 for x86_64.
//!
//! A fiber here records what it sees in a `var` of this file, and the test checks that `var` on
//! the main context. So no fiber calls `std.testing`, which can need more stack than a fiber has.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const std_switch = @import("std_switch_x86_64.zig");
const Context = std_switch.Context;
const Switch = std_switch.Switch;
const initial_context = std_switch.initial_context;
const switching = @import("switch");
const stack_end_alignment = switching.stack_end_alignment;
const supported = std_switch.supported;

const testing = std.testing;

/// The bytes of the stack of each fiber here.
const stack_bytes = 64 * 1024;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;

/// Makes `fiber_context` a new fiber that runs `main` with `argument`, on a stack that ends at
/// `stack_end`. It also sets the two messages between that fiber and the main context.
fn start_fiber_at(stack_end: usize, argument: usize, comptime main: switching.Main) void {
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(stack_end, argument, main);
}

fn start_fiber(argument: usize, comptime main: switching.Main) void {
    start_fiber_at(@intFromPtr(&stack) + stack_bytes, argument, main);
}

/// Clears `rsi`, the register that the switch takes its message in, and jumps to `switch_called`
/// with the message in `rdi`. A switch that reads `rsi` and does not load it first then reads 0,
/// and faults. With `rsi` in the list, std's switch skipped that load in an optimized build.
fn call_with_message_register_cleared() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ xorl %%esi, %%esi
            \\ jmp %[switch_called:P]
            :
            : [switch_called] "X" (&std_switch.switch_called),
        ),
        else => @compileError("these tests are for x86_64 alone"),
    }
}

fn switch_with_message_register_cleared(message: *const Switch) void {
    const call: *const fn (*const Switch) callconv(.c) void =
        @ptrCast(&call_with_message_register_cleared);
    call(message);
}

var returns: usize = 0;

/// It switches back two times, and no context switches to it a third time.
fn twice_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    returns += argument;
    switch_with_message_register_cleared(&to_main);
    returns += 1;
    switch_with_message_register_cleared(&to_main);
    unreachable;
}

test "std's call on x86_64 loads its message from its argument, whatever rsi holds" {
    if (!supported) return error.SkipZigTest;
    returns = 0;
    start_fiber(1, twice_fiber);
    switch_with_message_register_cleared(&to_fiber);
    try testing.expectEqual(1, returns);
    switch_with_message_register_cleared(&to_fiber);
    try testing.expectEqual(2, returns);
}

/// What `first_fiber` saw when it started.
var seen_argument: usize = 0;
var seen_return_address: usize = 0;
var seen_frame: usize = 0;
var seen_caller_frame: usize = 0;

fn first_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    seen_argument = argument;
    seen_return_address = @returnAddress();
    seen_frame = @frameAddress();
    // The first word of a frame holds the frame pointer of the caller.
    const frame: *const usize = @ptrFromInt(seen_frame);
    seen_caller_frame = frame.*;
    std_switch.switch_called(&to_main);
    unreachable;
}

/// The test of the first stack fills the whole stack, and these bytes above its end, with the
/// byte below. So a word that `initial_context` does not write is not zero by chance.
const canary_bytes = 64;
const canary: u8 = 0xA5;

test "a new fiber of std's switch on x86_64 starts with its argument, with no caller, aligned" {
    if (!supported) return error.SkipZigTest;
    const argument = 0x0123_4567_89AB_CDEF;
    const stack_end = @intFromPtr(&stack) + stack_bytes - canary_bytes;
    @memset(&stack, canary);
    seen_argument = 0;
    seen_return_address = 1;
    seen_frame = 0;
    seen_caller_frame = 1;
    start_fiber_at(stack_end, argument, first_fiber);
    std_switch.switch_called(&to_fiber);
    try testing.expectEqual(argument, seen_argument);
    try testing.expectEqual(0, seen_return_address);
    try testing.expectEqual(0, seen_caller_frame);
    // `main` pushed the frame pointer at its entry, where the stack pointer is 8 bytes past a
    // multiple of 16. So its frame is on a multiple of 16.
    try testing.expectEqual(0, seen_frame % stack_end_alignment);
    try testing.expect(seen_frame > @intFromPtr(&stack));
    try testing.expect(seen_frame < stack_end);
    for (stack[stack_bytes - canary_bytes ..]) |byte| try testing.expectEqual(canary, byte);
}

/// The rounds of the tests of an `f80` value and of 32 values.
const rounds = 64;

/// What the main context and the fiber pass to each other in the test of an `f80` value.
const ExtendedMail = struct {
    to_fiber: usize = 0,
    half_to_main: f80 = 0,
};

/// It adds half of each value that the main context sends to an `f80` sum, and sends the sum back.
/// The sum is a local, and the compiler computes an `f80` value in the x87 registers.
fn extended_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const mail: *ExtendedMail = @ptrFromInt(argument);
    var half_sum: f80 = 0;
    for (0..rounds) |_| {
        half_sum += @as(f80, @floatFromInt(mail.to_fiber)) / 2;
        mail.half_to_main = half_sum;
        std_switch.switch_called(&to_main);
    }
    unreachable;
}

test "the main context and a fiber of std's call on x86_64 each keep an f80 value" {
    if (!supported) return error.SkipZigTest;
    var mail: ExtendedMail = .{};
    start_fiber(@intFromPtr(&mail), extended_fiber);
    var half_sum: f80 = 0;
    for (0..rounds) |round| {
        const value = 3 * round + 7;
        mail.to_fiber = value;
        std_switch.switch_called(&to_fiber);
        half_sum += @as(f80, @floatFromInt(value)) / 2;
        // Half of an integer is exact in an `f80`, so the two sums are equal bit for bit.
        try testing.expectEqual(half_sum, mail.half_to_main);
    }
}

/// The floating-point values that one context keeps across a switch: two times the count of the
/// registers `xmm0` to `xmm15`.
const values_count = 32;

var fiber_in: [values_count]f64 = undefined;
var fiber_out: [values_count]f64 = undefined;

/// Reads each value of `in`, switches with a copy of the switch, and then writes each value to
/// `out`. Each read and each write is volatile, so each value lives across the switch, in a
/// register or on the stack. The main context and the fiber both run this one function. So a
/// register that holds a value of one side across the switch holds a value of the other side too.
noinline fn copy_with_values(
    message: *const Switch,
    in: *const volatile [values_count]f64,
    out: *volatile [values_count]f64,
) void {
    var values: [values_count]f64 = undefined;
    inline for (0..values_count) |index| values[index] = in[index];
    std_switch.switch_copied(message);
    inline for (0..values_count) |index| out[index] = values[index];
}

fn values_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    for (0..rounds) |_| copy_with_values(&to_main, &fiber_in, &fiber_out);
    unreachable;
}

test "the main context and a fiber of std's copy on x86_64 each keep 32 floating-point values" {
    if (!supported) return error.SkipZigTest;
    var in: [values_count]f64 = undefined;
    var out: [values_count]f64 = undefined;
    for (&in, &fiber_in, 0..) |*mine, *other, index| {
        mine.* = @floatFromInt(1000 + index);
        other.* = @floatFromInt(2000 + index);
    }
    start_fiber(0, values_fiber);
    for (0..rounds) |round| {
        @memset(&out, 0);
        copy_with_values(&to_fiber, &in, &out);
        try testing.expectEqualSlices(f64, &in, &out);
        // From the second round, the fiber wrote its values after the switch back to it.
        if (round > 0) try testing.expectEqualSlices(f64, &fiber_in, &fiber_out);
    }
}

/// The callee-saved registers of System V, and the stack pointer before a switch and after it. The
/// assembly below names each offset as a number.
const Registers = extern struct {
    /// `rbx`, then `r12` to `r15`.
    general: [5]u64,
    /// `rbp`.
    frame: u64,
    stack_before: u64,
    stack_after: u64,
};

comptime {
    assert(@offsetOf(Registers, "general") == 0);
    assert(@offsetOf(Registers, "frame") == 40);
    assert(@offsetOf(Registers, "stack_before") == 48);
    assert(@offsetOf(Registers, "stack_after") == 56);
}

/// Its arguments are the message, `set` and `seen`, in `rdi`, `rsi` and `rdx`.
///
/// 1. It saves each callee-saved register of its caller, and `seen`, on the stack.
/// 2. It writes the stack pointer to `seen.stack_before`.
/// 3. It loads each callee-saved register from `set`.
/// 4. It calls `switch_called` with the message.
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
            \\ callq %[switch_called:P]
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
            : [switch_called] "X" (&std_switch.switch_called),
        ),
        else => @compileError("these tests are for x86_64 alone"),
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
    registers.frame = @intFromPtr(frame);
    registers.stack_before = 0;
    registers.stack_after = 0;
    return registers;
}

fn expect_kept(set: *const Registers, seen: *const Registers) !void {
    try testing.expectEqualSlices(u64, &set.general, &seen.general);
    try testing.expectEqual(set.frame, seen.frame);
    try testing.expect(seen.stack_before != 0);
    try testing.expectEqual(seen.stack_before, seen.stack_after);
}

/// The switches that the test of the registers makes to the fiber.
const registers_rounds = 4;

var fiber_set: Registers align(@alignOf(Registers)) = undefined;
var fiber_seen: Registers align(@alignOf(Registers)) = undefined;
var fiber_rounds: usize = 0;

/// It switches back with values of its own in the callee-saved registers. So the main context
/// gets its values back only if `switch_called` keeps them.
fn registers_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    for (0..registers_rounds) |_| {
        fiber_rounds += 1;
        switch_with_registers(&to_main, &fiber_set, &fiber_seen);
    }
    unreachable;
}

test "a switch of std's call on x86_64 out and back keeps each callee-saved register" {
    if (!supported) return error.SkipZigTest;
    const set = values_of(&main_frame, 0x0F0F_0F0F_0F0F_0F0F);
    fiber_set = values_of(&fiber_frame, 0xF0F0_F0F0_F0F0_F0F0);
    fiber_seen = std.mem.zeroes(Registers);
    fiber_rounds = 0;
    start_fiber(0, registers_fiber);
    for (1..registers_rounds + 1) |round| {
        var seen = std.mem.zeroes(Registers);
        switch_with_registers(&to_fiber, &set, &seen);
        try testing.expectEqual(round, fiber_rounds);
        try expect_kept(&set, &seen);
        // From the second round, the fiber read its own registers after the switch back to it.
        if (round > 1) try expect_kept(&fiber_set, &fiber_seen);
    }
}
