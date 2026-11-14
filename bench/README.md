# The programs that measure tejedor

This directory holds each program that measures the package, and the results of their runs. The
results stay in the package (rotor's decision 34, "The measurement plan").

## The probe of the context switch

`switch_probe.zig` measures one switch from the main context to a fiber, and one switch back. It
calls `switch_context` of `src/switch.zig`, as the package calls it. A call that blocks costs one
such pair beside the operation that it waits for: a switch away from the fiber, and a switch back
to it. Camilo reads the numbers of this probe before step 1 of the build order.

The probe is rotor's row C26, which went with rotor's decision 22
(`bench/costs/probes/probes_fiber.zig` at rotor's `b2bcf60`). rotor never filled that row from a
quiet machine.

### What a number holds

- Each sample times two loops back to back. The first loop calls an empty function that is never
  inlined. The second loop switches to the fiber, and the fiber switches back.
- A sample is the time of a batch of 16,384 operations, divided by 16,384. The clock cannot time
  one switch alone: on `mac` it steps in units of 41 ns, which each report prints.
- A row is the median of 2,000 samples, with the p99 and the least sample beside it. The p99 is the
  p99 of batch means, and not of single switches.
- The fiber runs one function. Nothing else runs between two switches: no ready list, no tick and
  no operation. The package adds those.
- Each form of the switch runs in three shapes, and each one is a row. The report has three lines
  for each row: the switches, the empty function, and the first less the second.

### The forms

The probe measures two forms of the switch (record 3), and on x86-64 a candidate (record 5):

| form | what a caller holds | the form of the package on |
|---|---|---|
| a copy | a copy of the switch | aarch64 |
| a call | a call of a function that holds the switch, and that saves and restores the callee-saved registers | x86-64 |
| the jump candidate | a call of `jump_switch` of `jump_switch.zig`, which pushes the callee-saved registers and resumes with a jump | no platform: a candidate of x86-64 |

The probe gets the form of the package with a plain call of `switch_context`, as the package does.
It gets the other form with a plain call of `switch_other_form`: a call on aarch64, and a copy on
x86-64 (record 5).

### The three shapes

Each form runs in three shapes (record 5):

| shape | where the switch is |
|---|---|
| in the loop | in the loop that the probe times, and in the loop of the fiber |
| in one function that both sides call | in one function that is never inlined, and that returns after the switch |
| in a function of each side | in a function of the main context and another of the fiber. Each is never inlined, and returns after the switch |

A caller of step 1 switches in a function, and then returns. A processor predicts a return from a
stack of the return addresses of the calls that it saw. After a switch, a return can go to an
address that the other side pushed, and the processor then predicts it wrong. Record 5 gives the
count of such returns for each form and shape. After the switch, an empty block of assembly keeps a
call of the switch a call. The function of the fiber holds one `nop` more than the function of the
main context, so an optimized build cannot merge the two.

A report gives the form of the package first, and says so in its row. The other form follows it,
to compare with, and then the candidate, on x86-64.

The candidate is a switch in the style of Boost.Context for x86-64 System V. It is under `bench/`
alone, and the package does not use it. It replaces the call only if it measures faster, and
Camilo rules it. `zig build test-bench` runs its four tests on x86-64, and the Linux gate runs
them on x86-64 Linux. On a Mac the x86-64 build runs under an emulator, so no number of a call on
x86-64 is in a result. The CI ran the probe one time on a real x86-64 processor, and record 5 gives
those numbers.

The first two files of `results/`, `switch-mac-2026-11-13.md` and
`switch-orbstack-2026-11-13.md`, came before record 3, and their rows name the forms in other
words.
"As the compiler builds the call" was a copy: the disassembly of that build showed the body of
the switch in both loops. "With `switch_context` never inlined" was a call.

### What a number cannot show

- The cost of a switch to a cold fiber. The probe switches between the same two stacks, so both
  are in the cache.
- The cost of a switch in a caller of step 1. The shapes with functions come closer to it than the
  loop, and they still keep few registers across the switch.
- A slow single switch. A batch mean hides it.
- A drift of the machine during a run. The probe runs each row one time, in a fixed order.
  First come the three shapes of the form of the package, then the three of the other form. On
  x86-64 the three of the candidate come last. So a row of the candidate runs six rows after the
  row of the call in the same shape. A drift can fall on one row more than on another, so compare
  the forms of one run with care.

### How the probe knows that it measured the switch

- The fiber counts each time that it runs. The probe fails when that count differs from the count
  of the switches to the fiber.
- A test reads the address that each side saved at its last switch. For a call, it also reads
  the return address of that call. These show the form and the function of each row. So a row
  that runs another form or another function than its label fails the test. Record 5 says what
  the test does not read.
- The empty function reads a volatile value, and it is `noinline`. So its call stays in the loop.
- A median under 0.15 ns is less than one cycle of a 6 GHz core. The probe then prints `FAILED`
  and exits with status 1.

### Commands

```bash
zig build bench-switch -- --machine mac      # build in ReleaseSafe, and run on this host
zig build test-bench                         # the unit tests of the bench programs
zig build bench-linux                        # build the probe for Linux, and run nothing
bash tools/linux_bench.sh --machine orbstack # run that build in Docker
```

The probe always builds in ReleaseSafe. `--machine` gives the name that the report prints, and the
probe refuses each other argument. Exit status: 0 with numbers, 1 when the probe measured nothing,
and 2 for a wrong argument.

`tools/linux_bench.sh` runs the probe on the platform of Docker's host. `BENCH_PLATFORM=linux/amd64`
runs the x86-64 build. On a Mac that run is under an emulator: it shows that the probe runs, and
its numbers go in no result.

### The machines

| name | what it is |
|---|---|
| `mac` | the development machine: an Apple M1 Pro, with macOS |
| `orbstack` | the Linux virtual machine of OrbStack on `mac`, which runs Docker's containers |
| `github` | a GitHub-hosted runner. The job `probe` of the CI prints what its runner is |

A number is taken on an idle machine. `orbstack` runs on the cores of `mac`, so it is only as quiet
as `mac` is. A container does not see the load of its host, so `tools/linux_bench.sh` prints the
load of the host too.

### How to record a result

1. Run the probe, and send its report to a new file: `bench/results/switch-<machine>-<date>.md`.
   The date is the date that the report prints, which is in UTC.
2. Add the command to the file.
3. If the machine was busy, say so in the first lines of the file, with the load average.
4. Read the disassembly of the probe, and say in the file if the first form holds the body of
   `switch_context` or a call.

A run on a busy machine is no final number. Each file of `bench/results/` says which kind it is.

### The results

| file | machine | what it is |
|---|---|---|
| `results/switch-mac-2026-11-13.md` | `mac` | four busy runs, at load averages of 17 to 34, and no final number |
| `results/switch-orbstack-2026-11-13.md` | `orbstack` | four busy runs, at load averages of 28 to 42 on the host, and no final number |
| `results/switch-mac-2026-11-13-shapes.md` | `mac` | three busy runs of the three shapes, and no final number |
| `results/switch-github-2026-11-14.md` | `github` | three CI runs at `ba1daf0`, each on another runner and another x86-64 processor, and no number of a quiet machine |

No run on a quiet `mac` exists yet. The first CI run, on 2026-11-13, is in record 5 and in no file
of `results/`.

## Files

| file | what it holds |
|---|---|
| `switch_probe.zig` | the entry of the probe of the context switch, and the table of the machine |
| `switch_probe_forms.zig` | the forms and the shapes that the probe measures, and the run of each row |
| `switch_probe_report.zig` | the table of the numbers in the report |
| `jump_switch.zig` | the jump candidate of record 5 for x86-64, and its tests |
| `measure.zig` | the method that times a probe: batches, the median, the p99, and two loops back to back |
| `machine.zig` | the machine and the load average, for the report |
| `results/` | the reports of the runs that the steps above recorded, and of the CI runs of 2026-11-14. A file can hold several runs. Record 5 holds the first CI run |
