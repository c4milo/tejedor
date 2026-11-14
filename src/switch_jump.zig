//! The context switch of a fiber on x86_64, and the first stack of a new fiber there (record 6).
//! `switch.zig` is the entry of the switch, and this file is a piece of it. Camilo ruled on
//! 2026-11-14 that this switch, the jump, replaces the call of std's switch on x86_64. It was the
//! candidate of record 5, under `bench/` alone.
//!
//! The design is the design of Boost.Context's `jump_fcontext` for x86-64 System V, in
//! `jump_x86_64_sysv_elf_gas.S`. This file holds no code of Boost, and no code of std:
//!
//! 1. A caller calls `jump_switch`, a function in assembly, as a C function. The call pushes the
//!    address to resume at.
//! 2. The function pushes the six callee-saved registers of System V: `rbp`, `rbx` and `r12` to
//!    `r15`.
//! 3. It saves the stack pointer in the context that it leaves, and loads the stack pointer of the
//!    context that it resumes.
//! 4. It pops the six registers of that context, and then the address to resume at. It jumps to
//!    that address with `jmp`, and not with `ret`.
//!
//! So a context is one word, its stack pointer, and its stack holds the rest. Each caller calls
//! `jump_switch`, so the calling convention covers each caller-saved register. The x87 registers,
//! `xmm0` to `xmm31`, `k0` to `k7` and `r16` to `r31` are caller-saved. The function is assembly
//! and has no clobber list, so no name of the clobber type of Zig is needed.
//!
//! Boost's function also saves MXCSR and the x87 control word. This one does not: the rounding
//! mode and the exception masks belong to the thread (record 3).
//!
//! This file holds assembly in two naked functions, and raw pointers to the words of a stack. So
//! `docs/hot-path-ledger.md` names this file, and holds a row for each use.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const switching = @import("switch.zig");

/// A context: the stack pointer that it had when it left. Its stack holds its six callee-saved
/// registers, and above them the address to resume at. 8 bytes, aligned to 8.
pub const Context = extern struct {
    stack_pointer: usize,
};

/// What a switch names: the context to save into, and the context to resume. 16 bytes, aligned
/// to 8.
pub const Switch = extern struct {
    old: *Context,
    new: *Context,
};

// The assembly names each field by its offset, as a number.
comptime {
    if (switching.supported and builtin.cpu.arch == .x86_64) {
        assert(@offsetOf(Context, "stack_pointer") == 0);
        assert(@sizeOf(Context) == 8 and @alignOf(Context) == 8);
        assert(@offsetOf(Switch, "old") == 0);
        assert(@offsetOf(Switch, "new") == 8);
        assert(@sizeOf(Switch) == 16 and @alignOf(Switch) == 8);
    }
}

/// The words that `jump_switch` pops from a context that it resumes: six registers, then the
/// address to resume at.
const resume_words = 7;

/// The place of each word on the stack of a context, from its stack pointer up: the order of the
/// pops.
const Word = enum(u8) { r15, r14, r13, r12, rbx, rbp, resume_address };

comptime {
    assert(@typeInfo(Word).@"enum".fields.len == resume_words);
}

/// Saves the context that runs into `message.old`, and resumes `message.new`. It returns when
/// another switch names this context as its `new`. It is the address of `jump_switch`, with the
/// C calling convention. So a plain call of it is a call of `jump_switch`, in Debug and in
/// ReleaseSafe, and Zig refuses a call of it with `.always_inline`.
pub const switch_context: *const fn (message: *const Switch) callconv(.c) void =
    @ptrCast(&jump_switch);

/// The switch. Its argument, the message, is in `rdi`. It reads both contexts of the message
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
        else => @compileError("the jump is the switch of x86_64 alone"),
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
        else => @compileError("the jump is the switch of x86_64 alone"),
    }
}

/// The context that a new fiber starts from. `stack_end` is the address one byte after the stack
/// of the fiber, and `switch.zig` checks it. The first stack holds the seven words that
/// `jump_switch` pops: the argument in the word of `r12`, the address of `main` in the word of
/// `rbx`, the entry as the address to resume at, and zero in each other word. So the first frame
/// pointer is zero. Each word is at or above the first stack pointer.
///
/// After the pops the stack pointer is `stack_end`, and the entry pushes one word. So `main` starts
/// with the stack pointer 8 bytes past a multiple of 16, as after a call, and with a return
/// address of zero.
pub fn initial_context(stack_end: usize, argument: usize, comptime main: switching.Main) Context {
    const first = stack_end - resume_words * @sizeOf(usize);
    const words: *[resume_words]usize = @ptrFromInt(first);
    words.* = @splat(0);
    words[@intFromEnum(Word.r12)] = argument;
    words[@intFromEnum(Word.rbx)] = @intFromPtr(&main);
    words[@intFromEnum(Word.resume_address)] = @intFromPtr(&jump_entry);
    return .{ .stack_pointer = first };
}
