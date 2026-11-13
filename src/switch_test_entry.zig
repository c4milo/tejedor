//! The test of the first stack of a new fiber under a signal (record 4). It runs on Linux alone.
//!
//! A signal handler runs on the stack that the thread has when the signal arrives, and the kernel
//! writes its frame below the stack pointer. On aarch64 Linux that frame starts at the word below
//! the stack pointer. An entry that reads its argument there can read a word of the kernel.
//! Record 4 puts the argument above the first stack pointer for that reason.
//!
//! The test starts a fiber through a step of its own, `signal_then_enter`, which runs at the
//! first stack pointer of the fiber. The step sends one SIGUSR1 to its own thread, and then it
//! jumps to the entry. So the handler runs at the first stack pointer each time, with no race.
//!
//! On aarch64 macOS a program of the review sent itself the same signal before the old entry, and
//! the fiber got its argument. The test does not run there, because it makes system calls of
//! Linux. On x86_64 the old entry read its argument at the stack pointer, and not below it. So
//! the test runs on x86_64 Linux too, and it passes with either entry there.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const switching = @import("switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const switch_context = switching.switch_context;

const testing = std.testing;

/// The bytes of the fiber's stack. The kernel puts a signal frame of some kilobytes on it.
const stack_bytes = 64 * 1024;

/// The argument that the fiber must get.
const argument_sent = 0x5A5A_0000_1234_5678;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var step_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_step: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;
var handled: usize = 0;
var seen_argument: usize = 0;

// The step below names its system calls by number. These asserts hold each number to std's.
comptime {
    if (builtin.os.tag == .linux) {
        const numbers: [4]usize = switch (builtin.cpu.arch) {
            .aarch64 => .{ 172, 178, 131, 10 },
            .x86_64 => .{ 39, 186, 234, 10 },
            else => .{ 0, 0, 0, 0 },
        };
        if (switching.supported) {
            std.debug.assert(@intFromEnum(linux.SYS.getpid) == numbers[0]);
            std.debug.assert(@intFromEnum(linux.SYS.gettid) == numbers[1]);
            std.debug.assert(@intFromEnum(linux.SYS.tgkill) == numbers[2]);
            std.debug.assert(@intFromEnum(linux.SIG.USR1) == numbers[3]);
        }
    }
}

fn on_signal(_: linux.SIG) callconv(.c) void {
    handled += 1;
}

/// It runs at the first stack pointer of the fiber, with the address of the entry in the frame
/// pointer, where the test put it. It clears the frame pointer, sends SIGUSR1 to its own thread
/// with `tgkill`, and jumps to the entry. A system call leaves each register that it uses here.
fn signal_then_enter() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x9, x29
            \\ mov x29, xzr
            \\ mov x8, #172
            \\ svc #0
            \\ mov x10, x0
            \\ mov x8, #178
            \\ svc #0
            \\ mov x1, x0
            \\ mov x0, x10
            \\ mov x2, #10
            \\ mov x8, #131
            \\ svc #0
            \\ br x9
        ),
        .x86_64 => asm volatile (
            \\ movq %%rbp, %%r12
            \\ xorl %%ebp, %%ebp
            \\ movl $39, %%eax
            \\ syscall
            \\ movl %%eax, %%r13d
            \\ movl $186, %%eax
            \\ syscall
            \\ movl %%eax, %%esi
            \\ movl %%r13d, %%edi
            \\ movl $10, %%edx
            \\ movl $234, %%eax
            \\ syscall
            \\ jmpq *%%r12
        ),
        else => @compileError("no fiber switch for this architecture"),
    }
}

fn entry_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    seen_argument = argument;
    @call(switching.call_modifier, switch_context, .{&to_main});
    unreachable;
}

/// The context of the step. Its stack pointer is the one of the fiber's first context. Its frame
/// pointer holds the address of the fiber's entry, and it resumes at the step.
fn step_of(first: *const Context) Context {
    const step = @intFromPtr(&signal_then_enter);
    return switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = first.sp, .fp = first.pc, .pc = step },
        .x86_64 => .{ .rsp = first.rsp, .rbp = first.rip, .rip = step },
        else => @compileError("no fiber switch for this architecture"),
    };
}

test "a new fiber gets its argument when a signal arrives at its first stack pointer" {
    if (builtin.os.tag != .linux or !switching.supported) return error.SkipZigTest;
    const action: linux.Sigaction = .{
        .handler = .{ .handler = on_signal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    var before: linux.Sigaction = undefined;
    try testing.expectEqual(0, linux.sigaction(.USR1, &action, &before));
    defer _ = linux.sigaction(.USR1, &before, null);

    handled = 0;
    seen_argument = 0;
    fiber_context = initial_context(@intFromPtr(&stack) + stack_bytes, argument_sent, entry_fiber);
    step_context = step_of(&fiber_context);
    to_step = .{ .old = &main_context, .new = &step_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    @call(switching.call_modifier, switch_context, .{&to_step});

    // The handler ran one time, on the fiber's stack, before the entry read the argument.
    try testing.expectEqual(1, handled);
    try testing.expectEqual(argument_sent, seen_argument);
}
