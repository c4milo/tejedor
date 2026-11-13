//! A panic in a fiber that starts with the first context and the entry of std's `Kqueue` idle
//! fiber, or with the corrected entry. It switches with std's own `std.Io.fiber.contextSwitch`.
//!
//!     zig build-exe halt_in_fiber.zig -O ReleaseSafe
//!     ./halt_in_fiber std; echo "exit status $?"
//!     ./halt_in_fiber fixed; echo "exit status $?"
//!
//! `std`: the text of `Kqueue.mainIdleEntry` and the context of `Kqueue.init`
//! (std/Io/Kqueue.zig:193-207 and 541-556). On aarch64 the entry leaves the link register as the
//! other context left it. On x86_64 the argument is in the word that `main` takes as its return
//! address.
//!
//! `fixed`: the argument is in the word below the end of the stack, above the first stack
//! pointer. On aarch64 the entry clears the link register. On x86_64 the word at the first stack
//! pointer is zero.
//!
//! Expected: the trace ends at `fiber_main`, and the process ends with SIGABRT (status 134).
const std = @import("std");
const builtin = @import("builtin");
const fiber = std.Io.fiber;

const argument_sent: usize = 0x5A5A_0000_1234_5678;

/// With 64 KiB, a panic in a Debug build on aarch64 Linux ended with SIGSEGV before it printed a
/// frame, with either entry.
var stack: [1024 * 1024]u8 align(16) = undefined;
var main_context: fiber.Context align(@alignOf(fiber.Context)) = undefined;
var fiber_context: fiber.Context align(@alignOf(fiber.Context)) = undefined;
var to_fiber: fiber.Switch align(@alignOf(fiber.Switch)) = undefined;

noinline fn halt_here(argument: usize) noreturn {
    std.debug.panic("a panic in a fiber, argument 0x{x}", .{argument});
}

fn fiber_main(argument: usize) callconv(.c) noreturn {
    halt_here(argument);
}

/// The text of std's `Kqueue.mainIdleEntry`, with `mainIdle` replaced.
fn std_entry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq (%%rsp), %%rdi
            \\ jmp %[mainIdle:P]
            :
            : [mainIdle] "X" (&fiber_main),
        ),
        .aarch64 => asm volatile (
            \\ ldr x0, [sp, #-8]
            \\ b %[mainIdle]
            :
            : [mainIdle] "X" (&fiber_main),
        ),
        else => @compileError("aarch64 and x86_64 only"),
    }
}

/// The corrected entry.
fn fixed_entry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq 16(%%rsp), %%rdi
            \\ jmp %[main:P]
            :
            : [main] "X" (&fiber_main),
        ),
        .aarch64 => asm volatile (
            \\ ldr x0, [sp, #8]
            \\ mov lr, xzr
            \\ b %[main]
            :
            : [main] "X" (&fiber_main),
        ),
        else => @compileError("aarch64 and x86_64 only"),
    }
}

/// std's switch, in a function of its own.
fn switch_function(s: *const fiber.Switch) callconv(.c) void {
    _ = fiber.contextSwitch(s);
}

/// It copies the message into the register that std's switch reads, and jumps to
/// `switch_function`. So the first issue of the report does not change this program.
fn switch_trampoline() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq %%rdi, %%rsi
            \\ jmp %[target:P]
            :
            : [target] "X" (&switch_function),
        ),
        .aarch64 => asm volatile (
            \\ mov x1, x0
            \\ b %[target]
            :
            : [target] "X" (&switch_function),
        ),
        else => @compileError("aarch64 and x86_64 only"),
    }
}

fn switch_to(s: *const fiber.Switch) void {
    const call: *const fn (*const fiber.Switch) callconv(.c) void = @ptrCast(&switch_trampoline);
    call(s);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(std.heap.page_allocator);
    const fixed = args.len == 2 and std.mem.eql(u8, args[1], "fixed");
    const end: [*]align(16) usize = @ptrCast(@alignCast(stack[stack.len..].ptr));
    (end - 1)[0] = argument_sent;
    if (!fixed) {
        fiber_context = switch (builtin.cpu.arch) {
            .aarch64 => .{ .sp = @intFromPtr(end), .fp = 0, .pc = @intFromPtr(&std_entry) },
            .x86_64 => .{ .rsp = @intFromPtr(end - 1), .rbp = 0, .rip = @intFromPtr(&std_entry) },
            else => unreachable,
        };
    } else {
        fiber_context = switch (builtin.cpu.arch) {
            .aarch64 => .{ .sp = @intFromPtr(end - 2), .fp = 0, .pc = @intFromPtr(&fixed_entry) },
            .x86_64 => context: {
                (end - 3)[0] = 0;
                break :context .{ .rsp = @intFromPtr(end - 3), .rbp = 0, .rip = @intFromPtr(&fixed_entry) };
            },
            else => unreachable,
        };
    }
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    switch_to(&to_fiber);
    unreachable;
}
