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

### The two forms

The probe measures two forms of the switch (record 3):

| form | what a caller holds | the form of the package on |
|---|---|---|
| a copy | a copy of `switch_body`, the assembly of the switch | aarch64 |
| a call | a call of a function that holds the switch, and that saves and restores the callee-saved registers | x86-64 |

The probe gets the form of the package with a plain call of `switch_context`, as the package does.
It gets the other form with a plain call of `switch_other_form`: a call on aarch64, and a copy on
x86-64 (record 5).

A report gives the form of the package first, and says so in its row. The other form follows it,
to compare with. On a Mac the x86-64 build runs under an emulator, so no number of a call on
x86-64 is in a result. The CI ran the probe one time on a real x86-64 processor, and record 5 gives
those numbers.

The two files of `results/` came before record 3, and their rows name the forms in other words.
"As the compiler builds the call" was a copy: the disassembly of that build showed the body of
the switch in both loops. "With `switch_context` never inlined" was a call.

### What a number cannot show

- The cost of a switch to a cold fiber. The probe switches between the same two stacks, so both
  are in the cache.
- The cost of a switch in a caller of step 1. The probe switches in a loop that does nothing else,
  so the registers that a caller keeps across the switch cost less here.
- A slow single switch. A batch mean hides it.

### How the probe knows that it measured the switch

- The fiber counts each time that it runs. The probe fails when that count differs from the count
  of the switches to the fiber.
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

No run on a quiet `mac` exists yet. The one run on a GitHub runner, on 2026-11-13, is in record 5
and in no file of `results/`.

## Files

| file | what it holds |
|---|---|
| `switch_probe.zig` | the probe of the context switch, and its report |
| `measure.zig` | the method that times a probe: batches, the median, the p99, and two loops back to back |
| `machine.zig` | the machine and the load average, for the report |
| `results/` | the reports of the runs that the steps above recorded. A file can hold several runs. Record 5 holds the one CI run |
