**A busy run, and no final number.** `mac` ran other work at the time, and the first table gives
its load average. A number is taken on an idle machine, so a run on a quiet `mac` must replace
this file.

# The probe of the context switch

| | |
|---|---|
| machine | mac |
| processor | Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory |
| system | macOS 26.6.2, Darwin 25.6.0, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-13 (UTC) |
| clock | clock_gettime(CLOCK_UPTIME_RAW), with a least step of 41 ns |
| thread | not pinned (macOS on Apple silicon has no hard affinity); QoS class user-interactive requested |
| load average before the run | 31.05, 30.64 and 32.60, over 1, 5 and 15 minutes |
| load average after the run | 30.48, 30.53 and 32.55, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, as the compiler builds the call | 5.02 | 161 | 4.71 |
| one call of an empty function, beside those switches | 1.53 | 39.3 | 1.43 |
| those switches less that call, for each sample | 3.45 | 160 | -204 |
| one switch to a fiber and one switch back, with `switch_context` never inlined | 54.4 | 1023 | 27.0 |
| one call of an empty function, beside those switches | 1.54 | 119 | 1.43 |
| those switches less that call, for each sample | 49.3 | 1017 | -1490 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each form, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

## The command

```bash
zig build bench-switch -- --machine mac
```

The tree was at the commit that added this file. The run was at 20:05 on 2026-11-12, Eastern
time, which is 2026-11-13 in UTC.

## Three more runs

The same command ran two more times in the two minutes after the run above. It ran a fourth time
16 minutes after the first, when the load average was about half. Each row is one run. A load
average has no unit, and each other number is in nanoseconds. The four columns of the two forms
are for one switch to a fiber and one switch back.

| run | load average over 1 minute, before the run | as the compiler builds the call: median | as the compiler builds the call: least | never inlined: median | never inlined: least | one call of an empty function: median |
|---|---:|---:|---:|---:|---:|---:|
| 1, the report above | 31.05 | 5.02 | 4.71 | 54.4 | 27.0 | 1.53 |
| 2 | 34.34 | 4.95 | 4.69 | 30.5 | 26.9 | 1.52 |
| 3 | 34.39 | 4.97 | 4.81 | 45.7 | 27.6 | 1.52 |
| 4, at 20:21 | 16.65 | 4.85 | 4.77 | 27.6 | 27.5 | 1.49 |

## How to read this run

- **The first form is the switch with its body in the caller.** In this build the compiler copied
  the body of `switch_context` into the loop of the main context and into the fiber. The
  disassembly of the probe shows it: each of the two holds the instructions of the switch, and
  no call.
- **The second form calls the function.** `switch_context` then saves 20 registers on the stack
  before the switch, and restores them after it. The first form saves them one time, when the
  caller starts.
- **The median of the second form is not stable here, and the reason is not known.** The table
  of "Three more runs" shows it: the median differs much between runs 1, 2 and 3, and the least
  sample does not. The load average does not explain it. Run 2 has the least median of the
  three, at the load of run 3. Later runs on a `mac` that was as busy, or more, read a median
  near that of run 4. Those runs are in no result. A run on a quiet `mac` decides.
- **A negative least value** is in a row "those switches less that call". In such a sample,
  other work stopped the thread inside the loop of the empty function.
- rotor made one run of the old probe, on a busy `mac` too, with the switch as an `inline`
  function. Decision 34 of rotor gives its two numbers ("The fiber switch has no measured cell"):

  | what rotor's run timed | ns |
  |---|---:|
  | one switch out and back | 4.96 |
  | one call of an empty function | 1.52 |
