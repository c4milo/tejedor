// issue2.zig
const std = @import("std");
const builtin = @import("builtin");

fn clobber_x30() callconv(.c) void {
    asm volatile ("" ::: .{ .x30 = true });
}

fn keep_named(mail: *volatile f80) callconv(.c) f80 {
    const value: f80 = mail.* * 3;
    asm volatile ("nop" ::: .{
            .st0 = true, .st1 = true, .st2 = true, .st3 = true,
            .st4 = true, .st5 = true, .st6 = true, .st7 = true,
            .memory = true,
        });
    return value + mail.*;
}

fn keep_f64_zmm(mail: *volatile f64) callconv(.c) f64 {
    const value: f64 = mail.* * 3;
    asm volatile ("nop" ::: .{
            .zmm0 = true, .zmm1 = true, .zmm2 = true, .zmm3 = true,
            .zmm4 = true, .zmm5 = true, .zmm6 = true, .zmm7 = true,
            .zmm8 = true, .zmm9 = true, .zmm10 = true, .zmm11 = true,
            .zmm12 = true, .zmm13 = true, .zmm14 = true, .zmm15 = true,
            .memory = true,
        });
    return value + mail.*;
}

comptime {
    switch (builtin.cpu.arch) {
        .aarch64 => @export(&clobber_x30, .{ .name = "clobber_x30" }),
        .x86_64 => {
            @export(&keep_named, .{ .name = "keep_named" });
            @export(&keep_f64_zmm, .{ .name = "keep_f64_zmm" });
        },
        else => {},
    }
}
