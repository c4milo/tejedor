# 2. The switch names the `xmm` registers of x86-64

Status: **accepted**. Camilo ruled on 2026-11-12 that the package applies this correction. This
record was written the same day, with the correction. The ruling is Camilo's. The reasons against
each alternative below are the session's, and Camilo has not read them.

Note of 2026-11-13, second round: record 5 removes `ffr` from the aarch64 list. It also makes the
switch a function that is never inlined on x86-64, by its declaration. The x86-64 list of this
record does not change.

## The decision

The clobber list of `switch_context` for x86-64 names `xmm0` to `xmm15`, beside the `zmm0` to
`zmm31` of std's list. This is the fourth correction of std's clobber lists in `src/switch.zig`.
rotor's decision 22 found the first three.

The assembly of the switch does not change, and nothing changes on aarch64.

## The error

A clobber list tells the compiler which registers a block of assembly changes. The assembly of the
switch saves three things: the stack pointer, the frame pointer and the address to resume at. So
its list must name each other register. The compiler then keeps no value in a named register
across the switch.

std 0.16.0 names the vector registers of x86-64 as `zmm0` to `zmm31`. Those are the names of
AVX-512. The baseline x86-64 processor has no AVX-512, and its floating-point registers are `xmm0`
to `xmm15`. For such a target, the optimized build acted as if the switch changed no `xmm`
register:

1. It copied the body of `switch_context` into the caller.
2. It kept an `f64` value of the caller in an `xmm` register across the switch.
3. The context that ran in between changed that register.

std's `Io/fiber.zig` is the same, byte for byte, in Zig 0.17.1.

## The measured failure

The test is "the main context and a fiber each keep a floating-point value across a switch", in
`src/switch_test.zig`. The main context and a fiber each add to an `f64` sum of their own, and
they switch to each other 64 times.

Each run below was on 2026-11-12, on `mac`, for the baseline x86-64 processor. No processor of
`mac` is x86-64, so each run was under an emulator:

- The Linux executables ran in Docker, where OrbStack runs an x86-64 executable with Rosetta.
- The macOS executables ran with the Rosetta of macOS.

| the x86-64 list | system | mode | result of the test |
|---|---|---|---|
| `zmm0` to `zmm31` alone, as std has it | Linux | Debug | pass |
| `zmm0` to `zmm31` alone, as std has it | Linux | ReleaseSafe | fail: expected 4503599627370520, found 3.5 |
| `zmm0` to `zmm31` alone, as std has it | macOS | ReleaseSafe | fail: expected 4503599627370520, found 3.5 |
| with `xmm0` to `xmm15` | Linux | Debug | pass |
| with `xmm0` to `xmm15` | Linux | ReleaseSafe | pass |
| with `xmm0` to `xmm15` | macOS | Debug | pass |
| with `xmm0` to `xmm15` | macOS | ReleaseSafe | pass |

The fault shows only in the optimized build. A Debug build calls `switch_context` as a function,
and a caller keeps no value in an `xmm` register across a call.

The test also proved each of the sixteen names. The session made the Linux run in ReleaseSafe
sixteen more times, each with one name out of the list. The test failed each time, with "expected
7, found 3.5". Since record 3 the switch is a call on x86-64, so no test can prove these names
now. Record 3 says why the list keeps them.

The first commit of the switch, `bbf51c8`, held std's list. It did not run this test for a target
with no AVX-512.

## Alternatives it beat

1. **Keep std's list, and do not run the test where the error shows.** That is the state of
   `bbf51c8`. Each x86-64 executable of the Linux gate is for the baseline processor. So on x86-64
   a fiber of step 1 could lose a floating-point value at each call that blocks.
2. **Name the `xmm` registers in place of the `zmm` registers.** A processor with AVX-512 has
   `zmm16` to `zmm31`, and no name from `xmm0` to `xmm15` covers them. The copy would also differ
   from std's list by lines that it removes. With both sets of names, the copy only adds lines.
3. **Choose the names from the features of the target, at comptime.** The compiler accepts both
   sets of names together for a target with AVX-512 and for a target with none. So a choice adds
   code and no safety.
4. **Never inline `switch_context`, and keep std's list.** A caller keeps no value in an `xmm`
   register across a real call, by the calling convention. In a trial with a `noinline` switch and
   std's list, the test passed in ReleaseSafe. But this changes how each caller reaches the
   switch, on each processor, and the probe of step 0 measures what that costs. It is a change of
   the design, and no change of a list. On 2026-11-12 Camilo did not rule on it. On 2026-11-13 he
   ruled for a call on x86-64, beside this list (record 3).
5. **Wait for a correction in std.** A release of the package pins one Zig version, and Zig
   0.17.1 has the same file.

## What departs from rotor's decision 34

rotor's decision 34 says that the package takes the switch with "nothing but the names" changed
("Where the code starts"). It also says that decision 22 found three errors in std's clobber lists
("Upkeep"). This record departs from the first sentence: the x86-64 list of the package holds
sixteen names that decision 22's list did not hold. The count of the second sentence is now four.

The package changes no file of rotor. A note in rotor's decision 34 that points at this record is
rotor's to add.

## What this correction does not cover

- **A real x86-64 processor.** Each run above was under an emulator. CI runs the tests on an
  x86-64 runner, and no push has started the CI.
- **A target with AVX-512.** The tests compile for the CPU model `x86_64_v4`, in Debug and in
  ReleaseSafe, with `xmm0` and `zmm0` both in the list. `mac` has no processor and no emulator
  that runs AVX-512, so no such test ran.
- **The mask registers of AVX-512, `k0` to `k7`.** The clobber type of Zig 0.16.0 has no name for
  them. For the CPU model `x86_64_v4`, the disassembly of an optimized trial test shows a mask in
  `k1` across the copy of the switch. No instruction saves it, and no such test ran.
- **`xmm16` to `xmm31`.** The clobber type has these names, and the list does not. They matter
  for a target with AVX-512VL and no 512-bit registers, which a person asks for with `-evex512`.
  The compiler drops the `zmm` names there, and the disassembly shows two sums in `ymm16` and
  `ymm22` across the switch. With the sixteen names in the list, the caller saved both. No CPU
  model of Zig 0.16.0 is such a target, and nothing ran.
- **`r16` to `r31` of APX.** The clobber type stops at `r15`. The CPU model `diamondrapids` has
  the feature `egpr`. For a target with that feature, the disassembly shows three values in `r16`
  to `r18` across the copy of the switch. Nothing ran.
- **An aarch64 target with SVE.** The list named `ffr`, as std's list does. For such a target the
  compiler printed a warning for each copy of the switch, because `ffr` is a reserved register.
  The tests compiled, and nothing ran. Since record 5 the list does not name `ffr`, and
  `zig build test-reserved` fails when the warning comes back.
- **Two more errors of the lists.** The session measured them on the same day, with a trial test
  for each. Record 3 corrects both, by Camilo's ruling of 2026-11-13: `nzcv` in the aarch64 list,
  and a call on x86-64.

| what the list misses | where the trial test failed, in ReleaseSafe | what a changed list did |
|---|---|---|
| the condition flags of aarch64, `nzcv` | aarch64 macOS on `mac`, and aarch64 Linux in Docker | with `nzcv` in the list, the test passed |
| the x87 registers of x86-64, which hold an `f80` value | x86-64 Linux in Docker, under Rosetta | with `st0` to `st7` in the list, the test still failed |

With a `noinline` switch and no change of a list, both trial tests passed in ReleaseSafe: on
aarch64 macOS, on aarch64 Linux and on x86-64 Linux.

The names `st0` to `st7` have no effect, and a review of 2026-11-12 found the reason. Zig 0.16.0
gives them to LLVM as `~{st0}` to `~{st7}`. LLVM 21.1.8 moves an x87 value out of its register
only for the names `~{st}` and `~{st(1)}` to `~{st(7)}`. With those names in the LLVM text of a
small function, the compiler saved the `f80` value around the block of assembly. With Zig's
names it did not. So no change of the list covers an `f80` value in Zig 0.16.0.

Since record 3, each caller on x86-64 calls the switch. The calling convention then covers each
register of this part that the list does not cover.

## Upkeep

A Zig upgrade compares std's switch with the copy of the package (rotor's decision 34, "Upkeep").
The copy now differs from std 0.16.0 in six places, and the header of `src/switch.zig` lists
them. Record 3 holds the fifth, and record 5 the sixth. If a later std names the `xmm` registers,
this correction goes.

## Sources

- `std/Io/fiber.zig` of Zig 0.16.0 and of Zig 0.17.1 on the development machine. The two files are
  byte for byte the same.
- `std/builtin/assembly.zig` of Zig 0.16.0, for the names that a clobber list can hold.
- rotor's decision 22, "How it is checked", check 1, for the first three errors.
- rotor's decision 34 at `128b8da`, "Where the code starts" and "Upkeep".
- The runs of 2026-11-12 on `mac`. The Linux runs used the pinned image of `tools/linux_test.sh`.
