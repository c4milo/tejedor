# Hot-path ledger

rotor's decision 34 keeps one rule of rotor's decision 7 for this package ("What it keeps"). Ugly
code lives only in a named file, and each use has a row in a ledger. This file is that ledger.

Ugly code is code that plain Zig does not need: assembly, a naked function, a raw pointer, a
forced inline, or a safety check that is off. A use with no row here does not land.

## The named files

| file | what it holds |
|---|---|
| `src/switch.zig` | the context switch of a fiber, and the entry of a new fiber |

The tests of the switch hold naked functions too, in `src/switch_test.zig`,
`src/switch_test_registers.zig` and `src/switch_test_entry.zig`. Only a test calls them, and no
file of the library imports them.
So they have no row.

`bench/switch_probe_forms.zig` holds three blocks of assembly and forced inlines, which keep the
form of a shape of the probe. Its tests read a frame through a raw pointer. Only the probe and its
tests run that code, and no file of the library imports it. So it has no row.

`bench/jump_switch.zig` holds the jump candidate of record 5: a naked function in assembly for
x86-64. Only the probe and its tests call it, and no file of the library imports it. So it has no
row either. If Camilo rules that it replaces the call, it moves to `src/` with a row.

## The rows

| id | file and function | technique | why plain Zig cannot do it | what checks it | date |
|---|---|---|---|---|---|
| L1 | `src/switch.zig`, the assembly of `switch_copied`, which is private | inline assembly, with a clobber list of each register that it does not save | no statement of Zig changes the stack pointer and jumps to code on another stack | the tests of `src/switch_test.zig`, `src/switch_test_registers.zig` and `src/switch_test_floats.zig`, in Debug and in ReleaseSafe. The Linux gate runs them for aarch64 and for x86-64 | 2026-11-12 |
| L3 | `src/switch.zig`, `switch_copied`, which is `switch_context` on aarch64 | a forced inline: an `inline fn`, so each caller holds a copy of the switch | plain Zig leaves the choice to the compiler. A call takes the proof from the aarch64 list (records 3 and 5) | the test of `src/switch_test_form.zig`, `tools/compile_fail/switch_call_on_aarch64.zig`, and the mutations of the aarch64 list, CAUGHT in ReleaseSafe | 2026-11-13 |
| L2 | `src/switch.zig`, `Entry(main).entry` | a naked function in assembly | a new fiber has no caller, so its first instructions load the argument from the stack and jump to `main` | the test "a new fiber starts with its argument, on an aligned stack that ends at the stack's end". On Linux, the test of `src/switch_test_entry.zig` (record 4) | 2026-11-12 |

A row of rotor's ledger holds a count before the technique and a count after it. Rows L1 and L2
hold none, because no plain version exists to compare with. The probe of `bench/switch_probe.zig`
measures L1, and `bench/results/` holds its runs. For L3 the probe gives both forms: the copy, and
a call that is never inlined. No quiet machine has run it.

The assembly of L1 is std 0.16.0's `fiber.contextSwitch`, with six changes to its clobber lists.
The header of `src/switch.zig` gives each change and its reason. rotor's decision 22 found the
first three. Record 2 of `docs/decisions/` holds the fourth, which names the `xmm` registers of
x86-64. Record 3 holds the fifth, which names `nzcv` on aarch64. Record 5 holds the sixth: the
aarch64 list does not name `ffr`, which LLVM reserves. The list also names `x18` only where LLVM
does not reserve it, a choice of the session that Camilo has not ruled. A Zig upgrade compares
std's file with that copy (rotor's decision 34, "Upkeep").

On x86-64 `switch_context` is `switch_called`, a function that holds a copy of L1 and is never
inlined (records 3 and 5). So each caller calls it. The calling convention then covers the
registers that the clobber type of Zig 0.16.0 cannot name, such as the x87 registers.
