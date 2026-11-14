# 6. The jump is the switch of x86-64

Status: **accepted**. Camilo ruled on 2026-11-14, in a third round of rulings on step 0, after three
CI runs of the probe. The session wrote this record the same day, with the change. The rulings are
Camilo's. The reasons against each alternative below are the session's, and Camilo has not read
them. He reads such a reason only where a ruling quotes it.

## The question

Record 5 made the jump a candidate of the probe, under `bench/` alone. It said that the jump
replaces the call of x86-64 only if it measures faster, and Camilo rules it. The jump is a switch
in assembly in the style of Boost.Context. A caller calls it as a C function. It pushes the six
callee-saved registers of System V, and saves the stack pointer. Then it loads the stack pointer of
the other context, pops that context's six registers, and resumes with an indirect `jmp`.

The CI ran the probe three times on 2026-11-14 at `ba1daf0`, with
`zig build bench-switch -- --machine github` in ReleaseSafe.
`bench/results/switch-github-2026-11-14.md` holds the three reports. These are CI numbers: three
GitHub runners that are no named machine, one run on each, with three x86-64 processors. One run is
no evidence of a spread. Each cell is the median of the time of one switch to a fiber and one switch
back, in ns:

| form | shape | Intel Xeon Platinum 8573C, run 43605307180 | AMD EPYC 9V45, run 43605798617 | Intel Xeon 6973P-C, run 43605822985 |
|---|---|---:|---:|---:|
| a call of std's switch, the form of the package at `ba1daf0` | in the loop | 28.4 | 17.1 | 23.2 |
| a call of std's switch | in one function that both sides call | 29.7 | 18.5 | 23.8 |
| a call of std's switch | in a function of each side | 46.3 | 29.1 | 39.2 |
| a copy of std's switch | in the loop | 2.48 | 1.67 | 2.06 |
| a copy of std's switch | in one function that both sides call | 27.7 | 18.4 | 23.6 |
| a copy of std's switch | in a function of each side | 28.3 | 18.7 | 22.4 |
| the jump, the candidate at `ba1daf0` | in the loop | 8.26 | 6.01 | 6.54 |
| the jump | in one function that both sides call | 28.3 | 19.1 | 23.1 |
| the jump | in a function of each side | 28.2 | 19.1 | 23.0 |
| one call of an empty function, beside each row | | 1.00 to 1.66 | 0.89 to 0.90 | 0.53 to 0.56 |

The load average over one minute was 1.11, 0.66 and 0.86 before the three runs. The p99 and the
least sample of each row are in the results file. The shape of a function of each side is the
closest to step 1. In step 1 a fiber blocks in a function, and the main context resumes it from a
function of its own.

## The return model of record 5, and the numbers

Record 5 gave a prior of the session. It counts the returns that a processor predicts wrong in one
pair, for each form and shape. A processor predicts a return from a stack of the return addresses
of the calls that it saw. After a switch, a return can go to an address that the other context
pushed.

| form | in the loop | in one function that both sides call | in a function of each side |
|---|---:|---:|---:|
| a copy of std's switch | 0 | 2 | 2 |
| a call of std's switch | 2 | 2 | 4 |
| the jump | 0 | 2 | 2 |

The numbers agree with the model in each shape, on each of the three processors:

- **In a function of each side**, the call has four wrong returns, and the copy and the jump two.
  The call is the slowest on each runner, by 18.1, 10.0 and 16.2 ns against the jump. The copy and
  the jump are within 1 ns of each other.
- **In one function that both sides call**, each form has two wrong returns. The three forms are
  within 2 ns of each other on each runner.
- **In the loop**, the copy and the jump have no wrong return, and the call has two. The call is
  the slowest, by 20.1, 11.1 and 16.7 ns against the jump.

The model counts returns alone. In the loop the jump takes 4.3 to 5.8 ns more than the copy, with
the same count. The session reads that difference as the work of the jump: a call, six pushes,
seven pops and an indirect `jmp` on each side. A copy in the loop saves three words, and the
compiler saves the callee-saved registers one time, outside the loop. The probe does not measure
that work alone, so this explanation is no measurement.

## The decision

Camilo ruled on 2026-11-14. He chose this option, in its words:

> I move jump_switch to src/ as the x86-64 switch_context, with its one-word Context and its own first stack, a ledger row and a record 6. Its tests and mutations move with it. Done in step 0, before step 1.

1. **On x86-64 `switch_context` is the jump.** It is the address of `jump_switch`, a naked
   function in assembly, with the C calling convention. Each caller calls it with a plain call. It
   saves `rbp`, `rbx` and `r12` to `r15` itself. It resumes with a `pop` and a `jmp`. `Context` on
   x86-64 is one word, the stack pointer. aarch64 does not change: its form stays the copy, and its
   other form the call.
2. **`initial_context` on x86-64 builds the first stack of the jump.** It holds seven words:
   - the argument, in the word of `r12`;
   - the address of `main`, in the word of `rbx`;
   - the entry, as the address to resume at;
   - zero, in each other word.

   The entry moves the argument to `rdi`, pushes a return address of zero, and jumps to `main`. So
   the rules of record 4 hold:
   - Each word that the fiber needs is at or above the first stack pointer.
   - `main` starts with a return address of zero and a frame pointer of zero.
   - The stack pointer of `main` is 8 bytes past a multiple of 16.
3. **The jump has rows L4 to L6 of `docs/hot-path-ledger.md`**, and `src/switch_jump.zig`, the
   file that holds it, is a named file of the ledger. `bench/jump_switch.zig` and its exemption
   go.

The same round holds three more rulings. `supported` is false on Fuchsia, on both architectures:
record 5 holds that ruling in a note. The choices of the session that record 5 lists stay as built,
and record 5 marks each one. The three CI reports go in the tree, in
`bench/results/switch-github-2026-11-14.md`.

## What changes

- `src/switch_jump.zig` is new. It holds `jump_switch` and `jump_entry`, which are private, and
  `Context`, `Switch`, `switch_context` and `initial_context` for x86-64. `src/switch.zig` imports
  it, and the module `tejedor` exports no name of either file.
- In `src/switch.zig`, `Context` and `Switch` are std's on aarch64 and the jump's on x86-64.
  `switch_context` is `switch_copied` on aarch64 and the jump on x86-64. `switch_other_form` is the
  call of aarch64, and a reference to it does not compile on x86-64. The x86-64 list, the x86-64
  part of `switch_copied`, and the first context and the entry of record 4 for x86-64 left the
  file.
- std's switch of x86-64 left `src/` for `bench/std_switch_x86_64.zig`, as a copy and as a call,
  with the first context of record 4 for x86-64. The commit before this change copied it to
  `bench/`, with its tests in `bench/std_switch_x86_64_test.zig`. This change removed it from
  `src/`. The probe compares the jump with that call and that copy, in the three shapes.
  `bench/switch_probe_ways.zig` says where the probe gets each form.
- `bench/jump_switch.zig` went. Its tests are the tests of `src/` on x86-64 now.

### The design, and the names

The session took the design that it recommended to Camilo beside the question. std's call and copy
of x86-64 need a context of three words and the first stack of record 4. The jump needs a context
of one word and its own first stack. With both in `src/`, x86-64 needs two types of context, and a
name for each. In `bench/`, the comparison forms add no name to `src/`. The new file of `src/`
names four things that only `src/switch.zig` reads. `src/switch.zig` gives them the names that it
had: `Context`, `Switch`, `switch_context` and `initial_context`.

## The checks

Each test of the switch in `src/` runs on x86-64 against the jump, in Debug and in ReleaseSafe:

| rule | the test |
|---|---|
| a plain call of `switch_context` is a direct call of the jump, and no copy | "a plain call of the switch is a copy on aarch64 and a call of the jump on x86_64", in `src/switch_test_form.zig`. The address to resume at must be in the caller, between two calls, and the 5 bytes before it must be a direct call of `switch_context`. The first bytes at the target must be the six pushes of the jump. `tools/compile_fail/switch_copy_on_x86_64.zig` asks for an inline call of `switch_context`, and Zig must refuse it |
| each callee-saved register survives | "a switch out and back keeps each callee-saved register and the stack pointer", in `src/switch_test_registers.zig` |
| an `f80` value survives, in the x87 registers | "the main context and a fiber each keep an f80 value across a switch", in `src/switch_test.zig` |
| a mask and a vector of AVX-512 survive | "the main context and a fiber each keep masks and vectors of AVX-512 across a switch", in `src/switch_test_floats.zig`. The mask of the fiber is the inverse of the mask of the main context in each lane, and "the two sides of the test of AVX-512 differ in each lane of each mask and each sum" checks that on each target. The test of AVX-512 runs only on a processor with AVX-512: not on `mac`, and in CI only on a runner whose processor has it. A plain `zig build test` does not show whether it ran |
| a fiber runs one time for each switch | "a fiber runs one time for each of many switches in a row", in `src/switch_test.zig` |
| the first stack holds a return address of zero and gives an aligned frame, and `initial_context` writes no word below the first stack pointer | "a new fiber starts with its argument, on an aligned stack that ends at the stack's end", in `src/switch_test_start.zig`. A canary fills the stack before `initial_context`. Before the first switch, each byte below the first stack pointer must still hold it |
| a signal on Linux before a new fiber runs does not break its start | "a new fiber gets its argument when a signal arrives at its first stack pointer", in `src/switch_test_entry.zig`. On x86-64 a step runs with the stack pointer at the first word of the fiber's first stack, and sends SIGUSR1 to its own thread. Then it makes the pops and the `jmp` of the switch |
| a stack trace from a fiber ends at `main` | "a walk of the frame pointers from a fiber ends at the frame of its main", in `src/switch_test_start.zig`. A walk from a function that `main` calls reads two frames, and then a frame pointer of zero |

The tests of the x86-64 list moved with that list to `bench/std_switch_x86_64_test.zig`:

| rule | the test |
|---|---|
| std's switch loads its message from its argument (rotor's decision 22) | "std's call on x86_64 loads its message from its argument, whatever rsi holds" |
| the list names each callee-saved register | "a switch of std's call on x86_64 out and back keeps each callee-saved register" |
| the list names `xmm0` to `xmm15` (record 2) | "the main context and a fiber of std's copy on x86_64 each keep 32 floating-point values". It runs the copy. There a name out of the list shows in ReleaseSafe |
| the call keeps an `f80` value, and the copy does not (record 3) | "the main context and a fiber of std's call on x86_64 each keep an f80 value". It runs the call. Its header says how to run it on the copy, and the mutation below does that |
| the first context of record 4 for x86-64 | "a new fiber of std's switch on x86_64 starts with its argument, with no caller, aligned" |

The test of the form of the probe checks that each row runs its form, in its functions. For the
jump, the fiber reads the address to resume at of the main context while the main context waits.
After the run, later calls write over that word on the stack of the main context.

## What the compiler builds

On 2026-11-14 the session built the tests of the package for x86-64 Linux with
`zig build test-linux`, in Debug and in ReleaseSafe. It read the disassembly of `objdump -d`. Debug
on x86-64 is the backend of Zig itself, and ReleaseSafe is LLVM.

| mode | functions that call the jump | how they call it | functions that hold the pops and the `jmp` of the switch | lines that name std's switch |
|---|---|---|---|---|
| Debug | 22 functions of the tests | `callq switch_jump.jump_switch`, a direct call | `jump_switch`, and the step of the test of the signal | 0 |
| ReleaseSafe | the same 22, and `set_switch_and_read` | `callq switch_jump.jump_switch`, a direct call | the same two | 0 |

The 22 functions are each fiber and each test of `src/switch_test*.zig` that switches with a plain
call of `switch_context`. In Debug, `set_switch_and_read`, the assembly of the test of the
registers, calls the jump through a register, `callq *%rax`. That is the test's own assembly, which
takes the address of `switch_context`. The jump is a naked function, so no caller holds a copy of
its body.

In the ReleaseSafe probe for x86-64 Linux, the fiber and the functions of the rows of the jump call
`switch_jump.jump_switch`. In the rows of std's call, they call `std_switch_x86_64.switch_called`.
The rows of the copy call no switch.

## The mutations

The session ran each mutation on 2026-11-14 on `mac`. Each cell gives Debug, then ReleaseSafe. C is
CAUGHT, n is NOT CAUGHT, and a dash is a build that did not run. The x86-64 Linux runs were in
Docker under Rosetta, an emulator. The aarch64 Linux runs were in Docker with no emulator.

The jump, against the tests of the package:

| mutation | x86-64 Linux, under Rosetta |
|---|---|
| none | pass, pass |
| `rbx` not restored: its word is popped into no register | C, C |
| `rbp` not restored | C, C |
| `r13` not restored | C, C |
| `r15` not restored | C, C |
| the pops of `r12` and `r13` swapped | C, C |
| the old context and the new one swapped | C, C |
| the stack pointer saved one word high | C, C |
| `ret` in place of the `pop` and the `jmp` | n, n |
| the entry hands `main` the value of `r13` | C, C |
| the entry pushes no return address of zero | C, C |
| the entry pushes the address of `main` as the return address | C, C |
| the first frame pointer is not zero | C, C |
| the first stack is not cleared | C, C |
| `switch_context` names a function that calls the jump | C, C |
| `switch_context` is an inline function that calls the jump | n, n |
| a caller calls the jump from assembly whose list names no x87, `xmm` or `k` register | C, C |
| the argument 8 bytes below the first stack pointer, where the entry reads it | C, C |
| the argument 1,024 bytes below the first stack pointer | C, C |
| the argument 5,600 bytes below the first stack pointer | C, C |

The form of each architecture, and the start of a fiber on aarch64:

| mutation | aarch64 macOS, `test-debug` | aarch64 macOS, `test-release` | `test-compile-fail` on `mac` | aarch64 Linux |
|---|---|---|---|---|
| none | pass | pass | pass | pass, pass |
| `switch_context` is `switch_called` on aarch64 | C | C | C | - |
| `switch_copied` is not `inline` | C | n | C | - |
| `switch_context` of x86-64 is an inline function that calls the jump | - | - | C | - |
| `switch_context` of x86-64 names a function that calls the jump | - | - | C | - |
| the entry of aarch64 does not clear the link register | C | C | - | C, C |
| the first frame pointer of aarch64 is not zero | C | C | - | - |
| the argument below the stack pointer on aarch64, as in record 4 | C | C | - | C, C |

The masks of the test of AVX-512, on `mac`:

| mutation | `test-debug` | `test-release` |
|---|---|---|
| the masks of the fiber are not the inverse | C | C |
| the pairs of the first version: each mask of each side is `0x0F0F` | C | C |

The probe, against its tests, built for x86-64 Linux as the Linux gate builds its executables
`bench-x86_64-debug` and `bench-x86_64-release`:

| mutation | x86-64 Linux, under Rosetta |
|---|---|
| the row of the jump runs a function that calls the jump | C, C |
| the row of the call runs std's copy | C, C |
| the row of the copy runs std's call | C, C |
| in a function of each side, the fiber of the jump runs the function of the main context | C, C |
| in a function of each side, the main context of the jump calls the function of the fiber | C, C |
| in a function of each side, the main context of the jump switches in its loop | C, C |
| in the loop, the main context of the jump switches through a function of its own | n, n |
| in the loop, the main context of the copy switches through a function of its own | n, n |

std's switch of x86-64 in `bench/std_switch_x86_64.zig`, against the tests of the bench programs,
built for x86-64 Linux in the same way. The session ran these in the commit that copied it to
`bench/`, before the jump came to `src/`:

| mutation | x86-64 Linux, under Rosetta |
|---|---|
| none | pass, pass |
| `rsi` back in the list | n, C |
| `rbx` out of the list; `r12` out; `r15` out | C, C |
| `xmm0` to `xmm15` out of the list | n, C |
| `xmm7` out of the list | n, C |
| the test of an `f80` value runs the copy | n, C |
| `switch_called` is not `noinline` | n, C |
| no zero word at the first stack pointer | C, C |
| the old x86-64 entry of record 4, whole | C, C |

How to read the tables:

- `ret` pops the address to resume at and jumps to it, as the `pop` and the `jmp` do. So the jump
  stays correct, and no test can see the change. That NOT CAUGHT is expected. The difference is in
  the prediction of the return, which only the probe can show.
- An inline function that calls the jump compiles to the same call in each caller, so the tests
  pass. That NOT CAUGHT is expected. `test-compile-fail` catches it: Zig then compiles the program
  that asks for an inline call.
- A function that calls the jump as its last statement becomes a `jmp` to the jump in ReleaseSafe.
  The first test of the form passed with it in ReleaseSafe, because the address to resume at was
  in the caller. So the test now also reads the first bytes of the function that the caller calls.
  They must be the six pushes of the jump. The row of the probe gave the same result, and its
  mutant now calls the jump with no tail call.
- With a call from assembly, a Debug build keeps the `f80` sum in memory. But its call of the jump
  goes through a register, and the test of the form catches it. In ReleaseSafe the tests of the
  `f80` value and of 32 values catch it.
- The test of the first stack reads the canary before the first switch. So it catches a word below
  the first stack pointer at each offset, on each kernel. The session ran the three rows of
  the argument again after it added that check. Before it, the rows of 8 and 1,024 bytes were NOT
  CAUGHT. The test of the signal sees such a word only where the signal frame writes it.
- On x86-64 the kernel leaves 128 bytes below the stack pointer to the code that runs, which the
  session recalled and did not read. A trial of the session counted the bytes that the signal and
  the fiber changed below the first stack pointer under Rosetta. They were 1,274 to 1,383 bytes,
  with gaps, and the lowest was about 5,700 bytes below it. The signal did not write the words 8
  and 1,024 bytes below, so the test of the signal passed with the argument there. A real x86-64
  kernel can write another layout.
- The first version of the step of the test of the signal on x86-64 put its own words right below
  the first stack pointer. It then caught the mutation of 8 bytes by its own write, and not by the
  signal. The step now keeps its words in a static of the test.
- In the loop, the main context switches in the code of `measure.zig`, which has no address in the
  test of the probe. There the test checks the form alone, for each form (record 5). So a function
  of its own between the loop and the switch is NOT CAUGHT, for the jump and for the copy. That is
  the limit of the shape, and it is expected.
- A NOT CAUGHT of std's list in Debug is the expected result of records 2 and 3: a Debug build
  keeps few values in registers. The same holds for `switch_called` that is not `noinline`. A Debug
  build still calls it. A ReleaseSafe build copies it, and loses the `f80` value.

No processor here has AVX-512, so no mutation ran against the test of AVX-512. The session built
that test for the CPU model `x86_64_v4` in ReleaseSafe, and read the disassembly of
`switch_with_masks`. With the jump, the compiler saves each of the four masks with `kmovw` to the
stack before the call, and loads it after the call. Take a mutant that calls the jump from assembly
whose list names no `k` register. There the compiler keeps the masks in `k1` to `k4` across the
call. The other side runs the same function, and its compares write its own masks to `k1` to `k4`
before it switches back. Its masks are the inverse of the masks of the first side in each lane. So
the lanes that the first side chooses after the switch fail. Until a review of 2026-11-14 the two
sides had equal masks, and the test could not see that fault.

A runner of Linux on x86-64 whose processor has AVX-512 runs that test. A runner whose processor has
no AVX-512 skips it, and the log of a plain `zig build test` does not show whether the test ran. No
log has shown a run yet. Until one does, the disassembly above is the evidence for the masks of
AVX-512. The test of an `f80` value covers the x87 registers on each x86-64 processor.

## Alternatives that lost

These are the alternatives of the question that Camilo answered. The session wrote the reasons
against them, and Camilo has not read them.

1. **Keep the call of std's switch on x86-64.** It is the slowest form in each shape on each of the
   three runners. In a function of each side it takes 10.0 to 18.1 ns more than the jump in each
   pair. A step 1 that blocks a fiber pays that at each call that blocks.
2. **Decide at step 1.** The numbers of step 1 would then come from a switch that the package may
   replace. The tests and mutations of step 1 would also cover a form that goes. The move also
   changes the type of `Context` on x86-64, which step 1 stores in each fiber.

The session also weighed these designs for the move, and Camilo has not read them:

1. **Keep std's call and copy of x86-64 in `src/`, beside the jump.** That needs a second type of
   context and a second first stack in `src/`, each with a name. The package does not use that
   code.
2. **Make the entry a function of `main`, as on aarch64, and jump to `main` directly.** That is not
   the candidate that CI measured. The ruling moves that candidate.

## What departs from std and from rotor's decision 34

- **std.** On x86-64 the package no longer uses std's `fiber.contextSwitch`, or the first context
  and the entry of std's fibers. Its x86-64 switch holds no code of std. On aarch64 it still uses
  std's switch, with the changes of records 3 and 5.
- **rotor's decision 34, "Upkeep".** At a Zig upgrade, the read of std's switch against the copy of
  the package covers aarch64 alone. For x86-64 that upgrade reads these things:
  - that Zig still compiles a call through `switch_context` as a direct call of the jump. The test
    of the form and the disassembly above show it. Zig 0.16.0 also refuses a direct call of a
    naked function: "unable to call function with calling convention 'naked'". The session
    compiled such a call on 2026-11-14. No check of the package holds that fact, and the package
    does not depend on it;
  - that an inline call of `switch_context` still fails, with the note that
    `tools/compile_fail/switch_copy_on_x86_64.zig` requires. `switch_context` is a `@ptrCast` of
    the naked `jump_switch` to a function type of the C calling convention. Zig 0.16.0 cannot
    resolve the function behind a cast to another function type at compile time, so it refuses
    the inline call. It does inline a call through a pointer to a plain function with no cast;
  - the C calling convention of x86-64 in Zig. The jump saves the six callee-saved registers of
    System V, and the convention must cover each caller-saved register. The jump does not save the
    control bits of MXCSR or the x87 control word, which System V makes callee-saved. They belong
    to the thread (record 3);
  - std's switch of x86-64, against `bench/std_switch_x86_64.zig`, which the probe still measures.
    A later clobber type can name the x87 registers, `k0` to `k7` and `r16` to `r31`. Record 3
    says that a copy on x86-64 can then come back. Camilo rules on that change.
- **rotor's decision 34, "Where the code starts".** It takes the switch with "nothing but the
  names" changed. Records 2 to 5 departed from that sentence. On x86-64 this record replaces the
  switch and the entry.
- **rotor's decision 34, "What it keeps".** It puts the context switch in assembly in one file. By
  the ruling of 2026-11-14 the switch is assembly in two named files: `src/switch.zig` for aarch64
  and `src/switch_jump.zig` for x86-64. Each has rows in `docs/hot-path-ledger.md`.
- **rotor's decision 34, "The fiber switch has no measured cell".** rotor's probe measured an
  `inline` copy of std's switch. On x86-64 the package now measures the jump, beside std's call
  and copy.

The package changes no file of rotor. A note in rotor's decision 34 that points at this record is
rotor's to add.

## The shadow stack of CET

The jump needs a process with no shadow stack and no indirect branch tracking of the processor.
These are the two parts of CET on x86-64. std's switch needs the same.

- A shadow stack keeps a second copy of each return address, and checks it at each return. The
  call of `jump_switch` pushes a return address. The jump resumes the other context with `jmp`, so
  no return takes that address off the shadow stack. A later return of the other context then goes
  to an address that its own call pushed, and the shadow stack holds another one there. So the
  processor refuses that return.
- Branch tracking refuses an indirect jump to an address that does not start with `endbr64`. The
  jump resumes at a return address, and its entry jumps to `main` through `rbx`.

The build writes no GNU property note that asks Linux for either. The ReleaseSafe probe for x86-64
Linux holds no such note (`llvm-readelf -n`, 2026-11-14). Boost's design has a path for shadow
stacks, which the jump leaves out. The session recalled that path, and did not read it.

## Choices of the session that Camilo has not ruled

- **The names of `src/switch_jump.zig`**: `Context`, `Switch`, `switch_context` and
  `initial_context`, as `src/switch.zig` names them. `jump_switch` and `jump_entry` stay private.
- **`JumpWords` and `jump_words`**, which are public in `src/switch_test.zig`. The other test files
  read the words of the jump through them, as they read `switch_out_of_line` (record 5). The module
  `tejedor` exports neither.
- **`switch_other_form` does not compile on x86-64.** A reference to it there stops the compile
  with a message.
- **`bench/std_switch_x86_64.zig` and its test file are not named files of the ledger.** No file of
  the library imports them. The ledger exempts them, as it exempted `bench/jump_switch.zig`.
- **`bench/switch_probe_ways.zig`**, a new piece of the probe. It reads the address to resume at of
  the jump through a raw pointer. The ledger exempts it, as it exempts the other files of the
  probe.
- **The words of the report for the forms.** These changed after `ba1daf0`:
  - "the other form" is now "a form to compare with", and the role "a candidate" went;
  - "with a call of the switch" is now "with a call of std's switch";
  - "with a copy of the switch in the caller" is now "with a copy of std's switch in the caller";
  - "with a call of the jump candidate" is now "with a call of the jump".
- **The test of AVX-512**, which runs only for a target with AVX-512, and the test that checks its
  masks on each target.
- **The test of the frame walk**, the check of the canary below the first stack pointer, and the
  check of the first bytes of the jump in the test of the form.
- **The read of the address to resume at of the main context of the jump in the test of the probe.**
  The fiber makes it in a test build alone, through `read_resumed` and the field `main_resumed`,
  both private.
- **The step of the test of the signal on x86-64.** It moves the stack pointer to the first word of
  the first stack of the jump, and not past its pops. It keeps its own words in a static.
- **The check of Fuchsia of ruling 2**: a comptime assert outside the tests of `src/switch.zig`,
  and the step `zig build test-fuchsia`. That step compiles the file as an object for Fuchsia on
  both architectures, because the test runner of std 0.16.0 does not compile for Fuchsia.
- **The note that `test-compile-fail` requires on x86-64**: "function being called inline must be
  comptime-known". The error that Zig prints with it, "unable to resolve comptime value", names no
  inline call.

## Sources

- `bench/results/switch-github-2026-11-14.md`: the CI runs 43605307180, 43605798617 and
  43605822985, jobs "Linux x86-64, the probe of the switch", at `ba1daf0`.
- Records 3, 4 and 5, and the probe part of record 5 for the return model.
- Boost.Context, `jump_x86_64_sysv_elf_gas.S`, for the design of the jump. The session recalled the
  design, and did not read the file.
- `std/Io/fiber.zig` and `std/Build/Step/Compile.zig` of Zig 0.16.0.
