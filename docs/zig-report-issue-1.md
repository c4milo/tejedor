# Report to Zig, issue 1

### Title

`std.Io.fiber.contextSwitch`: the clobber lists name the message register, and miss `lr`, `x18`, `nzcv` and the `xmm` registers

### Body

**Zig version:** 0.16.0 and 0.17.1. `lib/std/Io/fiber.zig` is the same, byte for byte, in both.
Both are the Homebrew builds; `zig cc --version` prints clang 21.1.8 and 22.1.8.

**Targets:** `aarch64-macos`, `aarch64-linux-musl`, `x86_64-linux-musl` and `x86_64-macos`, the
x86_64 targets with `-mcpu=baseline`. The faults show in ReleaseSafe. Debug passed each case.

`contextSwitch` is an `inline fn`, so each caller holds a copy of its assembly. The clobber list
then decides which values the caller can keep in registers across the switch. The context that
runs in between changes each register that the list does not name.

**What happens.** In a ReleaseSafe build, I found these errors in the lists:

| # | architecture | the error | what the build did |
|---|---|---|---|
| 1 | aarch64, x86_64, riscv64 | The message register (`x1`, `rsi`, `a1`) is the input, the output and a clobber | It did not load the input. The switch read the value that the register held before. This is #35724 |
| 2 | aarch64 | The list names `x30` and not `lr` | It kept a loop counter in `x30` across the switch. The LLVM of Zig 0.16.0 and 0.17.1 ignores `~{x30}` (issue 2) |
| 3 | aarch64, not Darwin | The list does not name `x18` | On Linux it kept a loop counter in `x18` across the switch |
| 4 | aarch64 | The list does not name `nzcv` | It kept the flags of a comparison across the switch. #35724 notes this |
| 5 | x86_64 | The list names `zmm0` to `zmm31`, and no `xmm` register | For a target with no AVX-512, LLVM ignores the `zmm` names. It kept an `f64` value in `xmm0` across the switch |
| 6 | aarch64 with SVE | The list names `ffr` | LLVM prints `warning: inline asm clobber list contains reserved registers: FFR` |

I ran no riscv64 program. A riscv64 ReleaseSafe build of std's switch has no `mv a1, a0` before
`ld a0, 0(a1)`.

**What should happen.** Each value of the caller has the same value after the switch, in each
build mode.

**Reproduction.** This program uses `std.Io.fiber.contextSwitch` itself. It starts a fiber on a
static stack, and runs one case:

- `message`: a naked function clears `x1` or `rsi`, then jumps to a function that holds the
  switch. The switch must load its message from its argument.
- `counting`: each side keeps a loop counter across 100,000 switches.
- `float`: each side keeps an `f64` sum across 64 switches.
- `flags`: each side compares two values, switches, and uses the result again.

```zig
const std = @import("std");
const builtin = @import("builtin");
const fiber = std.Io.fiber;

var stack: [64 * 1024]u8 align(16) = undefined;
var main_context: fiber.Context = undefined;
var fiber_context: fiber.Context = undefined;
var to_fiber: fiber.Switch = undefined;
var to_main: fiber.Switch = undefined;
var mail: usize = 0; // the address of the data that a fiber reads

/// Starts a fiber at `entry`, which takes its data from `mail` and never returns.
fn start(entry: *const fn () callconv(.c) noreturn, data: usize) void {
    mail = data;
    const end = @intFromPtr(&stack) + stack.len;
    fiber_context = switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = end, .fp = 0, .pc = @intFromPtr(entry) },
        .x86_64 => .{ .rsp = end - 8, .rbp = 0, .rip = @intFromPtr(entry) },
        else => @compileError("aarch64 and x86_64 only"),
    };
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
}

// message: x1 or rsi holds 0 when the function with the switch starts.
fn switch_function(s: *const fiber.Switch) callconv(.c) void {
    _ = fiber.contextSwitch(s);
}
fn clear_then_switch() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("mov x1, xzr\n b %[f]"
            :
            : [f] "X" (&switch_function),
        ),
        .x86_64 => asm volatile ("xorl %%esi, %%esi\n jmp %[f:P]"
            :
            : [f] "X" (&switch_function),
        ),
        else => unreachable,
    }
}
fn switch_cleared(s: *const fiber.Switch) void {
    const call: *const fn (*const fiber.Switch) callconv(.c) void = @ptrCast(&clear_then_switch);
    call(s);
}
fn message_fiber() callconv(.c) noreturn {
    while (true) switch_cleared(&to_main);
}
fn message() bool {
    start(&message_fiber, 0);
    switch_cleared(&to_fiber);
    return true;
}

// counting: a loop counter on each side.
fn counting_fiber() callconv(.c) noreturn {
    const count: *usize = @ptrFromInt(mail);
    for (0..100_000) |_| {
        count.* += 1;
        _ = fiber.contextSwitch(&to_main);
    }
    unreachable;
}
fn counting() bool {
    var count: usize = 0;
    start(&counting_fiber, @intFromPtr(&count));
    for (1..100_001) |round| {
        _ = fiber.contextSwitch(&to_fiber);
        if (count != round) return false;
    }
    return true;
}

// float: an f64 sum on each side.
fn float_fiber() callconv(.c) noreturn {
    const half: *f64 = @ptrFromInt(mail);
    var sum: f64 = 0;
    for (0..64) |round| {
        sum += @as(f64, @floatFromInt(3 * round + 7)) / 2;
        half.* = sum;
        _ = fiber.contextSwitch(&to_main);
    }
    unreachable;
}
fn float() bool {
    var half: f64 = 0;
    start(&float_fiber, @intFromPtr(&half));
    var sum: f64 = 0;
    for (0..64) |round| {
        _ = fiber.contextSwitch(&to_fiber);
        sum += @as(f64, @floatFromInt(3 * round + 7)) / 2;
        if (sum != half) return false;
    }
    return true;
}

// flags: a comparison before the switch, used again after it. The fiber compares the other way.
const Flags = struct {
    left: u64,
    right: u64,
    low: u64 = 111,
    high: u64 = 999,
    before: u64 = 0,
    after: u64 = 0,
    fiber_before: u64 = 0,
    fiber_after: u64 = 0,
};
fn flags_fiber() callconv(.c) noreturn {
    const f: *volatile Flags = @ptrFromInt(mail);
    for (0..64) |_| {
        const left = f.right;
        const right = f.left;
        const low_before = f.low;
        const high_before = f.high;
        const less = left < right;
        f.fiber_before = if (less) low_before else high_before;
        _ = fiber.contextSwitch(&to_main);
        const low = f.low;
        const high = f.high;
        f.fiber_after = if (less) low else high;
    }
    unreachable;
}
noinline fn flags_round(f: *volatile Flags) void {
    const left = f.left;
    const right = f.right;
    const low_before = f.low;
    const high_before = f.high;
    const less = left < right;
    f.before = if (less) low_before else high_before;
    _ = fiber.contextSwitch(&to_fiber);
    const low = f.low;
    const high = f.high;
    f.after = if (less) low else high;
}
fn flags() bool {
    var storage: Flags = .{ .left = 1, .right = 2 };
    const f: *volatile Flags = &storage;
    start(&flags_fiber, @intFromPtr(f));
    for (0..64) |round| {
        f.left = 1 + round % 2;
        f.right = 2 - round % 2;
        flags_round(f);
        if (f.after != @as(u64, if (round % 2 == 0) 111 else 999)) return false;
    }
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(std.heap.page_allocator);
    const name = if (args.len == 2) args[1] else "";
    const ok = if (std.mem.eql(u8, name, "message"))
        message()
    else if (std.mem.eql(u8, name, "counting"))
        counting()
    else if (std.mem.eql(u8, name, "float"))
        float()
    else if (std.mem.eql(u8, name, "flags"))
        flags()
    else
        std.process.exit(2);
    std.debug.print("{s}: {s}\n", .{ name, if (ok) "PASS" else "FAIL" });
    if (!ok) std.process.exit(1);
}
```

```sh
zig build-exe fiber_switch.zig -O ReleaseSafe
for case in message counting float flags; do ./fiber_switch "$case"; echo "exit status $?"; done
```

**Results** on an Apple M1 Pro. aarch64 Linux ran in Docker. Each x86_64 program ran under
Rosetta, in Docker or on macOS, so a real x86_64 processor did not run it. Each Debug build
passed each case, with both Zig versions.

| target | Zig | `message` | `counting` | `float` | `flags` |
|---|---|---|---|---|---|
| aarch64-macos, ReleaseSafe | 0.16.0 | Segmentation fault at address 0x0 | panic: reached unreachable code | panic: reached unreachable code | FAIL |
| aarch64-macos, ReleaseSafe | 0.17.1 | Segmentation fault at address 0x0 | PASS | panic: reached unreachable code | FAIL |
| aarch64-linux-musl, ReleaseSafe | 0.16.0 and 0.17.1 | Segmentation fault at address 0x0 | Segmentation fault at address 0x8 | Segmentation fault at address 0x5 | Segmentation fault at address 0x50 |
| x86_64-linux-musl, baseline, ReleaseSafe | 0.16.0 and 0.17.1 | Segmentation fault at address 0x0 | PASS | FAIL | PASS |
| x86_64-macos, baseline, ReleaseSafe | 0.16.0 and 0.17.1 | Segmentation fault at address 0x0 | PASS | FAIL | PASS |

On aarch64 several errors act together, so a case can crash in place of a FAIL.

**Which entry of the list causes which failure.**

The attached `std_switch.zig` holds a copy of std's function with the clobber list as a comptime
parameter. It runs six cases with std's function, with the copy and std's list, with a corrected
list, and with the corrected list less one correction. The corrected list is std's list with
these changes: no `x1` or `rsi`, and `lr`, `nzcv`, `x18` (not on Darwin) and `xmm0` to `xmm15`
added.

For each Zig version I compared 48 pairs of runs: 4 targets, 2 modes and 6 cases. In each pair,
the copy with std's list ended with the same exit status as std's function. Each Debug build
passed each case. The ReleaseSafe failures, the same with Zig 0.16.0 and 0.17.1:

| list | aarch64-macos | aarch64-linux-musl | x86_64-linux-musl and x86_64-macos (Rosetta) |
|---|---|---|---|
| std's | each case fails but `float` | each case fails or crashes | `message`, `float` and `f80` fail |
| corrected | each case passes | each case passes | `f80` fails: no clobber name covers the x87 registers (issue 2) |
| corrected, with `x1` or `rsi` back | `message`: Segmentation fault at address 0x0 | `message`: Segmentation fault at address 0x0 | `message`: Segmentation fault at address 0x0, and `f80` |
| corrected, without `lr` | `counting`, `values` and `f80` fail | `counting`, `values` and `f80` fail | not applicable |
| corrected, without `x18` | not applicable: neither list names `x18` on macOS | `counting` and `values` fail, `f80` crashes | not applicable |
| corrected, without `nzcv` | `flags` fails | `flags` fails | not applicable |
| corrected, without `xmm0` to `xmm15` | not applicable | not applicable | `float` and `f80` fail |
| corrected, with `st0` to `st7` added | not applicable | not applicable | `f80` fails |

The cases `values` and `f80` of `std_switch.zig` keep integer locals and an `f80` sum across the
switch. On aarch64 an `f80` value is computed in general registers.

**Disassembly.** Each excerpt is a ReleaseSafe build with Zig 0.16.0. Zig 0.17.1 gives the same
instructions.

Error 1. A function that holds std's switch never moves its argument from `x0` to `x1`, or from
`rdi` to `rsi`:

```asm
// export fn std_switch_function(s: *const std.Io.fiber.Switch) void { _ = std.Io.fiber.contextSwitch(s); }
// aarch64-linux-musl
	add	x29, sp, #64
	ldp	x0, x2, [x1]
	ldr	x3, [x2, #16]
// x86_64-linux-musl, baseline
	mov	rbp, rsp
	...
	mov	rax, qword ptr [rsi]
	mov	rcx, qword ptr [rsi + 8]
```

In `std_switch.zig`, the same function with the corrected list holds `mov x1, x0` before
`ldp x0, x2, [x1]`.

Errors 2 and 3. The fiber of the case `counting` in `std_switch.zig`, with the copy and std's
list:

```asm
// aarch64-macos: the loop counter is in x30 across the switch
	mov	w30, #0x86a0            ; =34464
	movk	w30, #0x1, lsl #16
	...
	mov	sp, x4
	br	x3
	ldr	x9, [sp, #0x8]
	subs	x30, x30, #0x1
// aarch64-linux-musl: the loop counter is in x18 across the switch
	mov	w18, #0x86a0            // =34464
	movk	w18, #0x1, lsl #16
	...
	mov	sp, x4
	br	x3
	subs	x18, x18, #0x1
```

Error 4. `flags_round` in `std_switch.zig` on aarch64-linux-musl, with the corrected list less
`nzcv`. The `csel` after the switch uses the flags of the `cmp` before it:

```asm
	cmp	x8, x9
	csel	x8, x10, x11, lo
	...
	br	x3
	ldr	x10, [sp, #0x8]
	ldr	x8, [x10, #0x40]
	ldr	x9, [x10, #0x48]
	csel	x8, x8, x9, lo
```

Error 5. The fiber of the case `float` in `std_switch.zig`, with the copy and std's list, for
`-mcpu=baseline`. The sum stays in `xmm0` across the jump:

```asm
	addsd	%xmm5, %xmm0
	movsd	%xmm0, 0x8(%rax)
	...
	jmpq	*0x10(%rcx)
	movq	-0x38(%rbp), %rcx
```

Error 5 has a second form. For `-mcpu=x86_64_v4-evex512` (Zig 0.16.0; Zig 0.17.1 has no feature
`evex512`), std's list leaves two 256-bit values in `ymm0` and `ymm1` across the switch. With
`xmm0` to `xmm15` added, the build keeps them in `ymm16` and `ymm17`. With `xmm0` to `xmm31`
added, the build keeps none of them in a register. This is from the disassembly only.

Error 6. The command and its output:

```sh
zig build-obj lowering.zig -target aarch64-linux-musl -mcpu=generic+sve -O ReleaseSafe
```

```text
warning: inline asm clobber list contains reserved registers: FFR
note: Reserved registers on the clobber list may not be preserved across the asm statement, and clobbering them may lead to undefined behaviour.
```

LLVM prints the message when it generates code, and the command writes `lowering.o`. With
`-fno-emit-bin` and no other output, the compile prints nothing. The same message comes for
`-mcpu=neoverse_v1`, in Debug and in ReleaseSafe, with both Zig versions. LLVM reserves FFR, so
its register allocator never keeps a value there, and the name protects nothing. The same holds
for `x18` where LLVM reserves it: on Darwin, Android, OpenHarmony, Fuchsia, UEFI and Windows, and
for a CPU with the feature `reserve_x18`. A list that names `x18` there prints
`warning: inline asm clobber list contains reserved registers: X18`. I found these targets with
compiles of such a list with both Zig versions, and not in the source of LLVM. So the suggested
change removes `.ffr`, and names `x18` only where LLVM does not reserve it.

**Suggested change.** This is a suggested change, and not a copy of my own code. My own copy of
the switch differs from it in two places: it names `xmm0` to `xmm15`, and not `xmm0` to `xmm31`,
and it has no riscv64 list.

```diff
         .aarch64 => asm volatile (
             ...
             : .{
               .x0 = true,
-              .x1 = true,
               .x2 = true,
               ...
               .x17 = true,
+              .x18 = !x18_reserved, // see the notes below
               .x19 = true,
               ...
               .x30 = true,
+              .lr = true,
               ...
-              .ffr = true,
+              .nzcv = true,
               .memory = true,
             }),
         .riscv64 => asm volatile (
             ...
-              .x11 = true,
             ...
         .x86_64 => asm volatile (
             ...
-              .rsi = true,
               ...
               .zmm31 = true,
+              .xmm0 = true,
+              ...
+              .xmm31 = true,
               .fpsr = true,
```

Notes on the change:

- `.lr` is necessary while LLVM ignores `~{x30}`. Issue 2 asks the backend to lower `.x30` to
  `~{lr}`.
- `x18_reserved` is true on Darwin, Windows, UEFI and Fuchsia, on Android and OpenHarmony
  (`abi.isAndroid()` and `abi.isOpenHarmony()`), and for a CPU with the feature `reserve_x18`. My
  own copy uses that condition. A compile for each of those targets
  prints no warning, and a compile for Linux with no such feature keeps the name. Nothing ran on
  those targets.
- `.ffr` goes, because LLVM reserves FFR. I compiled the change for `neoverse_n2`, and it printed
  no warning. The disassembly of a build with `.ffr` and of a build without it is the same.
- The names `xmm16` to `xmm31` come from the disassembly of the `-evex512` case alone. A baseline
  build accepts them with no message. No program with them ran.
- I did not test the riscv64 line.
- No clobber name covers the x87 registers (issue 2). A caller can keep an `f80` value across
  the switch on x86_64, with this change too. My own code calls the switch as a function that is
  never inlined on x86_64, so the calling convention covers those registers. I did not measure
  that form for this report.

**Attachments:** `fiber_switch.zig`, `std_switch.zig`, `lowering.zig`, `wide.zig`.

**Related:** #35724 (error 1 and a note on error 4), #31284 and LLVM PR
<https://github.com/llvm/llvm-project/pull/167783> (error 2), issue 2 of this report.
