# Hot-path ledger

rotor's decision 34 keeps one rule of rotor's decision 7 for this package ("What it keeps"). Ugly
code lives only in a named file, and each use has a row in a ledger. This file is that ledger.

Ugly code is code that plain Zig does not need: assembly, a naked function, a raw pointer, a
forced inline, or a safety check that is off. A use with no row here does not land.

## The named files

| file | what it holds |
|---|---|
| `src/switch.zig` | the context switch of a fiber, and the entry of a new fiber |

The tests of the switch hold naked functions too, in `src/switch_test.zig` and
`src/switch_test_registers.zig`. Only a test calls them, and no file of the library imports them.
So they have no row.

## The rows

| id | file and function | technique | why plain Zig cannot do it | what checks it | date |
|---|---|---|---|---|---|
| L1 | `src/switch.zig`, `switch_context` | inline assembly, with a clobber list of each register that it does not save | no statement of Zig changes the stack pointer and jumps to code on another stack | the tests of `src/switch_test.zig` and `src/switch_test_registers.zig`, in Debug and in ReleaseSafe. The Linux gate runs them for x86-64, where the fourth change shows | 2026-11-12 |
| L2 | `src/switch.zig`, `Entry(main).entry` | a naked function in assembly | a new fiber has no caller, so its first instructions load the argument from the stack and jump to `main` | the test "a new fiber starts with its argument, on an aligned stack that ends at the stack's end" | 2026-11-12 |

A row of rotor's ledger holds a count before the technique and a count after it. These two rows
hold none, because no plain version exists to compare with.

The assembly of L1 is std 0.16.0's `fiber.contextSwitch`, with four changes to its clobber lists.
The header of `src/switch.zig` gives each change and its reason. rotor's decision 22 found the
first three. Record 2 of `docs/decisions/` holds the fourth, which names the `xmm` registers of
x86-64. A Zig upgrade compares std's file with that copy (rotor's decision 34, "Upkeep").
