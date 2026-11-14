//! std 0.16.0's context switch on x86_64, with the clobber list of the package, in the two forms
//! that the probe measures beside the switch of the package: a copy and a call. The package does
//! not use this file. `std_switch_x86_64_test.zig` holds its tests.
//!
//! The assembly is std's `fiber.contextSwitch`, instruction for instruction. The list departs from
//! std's in two places: it does not name the message register `rsi` (rotor's decision 22), and it
//! names `xmm0` to `xmm15` beside `zmm0` to `zmm31` (record 2).
//!
//! - `switch_copied` is an inline function, so each caller holds a copy of the switch. The list
//!   then decides what a caller keeps across the switch. The clobber type of Zig 0.16.0 has no
//!   working name for the x87 registers, and no name for `k0` to `k7` or for `r16` to `r31`. So a
//!   copy loses an `f80` value in ReleaseSafe (record 3), and can lose a value in those registers.
//! - `switch_called` is a function that is never inlined, so each caller calls it. The calling
//!   convention then covers each caller-saved register that the list does not cover.
//!
//! The first context and the entry of a new fiber are those of record 4 for x86_64. The argument
//! is in the word below the end of the stack. The first stack pointer is 24 bytes below the end,
//! and the word there is zero, so `main` starts with a return address of zero.
//!
//! The switch saves no control register: the rounding mode and the exception masks belong to the
//! thread (record 3). It needs a process with no shadow stack and no indirect branch tracking of
//! the processor (CET), as the switch of the package does.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const fiber = std.Io.fiber;
const switching = @import("switch");
const stack_end_alignment = switching.stack_end_alignment;
const Main = switching.Main;

/// True where this file has a switch: x86_64 with the System V calling convention.
pub const supported = switching.supported and builtin.cpu.arch == .x86_64;

/// std's context on x86_64: the stack pointer, the frame pointer and the address to resume at.
pub const Context = fiber.Context;

/// std's message of a switch: the context to save into, and the context to resume.
pub const Switch = fiber.Switch;

// The assembly names each field of `Context` and of `Switch` by its offset, as a number. Both types
// are std's. If a Zig upgrade moves a field, the build stops here.
comptime {
    if (supported) {
        assert(@offsetOf(Context, "rsp") == 0);
        assert(@offsetOf(Context, "rbp") == 8);
        assert(@offsetOf(Context, "rip") == 16);
        assert(@sizeOf(Context) == 24);
        assert(@offsetOf(Switch, "old") == 0);
        assert(@offsetOf(Switch, "new") == 8);
        assert(@sizeOf(Switch) == 16);
    }
}

/// The context that a new fiber starts from (record 4). `stack_end` is the address one byte after
/// the stack of the fiber. This function writes `argument` into the word below `stack_end`, and
/// the entry hands that word to `main`. The first stack pointer is 24 bytes below `stack_end`, and
/// the word there is zero. `main` takes that word as its return address, and its stack pointer is
/// then 8 bytes past a multiple of 16, as after a call.
pub fn initial_context(stack_end: usize, argument: usize, comptime main: Main) Context {
    assert(stack_end % stack_end_alignment == 0);
    assert(stack_end != 0);
    const argument_slot: *usize = @ptrFromInt(stack_end - @sizeOf(usize));
    argument_slot.* = argument;
    const stack_pointer = stack_end - stack_end_alignment - @sizeOf(usize);
    const return_slot: *usize = @ptrFromInt(stack_pointer);
    return_slot.* = 0;
    return .{ .rsp = stack_pointer, .rbp = 0, .rip = @intFromPtr(&Entry(main).entry) };
}

/// The entry of a new fiber. It reads the argument from the word below the end of the stack into
/// the first argument register, and jumps to `main`.
fn Entry(comptime main: Main) type {
    return struct {
        fn entry() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile (
                    \\ movq 16(%%rsp), %%rdi
                    \\ jmp %[main:P]
                    :
                    : [main] "X" (&main),
                ),
                else => @compileError("this file holds the switch of x86_64 alone"),
            }
        }
    };
}

/// A function that holds a copy of the switch, and that no caller can copy. A call of it with
/// `.always_inline` does not compile. It has the C calling convention, so its argument is in
/// `rdi`. The test of the message register relies on that.
pub noinline fn switch_called(message: *const Switch) callconv(.c) void {
    switch_copied(message);
}

/// The assembly of the switch. Each caller holds a copy of it, because it is an inline function,
/// and `switch_called` is one such caller.
pub inline fn switch_copied(message: *const Switch) void {
    _ = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const Switch),
            : [message_to_send] "{rsi}" (message),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .xmm0 = true,
              .xmm1 = true,
              .xmm2 = true,
              .xmm3 = true,
              .xmm4 = true,
              .xmm5 = true,
              .xmm6 = true,
              .xmm7 = true,
              .xmm8 = true,
              .xmm9 = true,
              .xmm10 = true,
              .xmm11 = true,
              .xmm12 = true,
              .xmm13 = true,
              .xmm14 = true,
              .xmm15 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        else => @compileError("this file holds the switch of x86_64 alone"),
    };
}

test {
    _ = @import("std_switch_x86_64_test.zig");
}
