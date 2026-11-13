//! Functions that keep a value across std's switch, for x86_64 targets with registers that the
//! clobber type of Zig 0.16.0 cannot name, or that std's list does not cover. Compile only, and
//! read the disassembly: no machine here runs AVX-512 or APX.
//!
//!     zig build-obj wide.zig -target x86_64-linux-musl -mcpu=x86_64_v4 -O ReleaseSafe -femit-asm=wide.s
//!     zig build-obj wide.zig -target x86_64-linux-musl -mcpu=diamondrapids -O ReleaseSafe -femit-asm=wide.s
//!     zig build-obj wide.zig -target x86_64-linux-musl -mcpu=x86_64_v4-evex512 -O ReleaseSafe -femit-asm=wide.s
const std = @import("std");
const Switch = std.Io.fiber.Switch;

const Lanes = @Vector(8, u64);
const Wide = @Vector(4, f64);

/// A vector comparison before the switch, and a use of its result after it. With AVX-512 the
/// result is a mask in one of `k0` to `k7`.
export fn mask_across(s: *const Switch, a: *const Lanes, b: *const Lanes, out: *volatile Lanes) void {
    const less = a.* < b.*;
    _ = std.Io.fiber.contextSwitch(s);
    out.* = @select(u64, less, a.*, b.*);
}

/// Three integers computed before the switch and used after it. std's list names each general
/// register from `rax` to `r15`. With APX the compiler can use `r16` to `r31`.
export fn integers_across(s: *const Switch, in: *const [3]u64, out: *volatile u64) void {
    const x = in[0] *% 3;
    const y = in[1] *% 5;
    const z = in[2] *% 7;
    _ = std.Io.fiber.contextSwitch(s);
    out.* = x +% y +% z;
}

/// Two 256-bit sums computed before the switch and used after it.
export fn vectors_across(s: *const Switch, in: *const [2]Wide, out: *volatile Wide) void {
    const p = in[0] * in[1];
    const q = in[0] + in[1];
    _ = std.Io.fiber.contextSwitch(s);
    out.* = p + q;
}

/// std's x86_64 list, with `xmm0` to `xmm<last>` added.
fn list_with_xmm(comptime last: usize) std.builtin.assembly.Clobbers {
    @setEvalBranchQuota(100_000);
    var clobbers: std.builtin.assembly.Clobbers = .{
        .rax = true, .rcx = true, .rdx = true, .rbx = true, .rsi = true, .rdi = true,
        .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true,
        .r14 = true, .r15 = true, .fpsr = true, .fpcr = true, .mxcsr = true, .rflags = true,
        .dirflag = true, .memory = true,
    };
    for (0..8) |index| @field(clobbers, std.fmt.comptimePrint("mm{d}", .{index})) = true;
    for (0..32) |index| @field(clobbers, std.fmt.comptimePrint("zmm{d}", .{index})) = true;
    for (0..last + 1) |index| @field(clobbers, std.fmt.comptimePrint("xmm{d}", .{index})) = true;
    return clobbers;
}

/// std's switch, instruction for instruction, with the clobber list as a parameter.
inline fn switch_with(comptime clobbers: std.builtin.assembly.Clobbers, s: *const Switch) void {
    _ = asm volatile (
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
        : [message_to_send] "{rsi}" (s),
        : clobbers);
}

/// `vectors_across` with std's list and `xmm0` to `xmm15`.
export fn vectors_across_xmm15(s: *const Switch, in: *const [2]Wide, out: *volatile Wide) void {
    const p = in[0] * in[1];
    const q = in[0] + in[1];
    switch_with(comptime list_with_xmm(15), s);
    out.* = p + q;
}

/// `vectors_across` with std's list and `xmm0` to `xmm31`.
export fn vectors_across_xmm31(s: *const Switch, in: *const [2]Wide, out: *volatile Wide) void {
    const p = in[0] * in[1];
    const q = in[0] + in[1];
    switch_with(comptime list_with_xmm(31), s);
    out.* = p + q;
}
