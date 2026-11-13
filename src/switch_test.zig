//! The tests of the context switch (rotor's decision 34, "Build order", step 0). They are in a
//! file of their own because they need stacks and contexts that outlive a function. The lint
//! allows such a `var` only in a test file.
//!
//! A fiber here records what it sees in a `var` of this file, and the test checks that `var` on
//! the main context. So no fiber calls `std.testing`, which can need more stack than a fiber has.
//!
//! Each fiber and each test calls the switch in the form of the package, through
//! `switch_in_form`. On aarch64 that form is a copy of the body of `switch_context` in the caller.
//! So a caller can keep a value in a register across the switch, and a test can see a register
//! that the clobber list misses. On x86_64 that form is a call. The test of the message register
//! calls the function itself.
//!
//! `switch_test_registers.zig` holds the test of the callee-saved registers, and
//! `switch_test_floats.zig` holds the test of each floating-point register.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const switching = @import("switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const supported = switching.supported;
const switch_context = switching.switch_context;

const testing = std.testing;

/// Switches with `message`, in the form of the package: `@call` with `call_modifier`.
inline fn switch_in_form(message: *const Switch) void {
    @call(switching.call_modifier, switch_context, .{message});
}

/// Clears the register that the switch takes its message in, `x1` or `rsi`. Then it jumps to the
/// switch with the message in the first argument register. A switch that reads the message
/// register and does not load it first then reads 0, and faults. The first error of std's clobber
/// lists made the optimized build skip that load. A test that called the switch the usual way
/// passed with that error, because the register held a pointer that worked.
fn call_with_message_register_cleared() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ xorl %%esi, %%esi
            \\ jmp %[switch_context:P]
            :
            : [switch_context] "X" (&switch_context),
        ),
        .aarch64 => asm volatile (
            \\ mov x1, xzr
            \\ b %[switch_context]
            :
            : [switch_context] "X" (&switch_context),
        ),
        else => @compileError("no fiber switch for this architecture"),
    }
}

fn switch_with_message_register_cleared(message: *const Switch) void {
    const call: *const fn (*const Switch) callconv(.c) void =
        @ptrCast(&call_with_message_register_cleared);
    call(message);
}

/// Returns the stack pointer that the caller had when it made the call. On x86_64 the call
/// pushed the return address, so the function adds that word back.
fn read_stack_pointer_of_caller() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rax
            \\ retq
        ),
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ ret
        ),
        else => @compileError("no fiber switch for this architecture"),
    }
}

fn stack_pointer_of_caller() usize {
    const call: *const fn () callconv(.c) usize = @ptrCast(&read_stack_pointer_of_caller);
    return call();
}

/// The bytes of the stack of each fiber here. Each fiber runs one small function.
const stack_bytes = 64 * 1024;

/// The bytes above the end of a fiber's stack that one test fills, to show that a fiber writes
/// none of them.
const canary_bytes = 64;

/// The byte that fills them.
const canary: u8 = 0xA5;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var second_stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var second_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;
var returns: usize = 0;

/// Makes `fiber_context` a new fiber that runs `main` with `argument`, on a stack that ends at
/// `stack_end`. It also sets the two messages between that fiber and the main context.
fn start_fiber(stack_end: usize, argument: usize, comptime main: switching.Main) void {
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(stack_end, argument, main);
}

fn end_of(memory: []u8) usize {
    return @intFromPtr(memory.ptr) + memory.len;
}

test "aarch64 and x86_64 each have a switch" {
    switch (builtin.cpu.arch) {
        .aarch64, .x86_64 => try testing.expect(supported),
        else => try testing.expect(!supported),
    }
}

/// It switches back two times, and no context switches to it a third time. So it never reaches
/// its end.
fn twice_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    returns += argument;
    switch_with_message_register_cleared(&to_main);
    returns += 1;
    switch_with_message_register_cleared(&to_main);
    unreachable;
}

test "the switch loads its message from its argument, whatever the message register holds" {
    if (!supported) return error.SkipZigTest;
    returns = 0;
    start_fiber(end_of(&stack), 1, twice_fiber);
    switch_with_message_register_cleared(&to_fiber);
    try testing.expectEqual(1, returns);
    switch_with_message_register_cleared(&to_fiber);
    try testing.expectEqual(2, returns);
}

/// What `first_fiber` saw when it started.
var seen_argument: usize = 0;
var seen_stack_pointer: usize = 0;
var seen_caller_frame: usize = 0;
var seen_frame: usize = 0;
var seen_return_address: usize = 0;

fn first_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    seen_argument = argument;
    seen_return_address = @returnAddress();
    seen_stack_pointer = stack_pointer_of_caller();
    // The first word of a frame holds the frame pointer of the caller.
    seen_frame = @frameAddress();
    const frame: *const usize = @ptrFromInt(seen_frame);
    seen_caller_frame = frame.*;
    switch_in_form(&to_main);
    unreachable;
}

/// The frame pointer that a switch saved in `context`.
fn saved_frame_pointer(context: *const Context) usize {
    return switch (builtin.cpu.arch) {
        .aarch64 => context.fp,
        .x86_64 => context.rbp,
        else => @compileError("no fiber switch for this architecture"),
    };
}

/// The switch back from `first_fiber` saved the frame pointer of the fiber in `fiber_context`.
/// Where the compiler copied the switch into `first_fiber`, that is the frame of `first_fiber`.
/// Where the compiler called the switch, it is the frame of `switch_context`, and the first word
/// of that frame names the frame of `first_fiber`.
fn expect_saved_frame(stack_end: usize) !void {
    const saved = saved_frame_pointer(&fiber_context);
    try testing.expect(seen_frame != 0);
    if (saved == seen_frame) return;
    try testing.expectEqual(0, saved % @alignOf(usize));
    try testing.expect(saved >= @intFromPtr(&stack));
    try testing.expect(saved < stack_end);
    const caller_frame: *const usize = @ptrFromInt(saved);
    try testing.expectEqual(seen_frame, caller_frame.*);
}

test "a new fiber starts with its argument, on an aligned stack that ends at the stack's end" {
    if (!supported) return error.SkipZigTest;
    const argument = 0x0123_4567_89AB_CDEF;
    const stack_end = end_of(&stack) - canary_bytes;
    // The whole stack holds the canary. So a word that `initial_context` does not write is not
    // zero by chance.
    @memset(&stack, canary);
    seen_argument = 0;
    seen_stack_pointer = 0;
    seen_caller_frame = 1;
    seen_frame = 0;
    seen_return_address = 1;
    start_fiber(stack_end, argument, first_fiber);
    switch_in_form(&to_fiber);

    try testing.expectEqual(argument, seen_argument);
    // The compiler keeps the alignment that the function had at its entry. So an aligned stack
    // pointer at a call shows an aligned stack pointer at the entry.
    try testing.expectEqual(0, seen_stack_pointer % stack_end_alignment);
    try testing.expect(seen_stack_pointer > @intFromPtr(&stack));
    try testing.expect(seen_stack_pointer <= stack_end);
    // The first frame of a fiber names no frame of a caller, and no return address (record 4). So
    // a stack trace from a fiber ends at this frame.
    try testing.expectEqual(0, seen_caller_frame);
    try testing.expectEqual(0, seen_return_address);
    try expect_saved_frame(stack_end);
    // The fiber wrote no byte at its stack's end or above it.
    for (stack[stack_bytes - canary_bytes ..]) |byte| try testing.expectEqual(canary, byte);
}

/// The switches that one test makes to a fiber, one after the other.
const switches_in_a_row = 100_000;

/// It counts each time that it runs, through the pointer that it got as its argument.
fn counting_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const count: *usize = @ptrFromInt(argument);
    for (0..switches_in_a_row) |_| {
        count.* += 1;
        switch_in_form(&to_main);
    }
    unreachable;
}

test "a fiber runs one time for each of many switches in a row" {
    if (!supported) return error.SkipZigTest;
    var count: usize = 0;
    start_fiber(end_of(&stack), @intFromPtr(&count), counting_fiber);
    // `sum` lives across each switch on the main context, as `count` does on the fiber.
    var sum: usize = 0;
    for (1..switches_in_a_row + 1) |round| {
        switch_in_form(&to_fiber);
        try testing.expectEqual(round, count);
        sum += count;
    }
    try testing.expectEqual(switches_in_a_row * (switches_in_a_row + 1) / 2, sum);
}

/// What the main context and a fiber pass to each other.
const Mail = struct {
    to_fiber: usize = 0,
    to_main: usize = 0,
    half_to_main: f64 = 0,
};

/// The rounds of the test that passes a value each way.
const mail_rounds = 64;

/// It adds each value that the main context sends to a sum, and sends the sum back with the
/// number of the round. The sum and the round are locals. So they live on the fiber's stack, or
/// in its registers, across each switch.
fn replying_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const mail: *Mail = @ptrFromInt(argument);
    var sum: usize = 0;
    for (0..mail_rounds) |round| {
        sum += mail.to_fiber;
        mail.to_main = sum + round;
        switch_in_form(&to_main);
    }
    unreachable;
}

test "a value passes each way across a switch, and a fiber keeps its locals" {
    if (!supported) return error.SkipZigTest;
    var mail: Mail = .{};
    start_fiber(end_of(&stack), @intFromPtr(&mail), replying_fiber);
    var sum: usize = 0;
    for (0..mail_rounds) |round| {
        const value = 3 * round + 7;
        mail.to_fiber = value;
        switch_in_form(&to_fiber);
        sum += value;
        try testing.expectEqual(sum + round, mail.to_main);
    }
}

/// It adds half of each value that the main context sends to a floating-point sum, and sends
/// the sum back. The sum is a local. So it lives on the fiber's stack, or in a floating-point
/// register, across each switch.
fn halving_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const mail: *Mail = @ptrFromInt(argument);
    var half_sum: f64 = 0;
    for (0..mail_rounds) |_| {
        half_sum += @as(f64, @floatFromInt(mail.to_fiber)) / 2;
        mail.half_to_main = half_sum;
        switch_in_form(&to_main);
    }
    unreachable;
}

test "the main context and a fiber each keep a floating-point value across a switch" {
    if (!supported) return error.SkipZigTest;
    var mail: Mail = .{};
    start_fiber(end_of(&stack), @intFromPtr(&mail), halving_fiber);
    var half_sum: f64 = 0;
    for (0..mail_rounds) |round| {
        const value = 3 * round + 7;
        mail.to_fiber = value;
        switch_in_form(&to_fiber);
        half_sum += @as(f64, @floatFromInt(value)) / 2;
        // Half of an integer is exact in an `f64`, so the two sums are equal bit for bit.
        try testing.expectEqual(half_sum, mail.half_to_main);
    }
}

/// What the test of the condition flags keeps on each side of a switch. The test reads and
/// writes each field through a volatile pointer, so the compiler keeps the order of the reads
/// and writes.
const FlagsMail = struct {
    left: u64 = 0,
    right: u64 = 0,
    low: u64 = 0,
    high: u64 = 0,
    before: u64 = 0,
    after: u64 = 0,
    fiber_left: u64 = 0,
    fiber_right: u64 = 0,
    fiber_before: u64 = 0,
    fiber_after: u64 = 0,
};

/// The two values that a comparison chooses between.
const flags_low = 111;
const flags_high = 999;

/// It compares its own two values. It uses the result one time before its switch and one time
/// after it, as `flags_round` does on the main context.
fn flags_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const mail: *volatile FlagsMail = @ptrFromInt(argument);
    for (0..mail_rounds) |_| {
        const left = mail.fiber_left;
        const right = mail.fiber_right;
        const low_before = mail.low;
        const high_before = mail.high;
        const less = left < right;
        mail.fiber_before = if (less) low_before else high_before;
        switch_in_form(&to_main);
        const low = mail.low;
        const high = mail.high;
        mail.fiber_after = if (less) low else high;
    }
    unreachable;
}

/// One round of the main context. It compares its two values. It uses the result one time before
/// the switch and one time after it. The comparison, the switch and both uses are in this one
/// function, so the compiler can keep the flags of the comparison across the switch.
///
/// The assembly of the switch changes no flag, and the context that runs in between does. On
/// x86_64 the compiler takes each block of assembly as a change of the flags. On aarch64 the list
/// must name `nzcv` (record 3). With no `nzcv`, this test failed in ReleaseSafe on aarch64 macOS
/// and on aarch64 Linux.
noinline fn flags_round(mail: *volatile FlagsMail) void {
    const left = mail.left;
    const right = mail.right;
    const low_before = mail.low;
    const high_before = mail.high;
    const less = left < right;
    mail.before = if (less) low_before else high_before;
    switch_in_form(&to_fiber);
    const low = mail.low;
    const high = mail.high;
    mail.after = if (less) low else high;
}

test "a comparison before a switch decides the same way after the switch" {
    if (!supported) return error.SkipZigTest;
    var storage: FlagsMail = .{};
    const mail: *volatile FlagsMail = &storage;
    start_fiber(end_of(&stack), @intFromPtr(mail), flags_fiber);
    mail.low = flags_low;
    mail.high = flags_high;
    for (0..mail_rounds) |round| {
        // In an even round the main context compares 1 with 2, and the fiber compares 2 with 1.
        // In an odd round each one compares the other way. So in each round the flags of the
        // one are wrong for the other.
        mail.left = 1 + round % 2;
        mail.right = 2 - round % 2;
        mail.fiber_left = mail.right;
        mail.fiber_right = mail.left;
        flags_round(mail);
        const expected: u64 = if (round % 2 == 0) flags_low else flags_high;
        try testing.expectEqual(expected, mail.before);
        try testing.expectEqual(expected, mail.after);
        // From the second round, the fiber ran the code after its own switch. That code used the
        // comparison of the round before, which went the way of the main context in this round.
        if (round > 0) try testing.expectEqual(expected, mail.fiber_after);
    }
}

/// What the main context and a fiber pass to each other in the test of an `f80` value.
///
/// On x86_64 the compiler computes an `f80` value in the x87 registers, and the clobber list
/// covers none of them. With a copy of the switch in the caller, this test failed in ReleaseSafe
/// on x86_64 Linux, under Rosetta. The switch is a call there (record 3), and the calling
/// convention covers those registers.
const ExtendedMail = struct {
    to_fiber: usize = 0,
    half_to_main: f80 = 0,
};

/// It does what `halving_fiber` does, with an `f80` sum.
fn extended_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    const mail: *ExtendedMail = @ptrFromInt(argument);
    var half_sum: f80 = 0;
    for (0..mail_rounds) |_| {
        half_sum += @as(f80, @floatFromInt(mail.to_fiber)) / 2;
        mail.half_to_main = half_sum;
        switch_in_form(&to_main);
    }
    unreachable;
}

test "the main context and a fiber each keep an f80 value across a switch" {
    if (!supported) return error.SkipZigTest;
    var mail: ExtendedMail = .{};
    start_fiber(end_of(&stack), @intFromPtr(&mail), extended_fiber);
    var half_sum: f80 = 0;
    for (0..mail_rounds) |round| {
        const value = 3 * round + 7;
        mail.to_fiber = value;
        switch_in_form(&to_fiber);
        half_sum += @as(f80, @floatFromInt(value)) / 2;
        // Half of an integer is exact in an `f80`, so the two sums are equal bit for bit.
        try testing.expectEqual(half_sum, mail.half_to_main);
    }
}

/// The order in which three contexts ran: one letter for each time that a context ran.
const order_max = 8;
var order: [order_max]u8 = @splat(0);
var order_len: usize = 0;

fn note(letter: u8) void {
    assert(order_len < order_max);
    order[order_len] = letter;
    order_len += 1;
}

var first_to_second: Switch align(@alignOf(Switch)) = undefined;
var first_to_main: Switch align(@alignOf(Switch)) = undefined;
var second_to_main: Switch align(@alignOf(Switch)) = undefined;
var second_to_first: Switch align(@alignOf(Switch)) = undefined;

fn relay_first(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    note(@intCast(argument));
    switch_in_form(&first_to_second);
    note(@intCast(argument));
    switch_in_form(&first_to_main);
    unreachable;
}

fn relay_second(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    note(@intCast(argument));
    switch_in_form(&second_to_main);
    note(@intCast(argument));
    switch_in_form(&second_to_first);
    unreachable;
}

test "a switch saves the context that its message names, and resumes the other, with three" {
    if (!supported) return error.SkipZigTest;
    order_len = 0;
    fiber_context = initial_context(end_of(&stack), 'a', relay_first);
    second_context = initial_context(end_of(&second_stack), 'b', relay_second);
    first_to_second = .{ .old = &fiber_context, .new = &second_context };
    first_to_main = .{ .old = &fiber_context, .new = &main_context };
    second_to_main = .{ .old = &second_context, .new = &main_context };
    second_to_first = .{ .old = &second_context, .new = &fiber_context };
    const main_to_first: Switch = .{ .old = &main_context, .new = &fiber_context };
    const main_to_second: Switch = .{ .old = &main_context, .new = &second_context };

    // The main context starts the first fiber, which starts the second, which comes back here.
    note('m');
    switch_in_form(&main_to_first);
    // The second fiber resumes after its own switch, and it resumes the first after its switch.
    note('m');
    switch_in_form(&main_to_second);
    note('m');
    try testing.expectEqualStrings("mabmbam", order[0..order_len]);
}

test {
    _ = @import("switch_test_registers.zig");
    _ = @import("switch_test_floats.zig");
    _ = @import("switch_test_entry.zig");
}
