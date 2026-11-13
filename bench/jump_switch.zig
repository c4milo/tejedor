//! A candidate for the switch of x86-64 System V, in the style of Boost.Context (record 5). It is
//! under `bench/` alone, and the package does not use it. The probe measures it beside the two
//! forms of the switch of the package. It replaces the call of `switch_context` only if it measures
//! faster, and Camilo rules it.
//!
//! The design is the design of Boost.Context's `jump_fcontext` for x86-64 System V, in
//! `jump_x86_64_sysv_elf_gas.S`. This file holds no code of Boost:
//!
//! 1. A caller calls `jump_switch`, a function in assembly. The call pushes the address to resume
//!    at.
//! 2. The function pushes the six callee-saved registers of System V: `rbp`, `rbx` and `r12` to
//!    `r15`.
//! 3. It saves the stack pointer in the context that it leaves, and loads the stack pointer of the
//!    context that it resumes.
//! 4. It pops the six registers of that context, and then the address to resume at. It jumps to
//!    that address with `jmp`, and not with `ret`.
//!
//! So a context is one word, its stack pointer, and its stack holds the rest. The switch of the
//! package writes three words to a context, and a function around it saves the callee-saved
//! registers.
//!
//! Boost's function also saves MXCSR and the x87 control word. This one does not, as the switch of
//! the package does not: the rounding mode and the exception masks belong to the thread (record 3).
//!
//! The caller calls `jump_switch` as a C function. So the calling convention covers each register
//! that the function does not save, the x87 registers included.
//!
//! The candidate needs a process with no shadow stack, as each form of the switch of the package
//! does (`src/switch.zig`). Its call of `jump_switch` never returns, and a shadow stack refuses
//! that. Boost's design has a path for shadow stacks, which the candidate leaves out. The session
//! recalled that path, and did not read it.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const switching = @import("switch");
const stack_end_alignment = switching.stack_end_alignment;
const Main = switching.Main;

/// True where this file has a candidate: x86-64 with the System V calling convention.
pub const supported = switching.supported and builtin.cpu.arch == .x86_64;

/// A context of the candidate: the stack pointer that it had when it left. Its stack holds its
/// six callee-saved registers, and above them the address to resume at.
pub const Context = extern struct {
    stack_pointer: usize,
};

/// What a switch names: the context to save into, and the context to resume.
pub const Switch = extern struct {
    old: *Context,
    new: *Context,
};

comptime {
    // The assembly names each field by its offset.
    assert(@offsetOf(Context, "stack_pointer") == 0);
    assert(@offsetOf(Switch, "old") == 0);
    assert(@offsetOf(Switch, "new") == @sizeOf(usize));
}

/// The words that `jump_switch` pops from a context that it resumes: six registers, then the
/// address to resume at.
const resume_words = 7;

/// The place of each word on a first stack, from the first stack pointer up: the order of the pops.
const Word = enum(u8) { r15, r14, r13, r12, rbx, rbp, resume_address };

comptime {
    assert(@typeInfo(Word).@"enum".fields.len == resume_words);
}

/// The address to resume at of a context that a switch left: the last word that `jump_switch`
/// pops from its stack.
pub fn resume_address(context: *const Context) usize {
    const words: *const [resume_words]usize = @ptrFromInt(context.stack_pointer);
    return words[@intFromEnum(Word.resume_address)];
}

/// Switches with `message`. The caller calls `jump_switch`, which returns when another switch
/// names this context as its `new`.
pub inline fn jump(message: *const Switch) void {
    const call: *const fn (*const Switch) callconv(.c) void = @ptrCast(&jump_switch);
    call(message);
}

/// The candidate. Its argument, the message, is in `rdi`. It reads both contexts of the message
/// before it switches the stack, because the message can be on the stack that it leaves.
fn jump_switch() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ pushq %%rbp
            \\ pushq %%rbx
            \\ pushq %%r12
            \\ pushq %%r13
            \\ pushq %%r14
            \\ pushq %%r15
            \\ movq 0(%%rdi), %%rax
            \\ movq 8(%%rdi), %%rcx
            \\ movq %%rsp, 0(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ popq %%r15
            \\ popq %%r14
            \\ popq %%r13
            \\ popq %%r12
            \\ popq %%rbx
            \\ popq %%rbp
            \\ popq %%rcx
            \\ jmpq *%%rcx
        ),
        else => @compileError("the candidate is for x86-64 alone"),
    }
}

/// The first instructions of a new fiber. `jump_switch` popped the argument into `r12` and the
/// address of `main` into `rbx`. The entry moves the argument to `rdi`, and pushes a return address
/// of zero. So a stack trace from the fiber ends at `main` (record 4). Then it jumps to `main`.
fn jump_entry() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq %%r12, %%rdi
            \\ pushq $0
            \\ jmpq *%%rbx
        ),
        else => @compileError("the candidate is for x86-64 alone"),
    }
}

/// The context that a new fiber starts from. `stack_end` is the address one byte after the stack
/// of the fiber. The first stack holds the seven words that `jump_switch` pops. After the pops the
/// stack pointer is `stack_end`, and the entry pushes one word. So `main` starts with the stack
/// pointer 8 bytes past a multiple of 16, as after a call.
pub fn initial_context(stack_end: usize, argument: usize, comptime main: Main) Context {
    assert(stack_end % stack_end_alignment == 0);
    assert(stack_end != 0);
    const first = stack_end - resume_words * @sizeOf(usize);
    const words: *[resume_words]usize = @ptrFromInt(first);
    words.* = @splat(0);
    words[@intFromEnum(Word.r12)] = argument;
    words[@intFromEnum(Word.rbx)] = @intFromPtr(&main);
    words[@intFromEnum(Word.resume_address)] = @intFromPtr(&jump_entry);
    return .{ .stack_pointer = first };
}

// Tests. Each one runs on x86-64 alone. `zig build test-bench` runs them, and the Linux gate runs
// them for x86-64 Linux.

const testing = std.testing;

/// The bytes of the stack of each fiber here.
const stack_bytes = 64 * 1024;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;

fn start_fiber(argument: usize, comptime main: switching.Main) void {
    start_fiber_at(@intFromPtr(&stack) + stack_bytes, argument, main);
}

fn start_fiber_at(stack_end: usize, argument: usize, comptime main: switching.Main) void {
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(stack_end, argument, main);
}

/// The test of the first stack fills the whole stack, and these bytes above its end, with the
/// byte below. So a word that `initial_context` does not write is not zero by chance.
const canary_bytes = 64;
const canary: u8 = 0xA5;

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
    jump(&to_main);
    unreachable;
}

test "a new fiber of the candidate starts with its argument, with no caller, on an aligned frame" {
    if (!supported) return error.SkipZigTest;
    const argument = 0x0123_4567_89AB_CDEF;
    const stack_end = @intFromPtr(&stack) + stack_bytes - canary_bytes;
    @memset(&stack, canary);
    seen_argument = 0;
    seen_return_address = 1;
    seen_frame = 0;
    seen_caller_frame = 1;
    start_fiber_at(stack_end, argument, first_fiber);
    jump(&to_fiber);
    try testing.expectEqual(argument, seen_argument);
    try testing.expectEqual(0, seen_return_address);
    try testing.expectEqual(0, seen_caller_frame);
    // `main` pushed the frame pointer at its entry, where the stack pointer is 8 bytes past a
    // multiple of 16. So its frame is on a multiple of 16.
    try testing.expectEqual(0, seen_frame % stack_end_alignment);
    try testing.expect(seen_frame > @intFromPtr(&stack));
    try testing.expect(seen_frame < stack_end);
}

/// The switches that the test of the count makes to the fiber, one after the other.
const switches_in_a_row = 100_000;

/// It counts each time that it runs, through the pointer that it got as its argument.
fn counting_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const count: *usize = @ptrFromInt(argument);
    for (0..switches_in_a_row) |_| {
        count.* += 1;
        jump(&to_main);
    }
    unreachable;
}

test "the fiber of the candidate runs one time for each of many switches" {
    if (!supported) return error.SkipZigTest;
    var count: usize = 0;
    start_fiber(@intFromPtr(&count), counting_fiber);
    var sum: usize = 0;
    for (1..switches_in_a_row + 1) |round| {
        jump(&to_fiber);
        try testing.expectEqual(round, count);
        sum += count;
    }
    try testing.expectEqual(switches_in_a_row * (switches_in_a_row + 1) / 2, sum);
}

/// The rounds of the test of an `f80` value.
const extended_rounds = 64;

/// What the main context and the fiber pass to each other in the test of an `f80` value.
const ExtendedMail = struct {
    to_fiber: usize = 0,
    half_to_main: f80 = 0,
};

/// It adds half of each value that the main context sends to an `f80` sum, and sends the sum back.
/// The sum is a local. The compiler computes an `f80` value in the x87 registers, which the
/// candidate does not save.
fn extended_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const mail: *ExtendedMail = @ptrFromInt(argument);
    var half_sum: f80 = 0;
    for (0..extended_rounds) |_| {
        half_sum += @as(f80, @floatFromInt(mail.to_fiber)) / 2;
        mail.half_to_main = half_sum;
        jump(&to_main);
    }
    unreachable;
}

test "the main context and the fiber of the candidate each keep an f80 value across a switch" {
    if (!supported) return error.SkipZigTest;
    var mail: ExtendedMail = .{};
    start_fiber(@intFromPtr(&mail), extended_fiber);
    var half_sum: f80 = 0;
    for (0..extended_rounds) |round| {
        const value = 3 * round + 7;
        mail.to_fiber = value;
        jump(&to_fiber);
        half_sum += @as(f80, @floatFromInt(value)) / 2;
        // Half of an integer is exact in an `f80`, so the two sums are equal bit for bit.
        try testing.expectEqual(half_sum, mail.half_to_main);
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
/// 4. It calls `jump_switch` with the message.
/// 5. After the switch back, it writes each of those registers, and the stack pointer, to `seen`.
/// 6. It restores the registers of its caller, and returns.
fn set_jump_and_read() callconv(.naked) void {
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
            \\ callq %[jump_switch:P]
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
            : [jump_switch] "X" (&jump_switch),
        ),
        else => @compileError("the candidate is for x86-64 alone"),
    }
}

/// Switches with `message` while each callee-saved register holds its value of `set`. After the
/// switch back, it writes to `seen` what each of those registers holds.
fn jump_with_registers(message: *const Switch, set: *const Registers, seen: *Registers) void {
    const call: *const fn (*const Switch, *const Registers, *Registers) callconv(.c) void =
        @ptrCast(&set_jump_and_read);
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
/// gets its values back only if the candidate keeps them.
fn registers_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    for (0..registers_rounds) |_| {
        fiber_rounds += 1;
        jump_with_registers(&to_main, &fiber_set, &fiber_seen);
    }
    unreachable;
}

test "a switch of the candidate out and back keeps each callee-saved register" {
    if (!supported) return error.SkipZigTest;
    const set = values_of(&main_frame, 0x0F0F_0F0F_0F0F_0F0F);
    fiber_set = values_of(&fiber_frame, 0xF0F0_F0F0_F0F0_F0F0);
    fiber_seen = std.mem.zeroes(Registers);
    fiber_rounds = 0;
    start_fiber(0, registers_fiber);
    for (1..registers_rounds + 1) |round| {
        var seen = std.mem.zeroes(Registers);
        jump_with_registers(&to_fiber, &set, &seen);
        try testing.expectEqual(round, fiber_rounds);
        try expect_kept(&set, &seen);
        // From the second round, the fiber read its own registers after the switch back to it.
        if (round > 1) try expect_kept(&fiber_set, &fiber_seen);
    }
}
