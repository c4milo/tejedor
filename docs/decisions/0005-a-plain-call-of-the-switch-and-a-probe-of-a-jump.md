# 5. A plain call of the switch, and a probe of a jump

Status: **accepted**. Camilo ruled on 2026-11-13, in a second round that day, after the first CI
run of the probe on a real x86-64 processor. The session wrote this record the same day, with the
changes. The rulings are Camilo's. The reasons against each alternative below are the session's,
and Camilo has not read them.

## The question

The probe ran in CI on 2026-11-13, at `ded6989`, on a GitHub runner with an x86-64 processor. One
switch to a fiber and one switch back took these times. They are CI numbers, from one run on a
hosted runner, and no number of a quiet machine:

| form | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| a call of `switch_context`, the form of the package on x86-64 | 19.3 | 21.3 | 18.9 |
| a copy of the switch in the caller, the other form | 2.89 | 4.04 | 2.88 |
| one call of an empty function, beside each form | 1.35 | 2.13 and 2.05 | 1.35 |

| | |
|---|---|
| machine | `github`: an AMD EPYC 9V74, Zen 4, with AVX-512, 4 processors, 16 GiB memory |
| system | Linux 7.0.0-1017-azure |
| run | CI run 43383643761, job "Linux x86-64, the probe of the switch", started by hand |
| command | `zig build bench-switch -- --machine github`, ReleaseSafe |
| load average | 0.71 before the run and after it |

Camilo asked why the switch is never inlined on x86-64. The session answered with record 3:

- The clobber type of Zig 0.16.0 has no name that works for the x87 registers. Zig writes
  `~{st0}`, and LLVM moves an x87 value only for `~{st}` (record 2).
- It has no name for `k0` to `k7`, and none for `r16` to `r31`. It has names for `xmm16` to `xmm31`,
  and the list does not hold them (record 2).
- System V makes each of these registers caller-saved. So a call of the switch covers them.
- With a copy of the switch, a ReleaseSafe test lost an `f80` value on x86-64 Linux, under Rosetta
  (record 3).

The answer that Camilo read put `xmm16` to `xmm31` among the registers with no working name. The
clobber type names them, and the list does not hold them. The second bullet above corrects that.

## The decision

Camilo ruled on 2026-11-13. The first ruling is in his words: "Call, and probe a jump."

1. **`switch_context` itself has the form of record 3.** A plain call of it is a copy on aarch64
   and a call on x86-64. `call_modifier` goes.
   - On aarch64 `switch_context` is `switch_copied`, an inline function that holds the assembly.
     Each caller holds a copy of it, in Debug and in ReleaseSafe.
   - On x86-64 `switch_context` is `switch_called`, a function that is never inlined. Each caller
     calls it, in Debug and in ReleaseSafe.
   - `switch_other_form` has the form that the package does not use on an architecture: a call on
     aarch64, and a copy on x86-64. Only the tests and the probe name it. The names
     `switch_copied`, `switch_called` and `switch_other_form` are a choice of the session (below).
2. **The aarch64 list does not name `ffr`.** A record states the departure from std's list.

The assembly of the switch does not change.

## 1. The form is in the declaration of `switch_context`

### What changes

Record 3 put the form in `call_modifier`, a value that each caller passed to `@call`. A caller that
forgot it made a plain call, and the compiler chose the form. On x86-64 in ReleaseSafe the compiler
can choose a copy, and a copy loses an `f80` value.

Now the declaration holds the form. Zig refuses a call that asks for the other form, at compile
time:

| architecture | `switch_context` is | a call that does not compile | the error of Zig 0.16.0 |
|---|---|---|---|
| aarch64 | `inline fn switch_copied` | `@call(.never_inline, switch_context, ...)` | `cannot perform inline call with 'never_inline' modifier` |
| x86-64 | `noinline fn switch_called` | `@call(.always_inline, switch_context, ...)` | `inline call of noinline function` |

Zig 0.16.0 refuses one function that is both `noinline` and of the calling convention `inline`.
So the file holds two functions, and `switch_context` names the one of the architecture.
`switch_copied` holds the assembly, and `switch_called` holds a copy of it.

### The checks

- **`src/switch_test_form.zig`**, "a plain call of the switch is a copy on aarch64 and a call on
  x86_64". A switch saves the address to resume at. With a copy, that address is in the caller,
  between the return addresses of a call before the switch and a call after it. With a call, it is
  in `switch_context`, within 256 bytes of its start. The test reads the address, and checks
  the form of the architecture.
- **`tools/compile_fail/switch_copy_on_x86_64.zig`** asks for a copy on x86-64 Linux, and
  **`tools/compile_fail/switch_call_on_aarch64.zig`** asks for a call on aarch64 Linux.
  `zig build test-compile-fail` requires the error of Zig for each one (`build/switch_checks.zig`).
- **The lint rule `switch-form`** (`tools/lint/switch_form.zig`) refuses a reference to
  `switch_other_form` in each file under `src/` but `src/switch.zig` and the test files. Its header
  lists the references that it cannot see, such as an `@import` written in place. A plain call of
  that name is a copy on x86-64, which loses an `f80` value. The probe is under `bench/`, which the
  rule does not read.

### What the compiler builds

The session built the tests of the switch in ReleaseSafe on 2026-11-13, for three targets, and read
the disassembly of `objdump -d`. A branch to a register, `br x3`, is the last instruction of a copy
on aarch64.

| target | callers | what each holds |
|---|---|---|
| aarch64 macOS | `flags_round`, `extended_fiber`, `counting_fiber`, `switch_between_marks` | the switch, with `br x3`, and no call of a switch function |
| aarch64 Linux | the same four | the same |
| x86-64 Linux | the same four | `callq switch.switch_called`, and no copy of the switch |
| x86-64 Linux | `extended_fiber` | `fstpt` puts the `f80` sum on the stack before the call, and `fldt` loads it after the call |

On x86-64 Linux `switch_called` saves `rbp`, `rbx` and `r12` to `r15`, then runs the nine
instructions of the switch. The address to resume at is 51 bytes after its start in ReleaseSafe,
and 69 bytes in Debug.

### The mutations

The session ran each mutation of the form on 2026-11-13, after `switch_other_form` came. Each
cell of a platform gives Debug, then ReleaseSafe. C is CAUGHT, n is NOT CAUGHT, and a dash is a
build that did not run. The x86-64 Linux runs were in Docker on `mac`, under Rosetta. The last
column is the step `zig build test-compile-fail` on `mac`.

| mutation | aarch64 macOS | x86-64 Linux | `test-compile-fail` |
|---|---|---|---|
| none | pass, pass | pass, pass | pass |
| `switch_called` is not `noinline` | - | n, C | C |
| `switch_context` is `switch_copied` on x86-64 | - | C, C | C |
| `switch_context` is `switch_called` on aarch64 | C, C | - | C |
| `switch_copied` is not `inline` | C, n | - | C |

The session ran the mutations of the lists before `switch_other_form` came. The aarch64 list
changed after that run: `ffr` went, and `x18` reads `x18_reserved`. On the targets that ran these
mutations, the list names the same registers but `ffr`. LLVM reserves `ffr`, and the name changes
no instruction (section 2). The mutations of the lists:

| mutation | aarch64 macOS | aarch64 Linux | x86-64 Linux |
|---|---|---|---|
| `nzcv` out of the list | n, C | -, C | - |
| `lr` out | -, C | -, C | - |
| `x1` back in the list | -, C | -, C | - |
| `x18` out | - | -, C | - |
| `x19` out | n, C | C, C | - |
| `z8` and `z9` out | C, C | - | - |
| `z0` out | -, C | -, C | - |
| `rsi` back in the list | - | - | -, C |
| `rbx` out | - | - | C, C |
| `r15` out | - | - | -, C |
| `xmm0` to `xmm15` out | - | - | -, n |

The session ran the mutations of the lint rule `switch-form` on `mac`:

| mutation | `zig build lint` | `zig build test-tools` |
|---|---|---|
| none | pass | pass |
| `src/tejedor.zig` names `switch_other_form` | C | - |
| the rule looks for another name | C | C |
| the rule reads the test files | C | C |

How to read the tables:

- With `switch_called` a plain function, a Debug build still calls it, and a ReleaseSafe build
  copies it. With `switch_copied` a plain function, a Debug build calls it, and a ReleaseSafe build
  still copies it. So one mode of each is NOT CAUGHT by the tests. `test-compile-fail` catches both
  mutations, because Zig then accepts the call of the other form.
- With `switch_copied` on x86-64, the tests did not compile, because they take the address of
  `switch_context`. So that mutant swaps the two forms of x86-64, and the two lines of the tests
  that take that address name `switch_other_form`. The test of the form keeps its check that the
  address to resume at is not in the caller.
- Each NOT CAUGHT of a list name in Debug is the expected result of records 2 and 3. So is each
  NOT CAUGHT of the `xmm` names under a call.
- The rule reads the test files when it loses the exclusion of their stems. It then flags
  `src/switch_test.zig`, which names `switch_other_form`.

## 2. The aarch64 list does not name `ffr`

### The error

`ffr` is the first-fault register of SVE, the scalable vector extension of aarch64. std's list
names it, and so did the list of the package. LLVM reserves `ffr`, so its register allocator never
keeps a value there. So the name protects nothing.

For a processor with SVE, LLVM printed this warning for each copy of the switch:

```text
warning: inline asm clobber list contains reserved registers: FFR
```

GitHub's runner of Linux on arm64 has SVE. In the CI run 43383643761, the log of the job "zig
build test, Linux arm64" holds the warning 58 times, in five compiles. The build printed the first
warning of each compile as `error: warning:`, and the job passed. The two other test jobs of that
run hold no such warning.

A review of the session found the same fault for `x18` on 2026-11-13. The list named `x18` on
each system but those of Apple. LLVM also reserves `x18` on Android, OpenHarmony, Fuchsia, UEFI
and Windows, and for a processor with the feature `reserve_x18`. A compile of the switch for such
a target printed the warning for `X18`. The list now names `x18` only where LLVM does not reserve
it. So Linux and the BSDs keep the name, which the third correction of rotor's decision 22 needs.
A later review of the same day found that the first fix left out OpenHarmony. The ruling names
`ffr` alone, so the change for `x18` is a choice of the session (the end of this record).

### The check

`zig build test-reserved` builds `tools/switch_reserved.zig`, a copy of the switch, for eight
aarch64 targets. The standard error of each compile must be empty:

| target | processor | the register that LLVM reserves |
|---|---|---|
| Linux | `neoverse_n2`, which has SVE | `ffr` |
| macOS | `baseline` | `x18` |
| Android | `baseline` | `x18` |
| OpenHarmony | `baseline` | `x18` |
| Fuchsia | `baseline` | `x18` |
| UEFI | `baseline` | `x18` |
| Windows | `baseline` | `x18` |
| Linux | `baseline`, with the feature `reserve_x18` | `x18` |

The step runs the compiler as a command, because a compile step of the build passes a warning
(`build/switch_checks.zig`). `zig build test` runs it.

### What the compiler builds

The session built the tests of the switch with `ffr` in the aarch64 list and without it, on
2026-11-13, and compared the disassembly of `objdump -d`:

| target | processor | mode | FFR warnings with `ffr` | without `ffr` | disassembly |
|---|---|---|---:|---:|---|
| aarch64 macOS | the M1 Pro of `mac`, no SVE | ReleaseSafe | 0 | 0 | the same |
| aarch64 Linux | `baseline`, no SVE | ReleaseSafe | 0 | 0 | the same |
| aarch64 Linux | `neoverse_n2`, with SVE | Debug | 24 | 0 | the same |
| aarch64 Linux | `neoverse_n2`, with SVE | ReleaseSafe | 24 | 0 | the same |

So the name changes no instruction, on a processor with SVE and on one with none. The executables
of each pair differ in other bytes. The two trees had different paths, and the session did not
read where the bytes differ.

### The mutations

The session ran each mutation on 2026-11-13, on `mac`.

| mutation | `zig build test-reserved` on `mac` |
|---|---|
| none | pass |
| `ffr` back in the aarch64 list | C |
| `x18` named on each system but those of Apple, as before | C |
| `x18` named on Windows | C |
| `x18` named on UEFI | C |
| `x18` named on Fuchsia | C |
| `x18` named on Android | C |
| `x18` named on OpenHarmony | C |
| `x18` named on the systems of Apple | C |
| `x18` named for a processor with the feature `reserve_x18` | C |

## Alternatives that lost

These alternatives are the session's list. The session wrote it after the ruling, and Camilo has
not read it.

1. **Keep `call_modifier`.** A caller that forgets it makes a plain call. On x86-64 in ReleaseSafe
   the compiler can then copy the switch, and no check refuses that call.
2. **A copy on x86-64 too.** It is the fast form on the EPYC in the loop of the probe: 2.89 ns
   against 19.3 ns, CI numbers. It loses an `f80` value, and it can lose a value in `k0` to `k7`,
   `xmm16` to `xmm31` or `r16` to `r31` (record 3).
3. **Replace the call on x86-64 with a switch in assembly that saves the callee-saved registers
   itself, as Boost.Context does.** No number shows that it is faster than the call. Ruling 1 makes
   it a candidate of the probe first.
4. **Two names, one for each form, for the package to choose from.** Each caller of step 1 then
   chooses a form, and a wrong choice compiles. `switch_other_form` is a second name, and the lint
   rule `switch-form` refuses it in the package.

For the second ruling, these alternatives lost:

1. **Keep `ffr`, as std's list has it.** The name protects nothing, and each compile for a
   processor with SVE prints one warning for each copy of the switch.
2. **Name `ffr` only for a target with no SVE.** LLVM reserves `ffr` there too, so the name
   protects nothing there either.
3. **Remove `ffr`, with no check.** A later copy of std's list could bring the name back, and only
   a compile for a processor with SVE shows it.

## What departs from std and from rotor's decision 34

- **std.** std's `contextSwitch` is an `inline fn`, so each caller of std holds a copy, on each
  architecture. The package keeps that form on aarch64, with `switch_copied`. It departs from it on
  x86-64 with `switch_called`, a function that is never inlined.
- **std's list.** The aarch64 list does not name `ffr`, and std's list does. That is the sixth
  change of the lists. It removes a name, as the first change did. The list also names `x18` only
  where LLVM does not reserve it. The header of `src/switch.zig` lists each change.
- **rotor's decision 34, "Where the code starts".** It takes the switch with "nothing but the
  names" changed. Records 2 to 4 departed from that sentence. This record adds the two functions of
  the form, `switch_other_form`, and the list with no `ffr`.

Row L3 of `docs/hot-path-ledger.md` holds the forced inline of aarch64. The package changes no file
of rotor.

## Choices of the session that Camilo has not ruled

- **The names.** `switch_other_form` is public in `src/switch.zig`, and `switch_called` and
  `switch_copied` are private. `switch_out_of_line` is public in
  `src/switch_test.zig`. The probe takes `src/switch.zig` as a module of its own
  (`build/bench.zig`), so it needs a public name. The module `tejedor` exports no name of
  `src/switch.zig`.
- **The lint rule `switch-form`**, which keeps `switch_other_form` out of the package.
- **`x18` where LLVM reserves it.** Ruling 2 names `ffr`, and the session applied its reason to
  `x18`. On Android, OpenHarmony and Fuchsia, `x18` points to the shadow call stack of the thread,
  for code built with one. The switch does not swap it, so the fibers of a thread share one
  shadow call stack. Camilo may rule that `supported` is false there.
- **The step `test-reserved`**, and its eight targets.

## Sources

- The CI run 43383643761 of 2026-11-13, job "Linux x86-64, the probe of the switch", at `ded6989`.
- `std/Io/fiber.zig` and `std/builtin/assembly.zig` of Zig 0.16.0.
- Records 2 and 3, and rotor's decision 34 at `128b8da`.
