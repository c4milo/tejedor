# Report to Zig, issue 2

### Title

LLVM backend: some clobber names have no effect, and the x86 `Clobbers` has no `k0`–`k7` or `r16`–`r31`

### Body

**Zig version:** 0.16.0 and 0.17.1, the Homebrew builds. `zig cc --version` prints clang 21.1.8
and 22.1.8.

**Targets:** `aarch64-linux-musl`, `aarch64-macos`, and `x86_64-linux-musl` with the CPU models
`baseline`, `x86_64_v4`, `diamondrapids` and `x86_64_v4-evex512`.

The backend gives each name of `std.builtin.assembly.Clobbers` to LLVM as `~{name}`. The LLVM IR
below shows it.

LLVM does not know some of these names, and it ignores them with no message. Some registers have
no name in the type.

**What happens.**

| register | Zig gives LLVM | clang gives LLVM for the same name | LLVM 21.1.8 and 22.1.8 |
|---|---|---|---|
| `x30` on aarch64 | `~{x30}` | `~{lr}` | ignores `~{x30}`. It honours `~{lr}` |
| `st0` to `st7` on x86_64 | `~{st0}` to `~{st7}` | `~{st}`, `~{st(1)}` to `~{st(7)}` | ignores `~{st0}` to `~{st7}`. It honours clang's names |
| `zmm0` to `zmm31` on a target with no 512-bit registers | `~{zmm0}` to `~{zmm31}` | not tested | ignores them. They do not cover the `xmm` or `ymm` parts |
| `k0` to `k7` on x86_64 | no field: `error: no field named 'k1' in struct 'builtin.assembly.Clobbers__struct_1008'` | not tested | honours `~{k0}` to `~{k7}` when I add them to the IR |
| `r16` to `r31` on x86_64 with APX | no field: `error: no field named 'r16' in struct 'builtin.assembly.Clobbers__struct_1008'` | not tested | honours `~{r16}` to `~{r31}` when I add them to the IR |

Zig 0.17.1 gives the same errors, with the struct `lang.assembly.Clobbers__struct_0`.

**What should happen.** A name of the type either keeps each value out of its register, or gives
a compile error. For a register that the type cannot name, the type has a field.

**Reproduction 1: `x30` and `st0` to `st7`.**

```zig
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
```

```c
/* lowering_c.c: the same blocks in C, for a comparison */
#if defined(__aarch64__)
void c_clobber_x30(void) { __asm__ volatile("" ::: "x30"); }
#endif
#if defined(__x86_64__)
long double c_keep_named(volatile long double *mail) {
    long double value = *mail * 3;
    __asm__ volatile("nop" ::: "st", "st(1)", "st(2)", "st(3)", "st(4)", "st(5)", "st(6)",
                     "st(7)", "memory");
    return value + *mail;
}
#endif
```

```sh
zig build-obj issue2.zig -target x86_64-linux-musl -mcpu=baseline -O ReleaseSafe \
    -fno-emit-bin -femit-llvm-ir=issue2.ll -femit-asm=issue2.s
zig build-obj issue2.zig -target aarch64-linux-musl -O ReleaseSafe \
    -fno-emit-bin -femit-llvm-ir=issue2.ll -femit-asm=issue2.s
zig cc -target x86_64-linux-musl -O2 -S -emit-llvm lowering_c.c -o lowering_c.ll
zig cc -target x86_64-linux-musl -O2 -S lowering_c.c -o lowering_c.s
zig cc -target aarch64-linux-musl -O2 -S -emit-llvm lowering_c.c -o lowering_c.ll
```

The constraint strings in the IR, the same with Zig 0.16.0 and 0.17.1:

```llvm
; issue2.zig, aarch64-linux-musl
"", "~{x30}"
; lowering_c.c, aarch64-linux-musl
"", "~{lr}"
; issue2.zig, x86_64-linux-musl
"nop", "~{memory},~{st0},~{st1},~{st2},~{st3},~{st4},~{st5},~{st6},~{st7},~{dirflag},~{fpsr},~{flags}"
; lowering_c.c, x86_64-linux-musl
"nop", "~{st},~{st(1)},~{st(2)},~{st(3)},~{st(4)},~{st(5)},~{st(6)},~{st(7)},~{memory},~{dirflag},~{fpsr},~{flags}"
```

The assembly. Zig keeps the `f80` value in `st(0)` across the block. clang moves it to the stack:

```asm
; keep_named, from issue2.zig
	fld	tbyte ptr [rdi]
	fmul	dword ptr [rip + .LCPI0_0]
	nop
	fld	tbyte ptr [rdi]
	faddp	st(1), st
; c_keep_named, from lowering_c.c
	fldt	(%rdi)
	fmuls	.LCPI0_0(%rip)
	fstpt	-12(%rbp)                       # 10-byte Folded Spill
	nop
	fldt	(%rdi)
	fldt	-12(%rbp)                       # 10-byte Folded Reload
	faddp	%st, %st(1)
```

For `-mcpu=baseline`, `keep_f64_zmm` keeps the `f64` value in `xmm0` across the block. In the
attached `lowering.zig`, the same function with `xmm0` to `xmm15` in the list moves it to the
stack:

```asm
; keep_f64_zmm, from issue2.zig
	movsd	xmm0, qword ptr [rdi]
	mulsd	xmm0, qword ptr [rip + .LCPI1_0]
	nop
	addsd	xmm0, qword ptr [rdi]
```

In `clobber_x30`, the frame record of a ReleaseSafe build saves `x30`, with or without the
clobber. So for `x30` the proof is the switch of issue 1. std's list names `.x30` and no `.lr`. A
ReleaseSafe build for aarch64-macos then kept a loop counter in `w30` across the switch. The
counter was wrong after the switch:

```asm
	mov	w30, #0x86a0            ; =34464
	movk	w30, #0x1, lsl #16
	...
	br	x3
	ldr	x9, [sp, #0x8]
	subs	x30, x30, #0x1
```

With the corrected list of issue 1 the case passed. With that list less `.lr`, it failed.

**Reproduction 2: an `f80` value across the switch, with `st0` to `st7`.**

The attached `std_switch.zig` runs a case `f80`. The main context and a fiber each add to an
`f80` sum, and switch to each other 64 times. The list has every correction of issue 1, and
`st0` to `st7`. The case fails in ReleaseSafe:

| target, run under Rosetta | Zig | result |
|---|---|---|
| x86_64-linux-musl, baseline, ReleaseSafe | 0.16.0 and 0.17.1 | FAIL: sum: expected 7, found 3.5 |
| x86_64-macos, baseline, ReleaseSafe | 0.16.0 and 0.17.1 | FAIL: sum: expected 7, found 3.5 |
| the same targets, Debug | 0.16.0 and 0.17.1 | PASS |

**Reproduction 3: AVX-512 and APX, from the disassembly only.** No machine here has AVX-512 or
APX, so nothing ran. The attached `wide.zig` keeps values across std's switch:

```zig
export fn mask_across(s: *const Switch, a: *const Lanes, b: *const Lanes, out: *volatile Lanes) void {
    const less = a.* < b.*; // Lanes is @Vector(8, u64)
    _ = std.Io.fiber.contextSwitch(s);
    out.* = @select(u64, less, a.*, b.*);
}

export fn integers_across(s: *const Switch, in: *const [3]u64, out: *volatile u64) void {
    const x = in[0] *% 3;
    const y = in[1] *% 5;
    const z = in[2] *% 7;
    _ = std.Io.fiber.contextSwitch(s);
    out.* = x +% y +% z;
}
```

```sh
zig build-obj wide.zig -target x86_64-linux-musl -mcpu=x86_64_v4 -O ReleaseSafe -fno-emit-bin -femit-asm=wide.s
zig build-obj wide.zig -target x86_64-linux-musl -mcpu=diamondrapids -O ReleaseSafe -fno-emit-bin -femit-asm=wide.s
```

| CPU model | function | registers that hold a value across the switch |
|---|---|---|
| `x86_64_v4` | `mask_across` | `k1`: `vpcmpltuq k1, ...` before the switch, `vmovdqa64 zmm0 {k1}, ...` after it |
| `x86_64_v4-evex512` (0.16.0 only) | `mask_across` | `k1` and `k2` |
| `diamondrapids` | `mask_across` | `k1`, and the pointers in `r16`, `r17` and `r18` |
| `diamondrapids` | `integers_across` | `r16` to `r19` |

Zig 0.17.1 gives the same registers for `x86_64_v4` and `diamondrapids`. It rejects
`x86_64_v4-evex512` with `error: unknown CPU feature: 'evex512'`.

I added `~{k0}` to `~{k7}` and `~{r16}` to `~{r31}` to the constraint string of the switch in the
IR of the `diamondrapids` build. Then I compiled the IR with `zig cc -O2 -S`. The build then
saved the mask and the integers on the stack, and reloaded them after the switch. So LLVM 21.1.8
honours these names.

**Suggested change.**

1. Lower `.x30` to `~{lr}` on aarch64. LLVM PR <https://github.com/llvm/llvm-project/pull/167783>
   corrects `~{x30}` and `~{x29}` in LLVM. Its page says that it merged into LLVM's main branch on
   2026-05-17. The LLVM 22.1.8 of Zig 0.17.1 still ignores `~{x30}`. I did not test `x29`.
2. Lower `.st0` to `~{st}`, and `.st1` to `.st7` to `~{st(1)}` to `~{st(7)}`, as clang does.
3. Add `k0` to `k7` and `r16` to `r31` to the x86 clobber type.
4. For a name that the target does not have, such as `zmm16` with no AVX-512, give a compile
   error. Another choice is to lower it to the widest register that the target has.

**Attachments:** `issue2.zig`, `lowering.zig`, `lowering_c.c`, `wide.zig`, `missing_names.zig`,
`std_switch.zig`.

**Related:** #31284 (the same class of fault for `r14` on arm), LLVM PR #167783, issue 1 of this
report.
