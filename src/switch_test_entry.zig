//! The test of the first stack of a new fiber under a signal (records 4 and 6). It runs on Linux
//! alone.
//!
//! A signal handler runs on the stack that the thread has when the signal arrives, and the kernel
//! writes its frame below the stack pointer. On aarch64 Linux that frame starts at the word below
//! the stack pointer. An entry that reads its argument there can read a word of the kernel.
//! Record 4 puts the argument above the first stack pointer for that reason.
//!
//! The test starts a fiber through a step of its own, which runs on the fiber's stack before the
//! fiber has run. The step sends one SIGUSR1 to its own thread with system calls, and then it goes
//! on to the start of the fiber. So the handler runs on that stack each time, with no race.
//!
//! - On aarch64 the step, `signal_then_enter`, runs at the first stack pointer of the fiber, and
//!   then jumps to the entry.
//! - On x86_64 the first stack of the jump holds seven words that the jump pops (record 6). The
//!   step, `signal_then_resume`, moves the stack pointer to the first of them. That is where the
//!   jump puts it before its pops. Then the step makes the same pops and the same jump. The words
//!   of the step are in a static of the test, so nothing but the kernel writes below the first
//!   stack pointer of the fiber.
//!
//! On aarch64 macOS a program of the review sent itself the same signal before the old entry, and
//! the fiber got its argument. The test does not run there, because it makes system calls of
//! Linux. The kernel of x86_64 leaves 128 bytes below the stack pointer to the code that runs,
//! which the session recalled and did not read. So on x86_64 a word just below the stack pointer
//! is safe. Under Rosetta this test passed with the argument 8 or 1,024 bytes below the first
//! stack pointer of the jump. It failed with the argument 5,600 bytes below (record 6). The test
//! of the first stack in `switch_test_start.zig` catches each of the three.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const switching = @import("switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const switch_context = switching.switch_context;
const JumpWords = @import("switch_test.zig").JumpWords;

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
var step_words: JumpWords align(@alignOf(JumpWords)) = undefined;

// The steps below name their system calls by number. These asserts hold each number to std's.
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

/// On aarch64 it runs at the first stack pointer of the fiber, with the address of the entry in the
/// frame pointer, where the test put it. It clears the frame pointer, sends SIGUSR1 to its own
/// thread with `tgkill`, and jumps to the entry. A system call leaves each register that it uses
/// here.
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
        else => @compileError("this step is for aarch64 alone"),
    }
}

/// On x86_64 the jump popped the fiber's first stack pointer into `r12`, where the test put it.
/// The step moves the stack pointer there, and sends SIGUSR1 to its own thread with `tgkill`.
/// Then it pops the six registers and the address to resume at, as the jump does, and jumps to
/// that address. A system call changes no register that the pops load.
fn signal_then_resume() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq %%r12, %%rsp
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
            \\ popq %%r15
            \\ popq %%r14
            \\ popq %%r13
            \\ popq %%r12
            \\ popq %%rbx
            \\ popq %%rbp
            \\ popq %%rcx
            \\ jmpq *%%rcx
        ),
        else => @compileError("this step is for x86_64 alone"),
    }
}

fn entry_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    seen_argument = argument;
    switch_context(&to_main);
    unreachable;
}

/// The context of the step.
///
/// - On aarch64 its stack pointer is the one of the fiber's first context. Its frame pointer holds
///   the address of the fiber's entry, and it resumes at the step.
/// - On x86_64 its stack pointer names `step_words`, which the jump pops. Their `r12` holds the
///   fiber's first stack pointer, and the address to resume at is the step. The other words are
///   zero.
fn step_of(first: *const Context) Context {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const step = @intFromPtr(&signal_then_enter);
            return .{ .sp = first.sp, .fp = first.pc, .pc = step };
        },
        .x86_64 => {
            step_words = std.mem.zeroes(JumpWords);
            step_words.r12 = first.stack_pointer;
            step_words.resume_address = @intFromPtr(&signal_then_resume);
            return .{ .stack_pointer = @intFromPtr(&step_words) };
        },
        else => @compileError("no fiber switch for this architecture"),
    }
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
    switch_context(&to_step);

    // The handler ran one time, on the fiber's stack, before the fiber started.
    try testing.expectEqual(1, handled);
    try testing.expectEqual(argument_sent, seen_argument);
}
