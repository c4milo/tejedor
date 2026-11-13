//! Small functions that show how Zig gives a clobber list to LLVM.
//!
//!     zig build-obj lowering.zig -target aarch64-linux-musl -O ReleaseSafe \
//!         -femit-llvm-ir=lowering.ll -femit-asm=lowering.s
//!     zig build-obj lowering.zig -target x86_64-linux-musl -mcpu=baseline -O ReleaseSafe \
//!         -femit-llvm-ir=lowering.ll -femit-asm=lowering.s
const std = @import("std");
const builtin = @import("builtin");

/// std's switch, in a function of its own.
export fn std_switch_function(s: *const std.Io.fiber.Switch) void {
    _ = std.Io.fiber.contextSwitch(s);
}

const aarch64 = struct {
    /// A leaf function whose assembly names `x30`. If the compiler takes x30 as changed, the
    /// function must save it, because `ret` reads it.
    fn clobber_x30() callconv(.c) void {
        asm volatile ("" ::: .{ .x30 = true });
    }

    /// The same function, with `lr` in place of `x30`.
    fn clobber_lr() callconv(.c) void {
        asm volatile ("" ::: .{ .lr = true });
    }

    /// The same function, with `x19`, a register that a callee saves. A control.
    fn clobber_x19() callconv(.c) void {
        asm volatile ("" ::: .{ .x19 = true });
    }
};

const x86_64 = struct {
    /// An `f80` value computed before a block of assembly and used after it. The block does
    /// nothing. Its list names the eight x87 registers by the names of Zig's clobber type.
    fn keep_named(mail: *volatile f80) callconv(.c) f80 {
        const value: f80 = mail.* * 3;
        asm volatile ("nop" ::: .{
                .st0 = true,
                .st1 = true,
                .st2 = true,
                .st3 = true,
                .st4 = true,
                .st5 = true,
                .st6 = true,
                .st7 = true,
                .memory = true,
            });
        return value + mail.*;
    }

    /// The same function, with no x87 name in the list.
    fn keep_plain(mail: *volatile f80) callconv(.c) f80 {
        const value: f80 = mail.* * 3;
        asm volatile ("nop" ::: .{ .memory = true });
        return value + mail.*;
    }

    /// An `f64` value across a block whose list names `zmm0` to `zmm15`, as std's list does.
    fn keep_f64_zmm(mail: *volatile f64) callconv(.c) f64 {
        const value: f64 = mail.* * 3;
        asm volatile ("nop" ::: vector_clobbers("zmm"));
        return value + mail.*;
    }

    /// The same function, with `xmm0` to `xmm15` in the list.
    fn keep_f64_xmm(mail: *volatile f64) callconv(.c) f64 {
        const value: f64 = mail.* * 3;
        asm volatile ("nop" ::: vector_clobbers("xmm"));
        return value + mail.*;
    }

    fn vector_clobbers(comptime prefix: []const u8) std.builtin.assembly.Clobbers {
        var clobbers: std.builtin.assembly.Clobbers = .{ .memory = true };
        for (0..16) |index| @field(clobbers, std.fmt.comptimePrint("{s}{d}", .{ prefix, index })) = true;
        return clobbers;
    }
};

comptime {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            @export(&aarch64.clobber_x30, .{ .name = "clobber_x30" });
            @export(&aarch64.clobber_lr, .{ .name = "clobber_lr" });
            @export(&aarch64.clobber_x19, .{ .name = "clobber_x19" });
        },
        .x86_64 => {
            @export(&x86_64.keep_named, .{ .name = "keep_named" });
            @export(&x86_64.keep_plain, .{ .name = "keep_plain" });
            @export(&x86_64.keep_f64_zmm, .{ .name = "keep_f64_zmm" });
            @export(&x86_64.keep_f64_xmm, .{ .name = "keep_f64_xmm" });
        },
        else => {},
    }
}
