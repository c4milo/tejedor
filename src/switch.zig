//! The context switch of a fiber. It is std 0.16.0's `fiber.contextSwitch`, instruction for
//! instruction, with four changes to the clobber lists. std's own function faults in a
//! ReleaseSafe build. rotor's decision 22 found the first three errors at its check 1:
//!
//! 1. The register that carries the message is not in the list. It is `x1` on aarch64, and `rsi`
//!    on x86_64. std names it as the input and as a clobber. The optimized build then never loads
//!    the input, and the switch reads its message from the value that the register held before.
//! 2. On aarch64 the list names `lr` beside `x30`. With `x30` alone, the optimized build keeps a
//!    value in that register across the switch, and the switch does not save it.
//! 3. On aarch64 Linux the list names `x18`. std leaves it out, because macOS reserves it. Linux
//!    does not, and the optimized build kept a value in it across the switch.
//!
//! This package found a fourth error on 2026-11-12. Record 2 of `docs/decisions/` holds it, with
//! Camilo's ruling:
//!
//! 4. On x86_64 the list names `xmm0` to `xmm15` beside `zmm0` to `zmm31`. std names the `zmm`
//!    registers alone, and a processor with no AVX-512 has none. For such a target the optimized
//!    build kept a floating-point value in an `xmm` register across the switch, and the other
//!    context changed it.
//!
//! std's file is the same, byte for byte, in Zig 0.17.1. A Zig upgrade compares std's switch with
//! this copy (rotor's decision 34, "Upkeep").
//!
//! `switch_context` is an ordinary function, and not `inline`. The clobber list must name each
//! register that the switch does not save. Then a caller keeps what it needs, whether the
//! compiler calls the function or copies its body into the caller.
//!
//! This file holds assembly, so `docs/hot-path-ledger.md` holds a row for each use.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const fiber = std.Io.fiber;

/// True on the two architectures that this file has a switch and an entry for. The fibers of std
/// support a third, riscv64.
///
/// It reads the architecture alone, and a caller checks the system too. The switch and the entry
/// follow System V on x86_64 and AAPCS64 on aarch64. On x86_64 Windows this is true, and the
/// entry is wrong. The entry puts the argument in `rdi`, and the C calling convention of that
/// system reads `rcx`. The package as a whole does not build for Windows, because rotor builds
/// for Linux and for the systems of Apple alone.
pub const supported = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => true,
    else => false,
};

pub const Context = fiber.Context;
pub const Switch = fiber.Switch;

// The assembly of this file names each field of `Context` and of `Switch` by its offset, as a
// number. Both types are std's. If a Zig upgrade moves a field, the build stops here.
comptime {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            assert(@offsetOf(Context, "sp") == 0);
            assert(@offsetOf(Context, "fp") == 8);
            assert(@offsetOf(Context, "pc") == 16);
        },
        .x86_64 => {
            assert(@offsetOf(Context, "rsp") == 0);
            assert(@offsetOf(Context, "rbp") == 8);
            assert(@offsetOf(Context, "rip") == 16);
        },
        else => {},
    }
    if (supported) {
        assert(@sizeOf(Context) == 24);
        assert(@offsetOf(Switch, "old") == 0);
        assert(@offsetOf(Switch, "new") == 8);
        assert(@sizeOf(Switch) == 16);
    }
}

/// The alignment of a stack's end, which System V and AAPCS64 both require.
pub const stack_end_alignment = 16;

/// The function that a new fiber runs. It never returns. A fiber that is done switches to another
/// context, and no context switches back to it.
pub const Main = fn (argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn;

/// The context that a new fiber starts from. `stack_end` is the address one byte after the stack
/// of the fiber. This function writes `argument` into the word below `stack_end`, and the entry
/// hands that word to `main`.
pub fn initial_context(stack_end: usize, argument: usize, comptime main: Main) Context {
    assert(stack_end % stack_end_alignment == 0);
    assert(stack_end != 0);
    const slot: *usize = @ptrFromInt(stack_end - @sizeOf(usize));
    slot.* = argument;
    const entry = @intFromPtr(&Entry(main).entry);
    return switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = stack_end, .fp = 0, .pc = entry },
        .x86_64 => .{ .rsp = stack_end - @sizeOf(usize), .rbp = 0, .rip = entry },
        else => @compileError("no fiber entry for this architecture"),
    };
}

/// The entry of a new fiber. It reads the argument from the word below the end of the stack into
/// the first argument register, as `Kqueue.mainIdleEntry` of std does. Then it jumps to `main`.
fn Entry(comptime main: Main) type {
    return struct {
        fn entry() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile (
                    \\ movq (%%rsp), %%rdi
                    \\ jmp %[main:P]
                    :
                    : [main] "X" (&main),
                ),
                .aarch64 => asm volatile (
                    \\ ldr x0, [sp, #-8]
                    \\ b %[main]
                    :
                    : [main] "X" (&main),
                ),
                else => @compileError("no fiber entry for this architecture"),
            }
        }
    };
}

/// Saves the context that runs into `message.old`, and resumes `message.new`. It returns when
/// another switch names this context as its `new`. It has the C calling convention, so its
/// argument is in the first argument register. `switch_test.zig` relies on that.
pub fn switch_context(message: *const Switch) callconv(.c) void {
    _ = switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ adr x5, 0f
            \\ ldp x4, fp, [x2]
            \\ str x5, [x0, #16]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const Switch),
            : [message_to_send] "{x1}" (message),
            : .{
              .x0 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x18 = !builtin.target.os.tag.isDarwin(),
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x30 = true,
              .lr = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .ffr = true,
              .memory = true,
            }),
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
        else => @compileError("no fiber switch for this architecture"),
    };
}
