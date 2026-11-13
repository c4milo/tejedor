//! Names that the clobber type of x86_64 does not have.
//!
//!     zig build-obj missing_names.zig -target x86_64-linux-musl -mcpu=x86_64_v4 -O ReleaseSafe
export fn clobber_k1() void {
    asm volatile ("" ::: .{ .k1 = true });
}

export fn clobber_r16() void {
    asm volatile ("" ::: .{ .r16 = true });
}
