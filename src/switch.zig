//! The context switch of a fiber, the entry of a new fiber, and its first context. Each caller of
//! the package calls `switch_context` with a plain call, and gets the form of its architecture:
//!
//! - On aarch64 it is std 0.16.0's `fiber.contextSwitch`, instruction for instruction, with changes
//!   to the clobber list. It is `switch_copied`, an inline function, so each caller holds a copy of
//!   the switch, in Debug and in ReleaseSafe (records 3 and 5).
//! - On x86_64 it is the jump of `switch_jump.zig`: a function in assembly that saves the
//!   callee-saved registers itself, and that each caller calls as a C function (record 6). It holds
//!   no code of std.
//!
//! std's own function faults in a ReleaseSafe build. rotor's decision 22 found the first three
//! errors of its lists at its check 1:
//!
//! 1. The register that carries the message is not in the list. It is `x1` on aarch64, and `rsi`
//!    on x86_64. std names it as the input and as a clobber. The optimized build then never loads
//!    the input, and the switch reads its message from the value that the register held before.
//! 2. On aarch64 the list names `lr` beside `x30`. With `x30` alone, the optimized build keeps a
//!    value in that register across the switch, and the switch does not save it.
//! 3. On aarch64 Linux the list names `x18`. std leaves it out, because macOS reserves it. Linux
//!    does not, and the optimized build kept a value in it across the switch.
//!
//! This package found two more errors on 2026-11-12, and Camilo ruled on each:
//!
//! 4. On x86_64 the list names `xmm0` to `xmm15` beside `zmm0` to `zmm31` (record 2). Since record
//!    6 the x86_64 list is not in this file. `bench/std_switch_x86_64.zig` holds std's switch of
//!    x86_64 with that list, for the probe.
//! 5. On aarch64 the list names `nzcv`, the condition flags. std's list does not. The optimized
//!    build kept the flags of a comparison across the switch, and the other context changed them.
//!    Record 3 holds this correction.
//!
//! On 2026-11-13 Camilo ruled one more change, which is no correction (record 5):
//!
//! 6. On aarch64 the list does not name `ffr`, the first-fault register of SVE, and std's list
//!    does. LLVM reserves `ffr`, so it never keeps a value there, and the name protects nothing.
//!    LLVM printed a warning for each copy of the switch that named it.
//!
//! The session applied the same reason to `x18`, and Camilo accepted that choice on 2026-11-14
//! (record 5). LLVM reserves `x18` on the systems of Apple, Android, OpenHarmony, Fuchsia, UEFI and
//! Windows. It also reserves it for a processor with the feature `reserve_x18`. The list names
//! `x18` only where LLVM does not reserve it. `zig build test-reserved` fails when the list names a
//! register that LLVM reserves.
//!
//! Record 3 sets the form in which a caller gets the switch. Record 5 puts that form in
//! `switch_context` itself, and record 6 makes the jump the form of x86_64:
//!
//! - On aarch64 `switch_context` is `switch_copied`. The clobber list then decides what a caller
//!   keeps across the switch. A test can see a name of the list only where the compiler keeps a
//!   value in that register. Records 3 and 5 give the mutations of the list. No test proves `p0`
//!   to `p15`, `fpcr` or `fpsr`. Zig refuses a call of it with `.never_inline`.
//! - On x86_64 `switch_context` is the address of the jump, with the C calling convention. So each
//!   caller calls it, and the calling convention covers each caller-saved register: the x87
//!   registers, `xmm0` to `xmm31`, `k0` to `k7` and `r16` to `r31` among them. Zig refuses a call
//!   of it with `.always_inline`.
//!
//! `switch_other_form` gives the call of aarch64 to the tests and the probe. The lint rule
//! `switch-form` refuses a reference to that name in each other file under `src/`. On x86_64 this
//! file has no other form, and the name does not compile.
//!
//! The switch saves no control register: not FPCR on aarch64, and not MXCSR or the x87 control
//! word on x86_64. So the rounding mode and the exception masks belong to the thread, and not to
//! a fiber. A fiber that changes them restores them before it blocks (record 3).
//!
//! Each form of the switch needs a process with no shadow stack and no indirect branch tracking of
//! the processor, such as CET on x86_64. std's switch needs the same. After a switch, a return can
//! go to an address that the other context pushed, and the call of the jump never returns. A
//! shadow stack refuses both. Each form resumes with an indirect jump to an address with no
//! `endbr64`, and branch tracking refuses that jump. The build writes no GNU property note that
//! asks Linux for either. The ReleaseSafe probe for x86_64 Linux holds no such note (`llvm-readelf
//! -n`, 2026-11-14).
//!
//! std's file is the same, byte for byte, in Zig 0.17.1. A Zig upgrade compares std's switch of
//! aarch64 with this copy (rotor's decision 34, "Upkeep"). Record 6 lists what that upgrade reads
//! for x86_64.
//!
//! The first context and the entry of a new fiber depart from std's `Kqueue.mainIdleEntry` (record
//! 4). The argument of the fiber is above its first stack pointer, and `main` starts with a return
//! address of zero. On x86_64 the first stack is the one of the jump (record 6).
//!
//! This file holds assembly and a forced inline, and `switch_jump.zig` holds assembly. So
//! `docs/hot-path-ledger.md` names both files, and holds a row for each use.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const fiber = std.Io.fiber;
const jump = @import("switch_jump.zig");

/// True where this file has a switch and an entry for the target of the build, by the rule of
/// `supports` (record 5). A true is never wrong about the calling convention. The switch does not
/// swap the shadow call stack in `x18`, or the stack of SafeStack. So `supported` is false on
/// Fuchsia, which builds its C code with both. Elsewhere, do not switch a fiber while its stack
/// holds a frame of code built with either of them (record 5).
pub const supported = supports(&builtin.target);

// Not in a test: std 0.16.0's test runner does not compile for Fuchsia (`zig build test-fuchsia`).
comptime {
    if (builtin.os.tag == .fuchsia) assert(!supported);
}

/// Whether this file has a switch and an entry for `target` (record 5). The switch and the entry
/// follow System V on x86_64 and AAPCS64 on aarch64, and read and write 64-bit words. So the rule
/// reads the architecture, the width of a pointer, and the C calling convention of the target. It
/// is true for these three alone, with 64-bit pointers, and on no Fuchsia:
///
/// - x86_64 with `x86_64_sysv`: Linux, the systems of Apple and the BSDs.
/// - aarch64 with `aarch64_aapcs`: Linux, the BSDs, and UEFI.
/// - aarch64 with `aarch64_aapcs_darwin`: the systems of Apple.
///
/// It is false on Windows, on both architectures. On x86_64 the C calling convention of Windows
/// reads the first argument from `rcx`, and the entry puts it in `rdi`. On aarch64 Windows has a
/// convention of its own. It is false on UEFI of x86_64, which has the convention of Windows. It
/// is false on Fuchsia, whose C code keeps a shadow call stack in `x18` on aarch64, and a SafeStack
/// pointer at `%fs:0x18` on x86_64. It is false where a pointer is 32 bits: `gnux32`, `muslx32`
/// and `ilp32`. std 0.16.0 gives `gnux32` and `muslx32` the convention `x86_64_sysv`, so the rule
/// reads the width of a pointer too. This file has no switch for riscv64, which std's fibers have.
fn supports(target: *const std.Target) bool {
    switch (target.cpu.arch) {
        .aarch64, .x86_64 => {},
        else => return false,
    }
    if (target.os.tag == .fuchsia) return false;
    if (target.ptrBitWidth() != @bitSizeOf(u64)) return false;
    const convention = target.cCallingConvention() orelse return false;
    return switch (convention) {
        .x86_64_sysv, .aarch64_aapcs, .aarch64_aapcs_darwin => true,
        else => false,
    };
}

/// The state of a context that a switch left. On aarch64 it is std's: the stack pointer, the frame
/// pointer and the address to resume at. On x86_64 it is the jump's: one word, the stack pointer,
/// and the stack holds the rest (record 6).
pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => jump.Context,
    else => fiber.Context,
};

/// What a switch names: the context to save into, and the context to resume.
pub const Switch = switch (builtin.cpu.arch) {
    .x86_64 => jump.Switch,
    else => fiber.Switch,
};

// The assembly of this file names each field of `Context` and of `Switch` by its offset, as a
// number. On aarch64 both types are std's. If a Zig upgrade moves a field, the build stops here.
// `switch_jump.zig` holds the asserts of x86_64.
comptime {
    if (supported and builtin.cpu.arch == .aarch64) {
        assert(@offsetOf(Context, "sp") == 0);
        assert(@offsetOf(Context, "fp") == 8);
        assert(@offsetOf(Context, "pc") == 16);
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

/// The context that a new fiber starts from (record 4). `stack_end` is the address one byte after
/// the stack of the fiber. The argument is above the first stack pointer, so a signal handler that
/// runs on this stack before the entry does not write over it.
///
/// - On aarch64 this function writes `argument` into the word below `stack_end`, and the entry
///   hands that word to `main`. The first stack pointer is 16 bytes below `stack_end`. The entry
///   clears the link register, so `main` starts with a return address of zero.
/// - On x86_64 it is the first stack of the jump (`switch_jump.zig`, record 6). The entry pushes a
///   return address of zero, and the stack pointer is then 8 bytes past a multiple of 16, as a
///   function sees it at its entry.
///
/// So a stack trace from a fiber ends at the frame of `main`.
pub fn initial_context(stack_end: usize, argument: usize, comptime main: Main) Context {
    assert(stack_end % stack_end_alignment == 0);
    assert(stack_end != 0);
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const argument_slot: *usize = @ptrFromInt(stack_end - @sizeOf(usize));
            argument_slot.* = argument;
            const entry = @intFromPtr(&Entry(main).entry);
            return .{ .sp = stack_end - stack_end_alignment, .fp = 0, .pc = entry };
        },
        .x86_64 => return jump.initial_context(stack_end, argument, main),
        else => @compileError("no fiber entry for this architecture"),
    }
}

/// The entry of a new fiber on aarch64. It reads the argument from the word below the end of the
/// stack into the first argument register, clears the link register, and jumps to `main`. std's
/// `Kqueue.mainIdleEntry` reads the argument below the stack pointer, and this entry does not
/// (record 4).
fn Entry(comptime main: Main) type {
    return struct {
        fn entry() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .aarch64 => asm volatile (
                    \\ ldr x0, [sp, #8]
                    \\ mov lr, xzr
                    \\ b %[main]
                    :
                    : [main] "X" (&main),
                ),
                else => @compileError("this entry is for aarch64 alone"),
            }
        }
    };
}

/// Saves the context that runs into `message.old`, and resumes `message.new`. It returns when
/// another switch names this context as its `new`. A caller calls it with a plain call, and gets
/// the form of its architecture:
///
/// - On aarch64 it is `switch_copied`, an inline function. So each caller holds a copy of the
///   switch, in Debug and in ReleaseSafe (records 3 and 5).
/// - On x86_64 it is the jump, a pointer to a function in assembly with the C calling convention.
///   So each caller calls it, in Debug and in ReleaseSafe (record 6).
pub const switch_context = switch (builtin.cpu.arch) {
    .x86_64 => jump.switch_context,
    else => switch_copied,
};

/// The call of aarch64, the form that the package does not use there (record 5). A plain call of
/// it is a call, in Debug and in ReleaseSafe. Only the tests and the probe name it, and the lint
/// rule `switch-form` keeps it out of the other files under `src/`. On x86_64 this file has no
/// other form (record 6), and a reference to this name does not compile there.
pub const switch_other_form = switch (builtin.cpu.arch) {
    .aarch64 => switch_called,
    else => @compileError("the package has no other form of the switch on this architecture"),
};

/// A function that holds a copy of the switch, and that no caller can copy. It has the C calling
/// convention, so its argument is in `x0`. `switch_test.zig` relies on that.
noinline fn switch_called(message: *const Switch) callconv(.c) void {
    switch_copied(message);
}

/// True where LLVM reserves `x18` of aarch64. That is on the systems of Apple, Android,
/// OpenHarmony, Fuchsia, UEFI and Windows, and for a processor with the feature `reserve_x18`. The
/// list names `x18` on each other target (record 5).
const x18_reserved = switch (builtin.target.os.tag) {
    .windows, .uefi, .fuchsia => true,
    else => builtin.target.os.tag.isDarwin() or builtin.target.abi.isAndroid() or
        builtin.target.abi.isOpenHarmony() or
        (builtin.cpu.arch == .aarch64 and
            std.Target.aarch64.featureSetHas(builtin.cpu.features, .reserve_x18)),
};

/// The assembly of the switch on aarch64. Each caller holds a copy of it, because it is an inline
/// function, and `switch_called` is one such caller. A call of it with `.never_inline` does not
/// compile.
inline fn switch_copied(message: *const Switch) void {
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
              .x18 = !x18_reserved,
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
              .nzcv = true,
              .memory = true,
            }),
        else => @compileError("no fiber switch for this architecture"),
    };
}

const testing = std.testing;

/// `builtin.target` with another processor, system and ABI. `supports` reads no other field.
fn target_of(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, abi: std.Target.Abi) std.Target {
    var target = builtin.target;
    target.cpu.arch = arch;
    target.os.tag = os;
    target.abi = abi;
    return target;
}

test "the switch is supported where the C calling convention is System V or AAPCS64" {
    // Linux, the systems of Apple and FreeBSD on both architectures, and UEFI on aarch64.
    try testing.expect(supports(&target_of(.x86_64, .linux, .musl)));
    try testing.expect(supports(&target_of(.x86_64, .linux, .gnu)));
    try testing.expect(supports(&target_of(.x86_64, .macos, .none)));
    try testing.expect(supports(&target_of(.x86_64, .freebsd, .none)));
    try testing.expect(supports(&target_of(.aarch64, .linux, .musl)));
    try testing.expect(supports(&target_of(.aarch64, .macos, .none)));
    try testing.expect(supports(&target_of(.aarch64, .freebsd, .none)));
    try testing.expect(supports(&target_of(.aarch64, .uefi, .msvc)));
    // Windows and Fuchsia on both architectures, and UEFI on x86_64.
    try testing.expect(!supports(&target_of(.x86_64, .windows, .gnu)));
    try testing.expect(!supports(&target_of(.x86_64, .windows, .msvc)));
    try testing.expect(!supports(&target_of(.aarch64, .windows, .gnu)));
    try testing.expect(!supports(&target_of(.aarch64, .windows, .msvc)));
    try testing.expect(!supports(&target_of(.x86_64, .uefi, .msvc)));
    try testing.expect(!supports(&target_of(.x86_64, .fuchsia, .none)));
    try testing.expect(!supports(&target_of(.aarch64, .fuchsia, .none)));
    // The ABIs whose pointers are 32 bits: the x32 ABIs of Linux, and `ilp32` of aarch64.
    try testing.expect(!supports(&target_of(.x86_64, .linux, .gnux32)));
    try testing.expect(!supports(&target_of(.x86_64, .linux, .muslx32)));
    try testing.expect(!supports(&target_of(.aarch64, .linux, .ilp32)));
    // `gnuabin32` is a name of the n32 ABI of MIPS. std 0.16.0 gives it the convention
    // `x86_64_x32` on x86_64.
    try testing.expect(!supports(&target_of(.x86_64, .linux, .gnuabin32)));
    // The architectures that this file has no switch for.
    try testing.expect(!supports(&target_of(.riscv64, .linux, .musl)));
    try testing.expect(!supports(&target_of(.x86, .linux, .musl)));
    try testing.expect(!supports(&target_of(.aarch64_be, .linux, .musl)));
}

test "supported is the rule of supports for the target of the build, and false on Windows" {
    // The build compiles this test for Windows too, and runs none there (build/switch_checks.zig).
    // The first comptime assert stops that compile when `supported` does not follow the rule. The
    // second stops it when `supported` is true on Windows, whatever the rule says.
    comptime assert(supported == supports(&builtin.target));
    if (builtin.os.tag == .windows) comptime assert(!supported);
    try testing.expectEqual(supports(&builtin.target), supported);
}
