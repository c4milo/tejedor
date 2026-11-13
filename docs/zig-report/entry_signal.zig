//! The first context and the entry of std's `Kqueue` idle fiber, on aarch64, with one signal that
//! arrives at the first stack pointer of the fiber, before the entry reads its argument.
//!
//!     zig build-exe entry_signal.zig -target aarch64-linux-musl -O ReleaseSafe
//!     ./entry_signal; echo "exit status $?"
//!
//! `std.Io.Kqueue` does not compile in Zig 0.16.0, and std uses it only on the BSDs. So this
//! program copies its entry and its first context, and switches with std's own
//! `std.Io.fiber.contextSwitch`:
//!
//! - `Kqueue.init`, std/Io/Kqueue.zig:193-201, writes the argument into the word below the end
//!   of the idle stack, and sets the stack pointer to the end of the stack.
//! - `Kqueue.mainIdleEntry`, std/Io/Kqueue.zig:541-556, reads the argument with
//!   `ldr x0, [sp, #-8]`: 8 bytes below the stack pointer.
//!
//! A step of this program runs at the first stack pointer and sends SIGUSR1 to its own thread
//! with a system call. Then it jumps to the entry. So the handler runs on the fiber's stack at
//! that stack pointer each time, with no race.
const std = @import("std");
const builtin = @import("builtin");
const fiber = std.Io.fiber;

comptime {
    if (builtin.cpu.arch != .aarch64) @compileError("aarch64 only");
}

const argument_sent: usize = 0x5A5A_0000_1234_5678;

var stack: [64 * 1024]u8 align(16) = undefined;
var main_context: fiber.Context align(@alignOf(fiber.Context)) = undefined;
var step_context: fiber.Context align(@alignOf(fiber.Context)) = undefined;
var to_step: fiber.Switch align(@alignOf(fiber.Switch)) = undefined;
var to_main: fiber.Switch align(@alignOf(fiber.Switch)) = undefined;
var handled: usize = 0;
var seen_argument: usize = 0;

/// The text of std's `Kqueue.mainIdleEntry` for aarch64, with `mainIdle` replaced.
fn main_idle_entry() callconv(.naked) void {
    asm volatile (
        \\ ldr x0, [sp, #-8]
        \\ b %[mainIdle]
        :
        : [mainIdle] "X" (&main_idle),
    );
}

/// The corrected entry: the argument is 8 bytes above the first stack pointer.
fn fixed_entry() callconv(.naked) void {
    asm volatile (
        \\ ldr x0, [sp, #8]
        \\ mov lr, xzr
        \\ b %[mainIdle]
        :
        : [mainIdle] "X" (&main_idle),
    );
}

fn main_idle(argument: usize) callconv(.c) noreturn {
    seen_argument = argument;
    switch_to(&to_main);
    unreachable;
}

/// std's switch, in a function of its own.
fn switch_function(s: *const fiber.Switch) callconv(.c) void {
    _ = fiber.contextSwitch(s);
}

/// It puts the message in x1 and jumps to `switch_function`. So x1 holds the message at the
/// switch, whatever an optimized build does with std's clobber list (the first issue of the
/// report). The program then tests the entry alone.
fn switch_trampoline() callconv(.naked) void {
    asm volatile (
        \\ mov x1, x0
        \\ b %[target]
        :
        : [target] "X" (&switch_function),
    );
}

fn switch_to(s: *const fiber.Switch) void {
    const call: *const fn (*const fiber.Switch) callconv(.c) void = @ptrCast(&switch_trampoline);
    call(s);
}

fn on_signal(_: std.posix.SIG) callconv(.c) void {
    handled += 1;
}

/// It runs at the first stack pointer, with the address of the entry in the frame pointer. It
/// sends SIGUSR1 to its own thread and jumps to the entry.
fn signal_then_enter() callconv(.naked) noreturn {
    switch (builtin.os.tag) {
        // getpid is 172, gettid is 178, tgkill is 131, SIGUSR1 is 10.
        .linux => asm volatile (
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
        // getpid is 20, kill is 37, SIGUSR1 is 30. The third argument of kill asks for POSIX
        // behaviour.
        .macos => asm volatile (
            \\ mov x9, x29
            \\ mov x29, xzr
            \\ mov x16, #20
            \\ svc #0x80
            \\ mov x1, #30
            \\ mov x2, #1
            \\ mov x16, #37
            \\ svc #0x80
            \\ br x9
        ),
        else => @compileError("Linux and macOS only"),
    }
}

/// With the argument `fixed`, the program uses the corrected entry, and a first stack pointer 16
/// bytes below the end of the stack.
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(std.heap.page_allocator);
    const fixed = args.len == 2 and std.mem.eql(u8, args[1], "fixed");
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = on_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.USR1, &action, null);

    // The first context, as `Kqueue.init` makes it.
    const idle_stack_end: [*]align(16) usize = @ptrCast(@alignCast(stack[stack.len..].ptr));
    (idle_stack_end - 1)[0..1].* = .{argument_sent};
    const idle_context: fiber.Context = if (fixed) .{
        .sp = @intFromPtr(idle_stack_end - 2),
        .fp = 0,
        .pc = @intFromPtr(&fixed_entry),
    } else .{
        .sp = @intFromPtr(idle_stack_end),
        .fp = 0,
        .pc = @intFromPtr(&main_idle_entry),
    };
    // The step starts at the same stack pointer, and holds the entry in its frame pointer.
    step_context = .{ .sp = idle_context.sp, .fp = idle_context.pc, .pc = @intFromPtr(&signal_then_enter) };
    var idle_context_storage = idle_context;
    to_step = .{ .old = &main_context, .new = &step_context };
    to_main = .{ .old = &idle_context_storage, .new = &main_context };
    switch_to(&to_step);

    std.debug.print("handler ran {d} time(s); argument sent 0x{x}, argument seen 0x{x}: {s}\n", .{
        handled,
        argument_sent,
        seen_argument,
        if (seen_argument == argument_sent) "PASS" else "FAIL",
    });
    if (seen_argument != argument_sent) std.process.exit(1);
}
