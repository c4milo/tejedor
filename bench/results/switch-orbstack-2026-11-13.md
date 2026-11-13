**A busy run, and no final number.** `orbstack` runs on the cores of `mac`, and `mac` ran other
work at the time. The tables below give the load of the virtual machine and the load of the
host. A number is taken on an idle machine, so a run on a quiet `mac` must replace this file.

# The probe of the context switch

| | |
|---|---|
| machine | orbstack |
| processor | CPU implementer 0x61, 10 processors, 16424796 KiB memory |
| system | Linux 7.2.12-orbstack-00394-gbecdd6130068, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-13 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 41 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 27.30, 32.35 and 31.90, over 1, 5 and 15 minutes |
| load average after the run | 27.51, 32.31 and 31.89, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, as the compiler builds the call | 5.20 | 181 | 4.66 |
| one call of an empty function, beside those switches | 1.55 | 42.2 | 1.43 |
| those switches less that call, for each sample | 3.53 | 158 | -1915 |
| one switch to a fiber and one switch back, with `switch_context` never inlined | 29.6 | 708 | 28.6 |
| one call of an empty function, beside those switches | 1.53 | 23.0 | 1.48 |
| those switches less that call, for each sample | 28.0 | 706 | -696 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each form, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

The probe ran in a container on linux/arm64. A container does not see the load of its host. On
the host, `uptime` gave:

| when | `uptime` on the host |
|---|---|
| before the run | 20:09  up 45 days, 22:34, 3 users, load averages: 38.58 32.73 33.04 |
| after the run | 20:09  up 45 days, 22:34, 3 users, load averages: 40.67 33.61 33.35 |

## The command

```bash
zig build bench-linux && bash tools/linux_bench.sh --machine orbstack
```

The tree was at the commit that added this file. The run was at 20:09 on 2026-11-12, Eastern
time, which is 2026-11-13 in UTC. The script printed the report above, with the table of the
load of the host. Docker ran the probe on OrbStack's Linux virtual machine, on the processor of
`mac`, with no emulator.

## Three more runs

The same script ran two more times in the minute after the run above, and a fourth time 13
minutes after the first. Each row is one run. A load average has no unit, and each other number
is in nanoseconds. The four columns of the two forms are for one switch to a fiber and one
switch back.

| run | load average of the host over 1 minute, before the run | as the compiler builds the call: median | as the compiler builds the call: least | never inlined: median | never inlined: least | one call of an empty function: median |
|---|---:|---:|---:|---:|---:|---:|
| 1, the report above | 38.58 | 5.20 | 4.66 | 29.6 | 28.6 | 1.55 |
| 2 | 40.67 | 4.88 | 4.79 | 29.0 | 27.6 | 1.49 |
| 3 | 41.90 | 4.90 | 4.79 | 29.0 | 28.5 | 1.51 |
| 4, at 20:22 | 28.14 | 4.92 | 4.79 | 29.0 | 28.5 | 1.50 |

## How to read this run

- **The first form is the switch with its body in the caller.** In this build the compiler copied
  the body of `switch_context` into the loop of the main context and into the fiber, as in the
  build for macOS. The disassembly of the probe shows it.
- **The second form calls the function.** `switch_context` then saves 20 registers on the stack
  before the switch, and restores them after it.
- **A negative least value** is in a row "those switches less that call". In such a sample,
  other work stopped the thread inside the loop of the empty function.
- The processor row has no name, because `/proc/cpuinfo` on aarch64 gives none. The processor is
  the Apple M1 Pro of `mac`.
