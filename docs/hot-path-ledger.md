# Hot-path ledger

rotor's decision 34 keeps one rule of rotor's decision 7 for this package ("What it keeps"). Ugly
code lives only in a named file, and each use has a row in a ledger. This file is that ledger.

Ugly code is code that plain Zig does not need: assembly, a naked function, a raw pointer, a
forced inline, or a safety check that is off. A use with no row here does not land.

## The named files

| file | what it holds |
|---|---|
| `src/switch.zig` | the context switch of aarch64, the entry of a new fiber on aarch64, and the switch that each architecture uses |
| `src/switch_jump.zig` | the context switch of x86-64, the jump, and the first stack of a new fiber there. Camilo named it on 2026-11-14 (record 6) |

The tests of the switch hold naked functions too, in `src/switch_test.zig`,
`src/switch_test_start.zig`, `src/switch_test_registers.zig` and `src/switch_test_entry.zig`. Only a
test calls them, and no file of the library imports them. So they have no row.

`bench/switch_probe_forms.zig` holds three blocks of assembly and forced inlines, which keep the
form of a shape of the probe. `bench/switch_probe_ways.zig` reads the address to resume at of the
jump through a raw pointer, and the tests of the probe read a frame through one. Only the probe and
its tests run that code, and no file of the library imports it. So it has no row.

`bench/std_switch_x86_64.zig` holds std's switch for x86-64 with the list of the package: inline
assembly, a forced inline and a naked entry. Its test file holds naked functions too. Only the
probe and the tests run that code, and no file of the library imports it. So it has no row. Until
record 6 that switch was the switch of the package on x86-64, under rows L1 and L2.

Until 2026-11-14 `bench/jump_switch.zig` held the jump, as the candidate of record 5, with no row.
Record 6 moved it to `src/switch_jump.zig`, with rows L4 to L6, and the file went.

## The rows

| id | file and function | technique | why plain Zig cannot do it | what checks it | date |
|---|---|---|---|---|---|
| L1 | `src/switch.zig`, the assembly of `switch_copied`, which is private | inline assembly, with a clobber list of each register that it does not save | no statement of Zig changes the stack pointer and jumps to code on another stack | the tests of `src/switch_test.zig`, `src/switch_test_registers.zig` and `src/switch_test_floats.zig`, in Debug and in ReleaseSafe. The Linux gate runs them for aarch64. Since record 6 this row is for aarch64 alone | 2026-11-12 |
| L3 | `src/switch.zig`, `switch_copied`, which is `switch_context` on aarch64 | a forced inline: an `inline fn`, so each caller holds a copy of the switch | plain Zig leaves the choice to the compiler. A call takes the proof from the aarch64 list (records 3 and 5) | the test of `src/switch_test_form.zig`, `tools/compile_fail/switch_call_on_aarch64.zig`, and the mutations of the aarch64 list, CAUGHT in ReleaseSafe | 2026-11-13 |
| L2 | `src/switch.zig`, `Entry(main).entry` | a naked function in assembly | a new fiber has no caller, so its first instructions load the argument from the stack and jump to `main` | the tests of `src/switch_test_start.zig`. On Linux, the test of `src/switch_test_entry.zig` (record 4). Since record 6 this row is for aarch64 alone | 2026-11-12 |
| L4 | `src/switch_jump.zig`, `jump_switch`, which is private | a naked function in assembly that a caller calls as a C function. It pushes the six callee-saved registers, swaps the stack pointer, pops the six registers of the other context, and resumes with an indirect jump | no statement of Zig changes the stack pointer and jumps to code on another stack. A function of Zig saves only the registers that it changes, so it cannot save each callee-saved register for the other context | the tests of `src/switch_test.zig`, `src/switch_test_start.zig`, `src/switch_test_registers.zig` and `src/switch_test_floats.zig` on x86-64, in Debug and in ReleaseSafe, and the mutations of record 6. The Linux gate runs them under an emulator, and CI on x86-64 | 2026-11-14 |
| L5 | `src/switch_jump.zig`, `jump_entry` | a naked function in assembly | a new fiber has no caller, so its first instructions move the argument to its register, push a return address of zero and jump to `main` | the tests of `src/switch_test_start.zig`. On Linux, the test of `src/switch_test_entry.zig` (record 6) | 2026-11-14 |
| L6 | `src/switch_jump.zig`, `switch_context` and `initial_context` | raw pointers: the address of `jump_switch` as a function of the C calling convention, and a pointer to the seven words of a first stack | Zig refuses a call of a naked function, so a caller calls it through a pointer of another type. The first stack is memory of the caller with no type | the test of `src/switch_test_form.zig`, `tools/compile_fail/switch_copy_on_x86_64.zig`, and the tests of `src/switch_test_start.zig` | 2026-11-14 |

A row of rotor's ledger holds a count before the technique and a count after it. These rows hold
none, because no plain version exists to compare with. The probe of `bench/switch_probe.zig`
measures L1 and L3 on aarch64, beside a call that is never inlined. It measures L4 on x86-64,
beside std's call and std's copy. No quiet machine has run it. Three CI runs measured L4 as the
candidate of record 5, and record 6 gives their numbers.

The assembly of L1 is std 0.16.0's `fiber.contextSwitch` for aarch64, with changes to its clobber
list. The header of `src/switch.zig` gives each change and its reason. rotor's decision 22 found
the first three. Record 3 holds the one that names `nzcv`. Record 5 holds the removal of `ffr`,
which LLVM reserves. The list also names `x18` only where LLVM does not reserve it, a choice of the
session that Camilo accepted on 2026-11-14 (record 5). A Zig upgrade compares std's file with that
copy (rotor's decision 34, "Upkeep").

The assembly of L4 and L5 holds no code of std. It follows the design of Boost.Context for x86-64
System V, and holds no code of Boost (record 6). Each caller calls `jump_switch`, so the calling
convention covers each caller-saved register, such as the x87 registers. The jump does not save the
control bits of MXCSR or the x87 control word, which System V makes callee-saved. They belong to
the thread (record 3).
