# 3. The switch is a copy on aarch64 and a call on x86-64

Status: **accepted**. Camilo ruled on 2026-11-13, on the form of the call and on the control
registers. The session wrote this record the same day, with the change. The rulings are Camilo's.
The reasons against each alternative below are the session's, and Camilo has not read them.

Note of 2026-11-13, second round: record 5 keeps the two forms of this record, and removes
`call_modifier`. The declaration of `switch_context` now holds the form. A plain call of it is a
copy on aarch64 and a call on x86-64. Zig refuses a call that asks for the other form. The
parts below that name `call_modifier` give the state of the first round.

Note of 2026-11-14: record 6 replaces the call of x86-64 with a call of the jump, a function in
assembly that saves the callee-saved registers itself. Each caller still calls a function, so the
calling convention still covers the x87 registers, `k0` to `k7` and `r16` to `r31`. Decision 1 of
this record holds as it is. On x86-64, decision 2 holds for the jump, and std's call and copy left
`src/switch.zig` for `bench/std_switch_x86_64.zig`. Decision 3 holds for both architectures. The
parts below that name the x86-64 list or `switch_context` on x86-64 give the state before record
6.

## The decision

1. **On aarch64 the clobber list names `nzcv`, and each caller holds a copy of the switch.** This
   is the fifth correction of std's clobber lists. Each test that proves a name of the list calls
   the switch in that form. So the proof does not depend on a choice of the optimizer. In the first
   round `call_modifier` was `.always_inline`, and each caller passed it to `@call`. Since record 5
   `switch_context` is an inline function on aarch64.
2. **On x86-64 each caller calls `switch_context`, and the compiler never inlines the call.** The
   calling convention then covers each register that the clobber type of Zig 0.16.0 cannot name.
   The x86-64 list stays as it is, with the `xmm` names of record 2. In the first round
   `call_modifier` was `.never_inline`. Since record 5 `switch_context` is a function that is
   never inlined on x86-64.
3. **The rounding mode and the exception masks belong to the thread.** The switch saves no
   control register. A fiber that changes one restores it before it blocks.

The assembly of the switch does not change.

## The errors

A clobber list tells the compiler which registers a block of assembly changes. Where a caller
holds a copy of the switch, the compiler can keep a value of the caller in a register across the
switch. If the list misses that register, the context that runs in between changes the value.

A review of 2026-11-12 found these errors, and a second session measured each one again:

| what the list does not cover | target | what showed it |
|---|---|---|
| `nzcv`, the condition flags of aarch64 | aarch64 macOS and aarch64 Linux | a test failed in ReleaseSafe |
| the x87 registers, which hold an `f80` value | x86-64 | a test failed in ReleaseSafe, under Rosetta |
| `k0` to `k7`, the mask registers of AVX-512 | x86-64 with AVX-512 | the disassembly of a ReleaseSafe build, and nothing ran |
| `r16` to `r31` of APX | x86-64 with the feature `egpr`, as the CPU model `diamondrapids` has it | the disassembly, and nothing ran |
| `xmm16` to `xmm31` | x86-64 with AVX-512VL and no 512-bit registers | the disassembly, and nothing ran |

The clobber type of Zig 0.16.0 has no name for `k0` to `k7`, and none for `r16` to `r31`. It has
the names `st0` to `st7`, and they have no effect. Record 2 gives the reason.

The review found one more fault: the proof of a list needed the copy, and no test made the copy.
Where a caller calls the switch, the calling convention covers each register that the function
does not save. Then a test cannot catch a wrong entry for such a register. In each ReleaseSafe
test of 2026-11-12 the compiler chose the copy. A later Zig can choose the call, and no test then
fails.

## The measured failures

The tests are in `src/switch_test.zig`. The runs with no `nzcv` and the runs of a copy on x86-64
were on 2026-11-12. The other runs were on 2026-11-13, with this change. Each ran on `mac`. The
x86-64 runs were in Docker, where OrbStack runs an x86-64 executable with Rosetta.

| the switch | test | platform | mode | result |
|---|---|---|---|---|
| a copy, and no `nzcv` | "a comparison before a switch decides the same way after the switch" | aarch64 macOS and aarch64 Linux | ReleaseSafe | fail: expected 111, found 999 |
| a copy, and no `nzcv` | the same | aarch64 macOS and aarch64 Linux | Debug | pass |
| a copy, with `nzcv` | the same | aarch64 macOS and aarch64 Linux | Debug and ReleaseSafe | pass |
| a copy | "the main context and a fiber each keep an f80 value across a switch" | x86-64 Linux | ReleaseSafe | fail: expected 7, found 3.5 |
| a copy, with `st0` to `st7` | the same | x86-64 Linux | ReleaseSafe | fail: expected 7, found 3.5 |
| a call | the same | x86-64 Linux | Debug and ReleaseSafe | pass |

## What the compiler builds

The session built the tests of the switch in ReleaseSafe on 2026-11-13, for three targets, and read
the disassembly of `objdump -d`. In the table, a branch to a register is the last instruction of
the switch: `br x3` on aarch64.

| target | function | what it holds |
|---|---|---|
| aarch64 macOS | `flags_round` | the switch, with `br x3`, and no call. A `cmp` comes after the switch, so the compiler compares again |
| aarch64 Linux | `flags_round` | the same |
| aarch64 macOS and aarch64 Linux | `extended_fiber` | the switch, with `br x3`, and no call |
| x86-64 Linux | `flags_round` | `callq switch.switch_context`, and no copy of the switch |
| x86-64 Linux | `extended_fiber` | `fstpt` puts the `f80` sum on the stack before `callq switch.switch_context`, and `fldt` loads it after the call |

So aarch64 copies the switch into each caller, and x86-64 calls it.

## Alternatives that lost

Camilo chose from these on 2026-11-13. The probe numbers below are from `bench/results/`: busy
runs of 2026-11-12 on an Apple M1 Pro, and no final numbers. A pair is one switch to a fiber and
one switch back.

| form | `mac`, median of four runs, ns | `orbstack`, median of four runs, ns |
|---|---:|---:|
| a copy of the switch in the caller | 4.85 to 5.02 | 4.88 to 5.20 |
| a call of `switch_context` | 27.6 to 54.4 | 29.0 to 29.6 |

1. **A copy on both architectures, with `nzcv` named.** On x86-64 no name of the clobber type
   covers the x87 registers, `k0` to `k7` or `r16` to `r31`. So a fiber on x86-64 could lose such
   a value at each call that blocks.
2. **A call on both architectures.** It covers each error by the calling convention. On aarch64
   it costs a call in each pair, by the table above. It also takes the proof from the aarch64
   list: with a call, the review's mutation that takes `lr` out of the list was NOT CAUGHT.
3. **A copy on x86-64, with a guard.** A comptime check refuses a target with AVX-512 or with
   `egpr`, and a rule forbids an `f80` value across a switch. The check refuses each processor
   with AVX-512, and no test can hold the rule.
4. **Name `xmm16` to `xmm31` in the list.** It covers one row of the errors alone.
5. **Leave the form to the compiler, as before.** The tests then prove the list only where the
   compiler copies the switch.

No real x86-64 processor ran the probe before this ruling, so the table gives no number for
the call on x86-64. Record 5 gives the first run in CI, on an x86-64 processor, later that day.

## What departs from std and from rotor's decision 34

- **std.** The aarch64 list names `nzcv`, which std's list does not. That is the fifth change of
  the lists, and the header of `src/switch.zig` lists each one. std's `contextSwitch` is an
  `inline fn`, so each caller of std holds a copy, on each architecture. The package keeps that
  form on aarch64, and calls the switch on x86-64. `call_modifier` was new, and record 5 replaced it
  with the form of the declaration.
- **rotor's decision 34, "Where the code starts".** It takes the switch with "nothing but the
  names" changed. Record 2 departed from that sentence first, and this record adds `nzcv` and the
  form of the call.
- **rotor's decision 34, "Upkeep".** It counts three errors of std's lists. The package now
  corrects five, and it covers the registers of the table above with a call on x86-64.
- **rotor's decision 34, "The fiber switch has no measured cell".** rotor's probe measured an
  `inline` copy of the switch. On x86-64 the package now calls the switch. One CI run measured
  that call on a real x86-64 processor, and record 5 gives it.

A forced inline is ugly code, so row L3 of `docs/hot-path-ledger.md` holds it. Since record 5 that
row names the inline function of aarch64. The package changes no file of rotor. A note in rotor's
decision 34 that points at this record is rotor's to add.

## What a call on x86-64 does not prove

A caller keeps no value in a caller-saved register across a call. So on x86-64 no test needs a
name of a caller-saved register in the list, and a mutation that takes one out is NOT CAUGHT.
That is expected. The list keeps those names, because a list with them is correct for a copy too.
The names of the callee-saved registers keep a proof on x86-64. The function saves each one that
the list names. The test of `src/switch_test_registers.zig` catches each one that it misses.

## The mutations

The session ran each mutation on 2026-11-13, with this change in place. Each cell gives Debug,
then ReleaseSafe. C is CAUGHT, n is NOT CAUGHT, and a dash is a build that did not run. The x86-64
runs were under Rosetta.

| mutation | aarch64 macOS | aarch64 Linux | x86-64 Linux |
|---|---|---|---|
| none | pass, pass | pass, pass | pass, pass |
| `nzcv` out of the list | n, C | n, C | - |
| `lr` out | n, C | n, C | - |
| `x1` back in the list | n, C | n, C | - |
| `x18` out | - | n, C | - |
| `x19` out | n, C | C, C | - |
| `x28` out | n, C | C, C | - |
| `x19` and `x20` out | C, C | C, C | - |
| `z8` and `z9` out | C, C | C, C | - |
| `z8` out; `z15` out | n, C | C, C | - |
| each other one of `z0` to `z31` out alone, 30 mutations | -, C | -, C | - |
| `call_modifier` is a call on aarch64 | n, n | n, n | - |
| `call_modifier` is a call on aarch64, and `lr` out | -, n | -, n | - |
| `call_modifier` is a copy on x86-64 | - | - | n, C |
| `rsi` back in the list | - | - | n, C |
| `rbx` out; `r12` out; `r15` out | - | - | C, C |
| `xmm0` to `xmm15` out | - | - | n, n |
| each one of `xmm0` to `xmm15` out alone, 16 mutations | - | - | -, n |
| `zmm0` to `zmm31` out; `mm0` to `mm7` out | - | - | -, n |
| each one of `rax`, `rcx`, `rdx`, `rdi`, `r8` to `r11`, `fpsr`, `fpcr`, `mxcsr`, `rflags`, `dirflag` and `memory` out alone, 14 mutations | - | - | -, n |

The rows that name `call_modifier` are mutations of the first round. Record 5 gives the mutations
of the form that replaced it.

How to read the table:

- The test of the flags catches `nzcv` out, and the test of 32 values in
  `src/switch_test_floats.zig` catches each `z` name on aarch64 Linux too.
- A call on aarch64 is correct, so no test fails when `call_modifier` is a call there. With a call,
  the mutation that takes `lr` out is NOT CAUGHT. That is why each test calls the switch in the
  form of the package.
- On x86-64 the test of an `f80` value catches a copy in place of the call.
- Each NOT CAUGHT of a caller-saved name on x86-64 is expected, as the part above says.

## The control registers

Camilo ruled on 2026-11-13 that the rounding mode and the exception masks belong to the thread.
The switch saves no control register:

| architecture | register | what it controls |
|---|---|---|
| aarch64 | FPCR | the rounding mode, and the traps of the floating-point exceptions |
| x86-64 | MXCSR | the rounding mode and the exception masks of SSE |
| x86-64 | the x87 control word | the rounding mode, the precision and the exception masks of the x87 unit |

std's switch saves none of them, and std's `Context` has no field for one. The names `fpcr`,
`fpsr` and `mxcsr` in the clobber lists tell the compiler that the registers change. They save
nothing.

A trial of the session ran on 2026-11-13 against the switch of this record. A fiber set the
rounding mode to "toward zero" and switched back. The main context then read the register:

| register | platform | modes | before the switch | after the switch back |
|---|---|---|---|---|
| FPCR | aarch64 macOS on `mac` | Debug and ReleaseSafe | `0x00000000` | `0x00c00000`, "toward zero" |
| FPCR | aarch64 Linux in Docker | Debug and ReleaseSafe | `0x00000000` | `0x00c00000`, "toward zero" |
| MXCSR | x86-64 Linux in Docker, under Rosetta | Debug and ReleaseSafe | `0x1f80` | `0x7f80`, "toward zero" |
| the x87 control word | x86-64 Linux in Docker, under Rosetta | Debug and ReleaseSafe | `0x037f` | `0x0f7f`, "toward zero" |

So a fiber that changes a rounding mode changes it for each other fiber of the thread. It changes
it for the callbacks of the reactor too, until it restores it. A fiber that changes one restores
it before it blocks. Zig code does not change these registers. Assembly does, and C code does
with `fesetround` or `feenableexcept`.

The System V ABI of x86-64 makes the control bits of MXCSR and the x87 control word callee-saved.
AAPCS64 asks the same of the rounding mode of FPCR. Both are recalled from the ABI texts, and
the session did not read them on 2026-11-13. So a call of the switch can return with control bits
other than the caller had. The ruling accepts that.

Two alternatives lost:

1. **Save the control registers in the switch.** That adds a field to std's `Context`, and more
   instructions to each switch. No probe measured that cost.
2. **Save them in the package, around each call that blocks.** That costs the same, and the
   package changes none of them itself.

## Upkeep

A Zig upgrade runs the mutations of the lists again. If a later clobber type names the x87
registers, `k0` to `k7` and `r16` to `r31`, a copy on x86-64 can come back. That is a change of
this decision, and Camilo rules on it.

## Sources

- `std/Io/fiber.zig` and `std/builtin/assembly.zig` of Zig 0.16.0.
- The reviews of 2026-11-12, and the runs of the second session the same night. Their scripts and
  logs are outside the tree.
- `bench/results/switch-mac-2026-11-13.md` and `bench/results/switch-orbstack-2026-11-13.md`.
- rotor's decision 34 at `128b8da`.
