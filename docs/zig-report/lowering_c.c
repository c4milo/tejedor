/* The functions of lowering.zig, written in C, to show what clang gives LLVM for the same
 * register names.
 *
 *     zig cc -target aarch64-linux-musl -O2 -S -emit-llvm lowering_c.c -o lowering_c.ll
 *     zig cc -target x86_64-linux-musl -O2 -S -emit-llvm lowering_c.c -o lowering_c.ll
 */
#if defined(__aarch64__)
void c_clobber_x30(void) { __asm__ volatile("" ::: "x30"); }
void c_clobber_lr(void) { __asm__ volatile("" ::: "lr"); }
#endif

#if defined(__x86_64__)
long double c_keep_named(volatile long double *mail) {
    long double value = *mail * 3;
    __asm__ volatile("nop" ::: "st", "st(1)", "st(2)", "st(3)", "st(4)", "st(5)", "st(6)",
                     "st(7)", "memory");
    return value + *mail;
}
#endif
