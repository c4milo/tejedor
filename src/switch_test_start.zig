//! The tests of the first context of a new fiber (records 4 and 6). They need a stack and contexts
//! that outlive a function, so they are in a file of their own, as the other tests of the switch
//! are (`switch_test.zig`).
//!
//! On aarch64 the first context is std's, with the entry of record 4. On x86_64 it is the first
//! stack of the jump (`switch_jump.zig`). On both, `main` starts with its argument, a return
//! address of zero, a frame pointer of zero, and an aligned stack. So a walk of the frame pointers
//! from a fiber, which is how a stack trace reads the frames, ends at the frame of `main`.
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

/// The bytes of the stack of each fiber here.
const stack_bytes = 64 * 1024;

/// The bytes above the end of a fiber's stack that one test fills, to show that a fiber writes
/// none of them.
const canary_bytes = 64;

/// The byte that fills them.
const canary: u8 = 0xA5;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;

/// Makes `fiber_context` a new fiber that runs `main` with `argument`, on a stack that ends at
/// `stack_end`. It also sets the two messages between that fiber and the main context.
fn start_fiber(stack_end: usize, argument: usize, comptime main: switching.Main) void {
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(stack_end, argument, main);
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
    switch_context(&to_main);
    unreachable;
}

/// The stack pointer of `context` while it does not run.
fn stack_pointer_of(context: *const Context) usize {
    return switch (builtin.cpu.arch) {
        .aarch64 => context.sp,
        .x86_64 => context.stack_pointer,
        else => @compileError("no fiber switch for this architecture"),
    };
}

/// The frame pointer that a switch saved for `context`. On aarch64 the copy of the switch saves it
/// in the context. On x86_64 the jump pushes it on the stack of the context.
fn saved_frame_pointer(context: *const Context) usize {
    return switch (builtin.cpu.arch) {
        .aarch64 => context.fp,
        .x86_64 => jump_words(context).rbp,
        else => @compileError("no fiber switch for this architecture"),
    };
}

test "a new fiber starts with its argument, on an aligned stack that ends at the stack's end" {
    if (!supported) return error.SkipZigTest;
    const argument = 0x0123_4567_89AB_CDEF;
    const stack_end = @intFromPtr(&stack) + stack_bytes - canary_bytes;
    // The whole stack holds the canary. So a word that `initial_context` does not write is not
    // zero by chance.
    @memset(&stack, canary);
    seen_argument = 0;
    seen_stack_pointer = 0;
    seen_caller_frame = 1;
    seen_frame = 0;
    seen_return_address = 1;
    start_fiber(stack_end, argument, first_fiber);
    // `initial_context` wrote no byte below the first stack pointer. A signal handler can write
    // there before the fiber runs, so each word that the fiber needs is at or above it (record 4).
    const first = stack_pointer_of(&fiber_context);
    for (stack[0 .. first - @intFromPtr(&stack)]) |byte| try testing.expectEqual(canary, byte);
    switch_context(&to_fiber);

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
    // The switch back saved the frame pointer of `first_fiber`: a copy holds it in its register,
    // and the jump pushes the register that its caller left.
    try testing.expect(seen_frame != 0);
    try testing.expectEqual(seen_frame, saved_frame_pointer(&fiber_context));
    // The fiber wrote no byte at its stack's end or above it.
    for (stack[stack_bytes - canary_bytes ..]) |byte| try testing.expectEqual(canary, byte);
}

/// The most frames that a walk reads. A fiber of the test below has two.
const frames_max = 8;

/// What `walk_frames` read: the return address of each frame, from its own frame up, the count of
/// the frames, and the frame pointer that stopped the walk.
var walked_returns: [frames_max]usize = @splat(1);
var walked_count: usize = 0;
var walked_end: usize = 1;

/// Walks the frame pointers from its own frame, and records the return address of each frame. A
/// frame holds the frame pointer of its caller in its first word, and its return address in the
/// second, on both architectures. The walk stops at a frame pointer of zero.
noinline fn walk_frames() void {
    walked_count = 0;
    var frame_pointer = @frameAddress();
    while (frame_pointer != 0 and walked_count < frames_max) : (walked_count += 1) {
        const frame: *const [2]usize = @ptrFromInt(frame_pointer);
        walked_returns[walked_count] = frame[1];
        frame_pointer = frame[0];
    }
    walked_end = frame_pointer;
}

fn tracing_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    walk_frames();
    switch_context(&to_main);
    unreachable;
}

/// The most bytes from the start of `tracing_fiber` to the return address of its call of
/// `walk_frames`.
const function_bytes_max = 4096;

test "a walk of the frame pointers from a fiber ends at the frame of its main" {
    if (!supported) return error.SkipZigTest;
    walked_returns = @splat(1);
    walked_count = 0;
    walked_end = 1;
    start_fiber(@intFromPtr(&stack) + stack_bytes, 0, tracing_fiber);
    switch_context(&to_fiber);

    // Two frames: the frame of `walk_frames`, which returns into `tracing_fiber`, and the frame
    // of `tracing_fiber`, whose return address is zero. The frame pointer above them is zero.
    try testing.expectEqual(2, walked_count);
    try testing.expectEqual(0, walked_end);
    const main_start = @intFromPtr(&tracing_fiber);
    try testing.expect(walked_returns[0] > main_start);
    try testing.expect(walked_returns[0] - main_start < function_bytes_max);
    try testing.expectEqual(0, walked_returns[1]);
}
