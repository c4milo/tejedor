# The probe of the context switch on `orbstack`, three runs at a host load average of about 3.5, 2026-11-15

These are the first runs of the probe on `orbstack` at a low load of `mac`. They replace the
busy runs of `switch-orbstack-2026-11-13.md` as the numbers to read. The session ran the probe
three times, one after the other, at `4f5f215`, right after the three runs of
`switch-mac-2026-11-15.md`. The tree of step 1, `a043623`, changes no file of the probe or of
the switch, so the runs hold for that tree too.

Each run is one run of the second command, after the first:

```bash
zig build bench-linux && bash tools/linux_bench.sh --machine orbstack
```

| run | load average of the virtual machine before the run | load average of the host before | load average of the host after |
|---|---|---|---|
| 1 | 0.46, 0.41 and 0.46 | 3.05, 3.17 and 3.52 | 3.29, 3.22 and 3.54 |
| 2 | 0.51, 0.42 and 0.46 | 3.29, 3.22 and 3.54 | 3.76, 3.33 and 3.57 |
| 3 | 0.63, 0.45 and 0.47 | 3.76, 3.33 and 3.57 | 3.78, 3.34 and 3.57 |

`orbstack` runs on the cores of `mac`, so it is only as quiet as `mac` is. Each run started at
a 1-minute load average of the host of 3.05 to 3.76, over the bound of 3.0 that the session used
for `mac`. The 5-minute load average of the host stayed under 3.4. The medians of a row differ
by at most 0.60 ns from run to run. The host was over the bound by at most 0.76, so the session
takes these runs as the final numbers of `orbstack` at this tree. Camilo may rule that they are
busy runs.

The session read the disassembly of the ReleaseSafe binary that the runs used
(`llvm-objdump -d`, `zig-out/linux-bench/switch_probe-aarch64`). It shows these functions:

| function | what it holds |
|---|---|
| `Run(.copy, .loop).fiber_main` | the switch, with `br x3` |
| `Functions(.copy, .one_function).switch_and_return` | the switch, with `br x3`, then `ret` |
| `Functions(.copy, .two_functions).switch_on_fiber` | the switch, with `br x3`, then `ret` |
| `Run(.call, .loop).fiber_main` | `bl switch.switch_called`, and no copy |
| `Functions(.call, .one_function).switch_and_return` | `bl switch.switch_called`, then `ret` |
| `Functions(.call, .two_functions).switch_on_fiber` | `bl switch.switch_called`, then `ret` |

As on 2026-11-13, the build has no function `switch_on_main` of its own. Its code is the same as
the code of `switch_and_return` of the same form, and the build keeps one copy of that code.

## Run 1

| | |
|---|---|
| machine | orbstack |
| processor | CPU implementer 0x61, 10 processors, 16424796 KiB memory |
| system | Linux 7.2.12-orbstack-00394-gbecdd6130068, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-15 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 41 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 0.46, 0.41 and 0.46, over 1, 5 and 15 minutes |
| load average after the run | 0.51, 0.42 and 0.46, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in the loop (the form of the package) | 4.91 | 5.51 | 4.62 |
| one call of an empty function, beside those switches | 1.48 | 1.76 | 1.39 |
| those switches less that call, for each sample | 3.43 | 4.01 | 2.09 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in one function that both sides call (the form of the package) | 29.0 | 35.8 | 27.2 |
| one call of an empty function, beside those switches | 1.48 | 2.17 | 1.38 |
| those switches less that call, for each sample | 27.5 | 33.4 | 25.0 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in a function of each side (the form of the package) | 29.2 | 33.1 | 27.2 |
| one call of an empty function, beside those switches | 1.49 | 1.82 | 1.39 |
| those switches less that call, for each sample | 27.7 | 31.6 | 24.8 |
| one switch to a fiber and one switch back, with a call of std's switch, in the loop (a form to compare with) | 28.6 | 30.3 | 26.8 |
| one call of an empty function, beside those switches | 1.48 | 1.72 | 1.38 |
| those switches less that call, for each sample | 27.1 | 28.8 | 24.9 |
| one switch to a fiber and one switch back, with a call of std's switch, in one function that both sides call (a form to compare with) | 32.8 | 37.1 | 30.6 |
| one call of an empty function, beside those switches | 1.49 | 1.90 | 1.38 |
| those switches less that call, for each sample | 31.3 | 35.6 | 29.1 |
| one switch to a fiber and one switch back, with a call of std's switch, in a function of each side (a form to compare with) | 42.4 | 47.6 | 39.6 |
| one call of an empty function, beside those switches | 1.49 | 1.91 | 1.39 |
| those switches less that call, for each sample | 40.9 | 46.1 | 38.2 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

The probe ran in a container on linux/arm64. A container does not see the load of its host. On
the host, `uptime` gave:

| when | `uptime` on the host |
|---|---|
| before the run | 6:30  up 48 days,  8:55, 3 users, load averages: 3.05 3.17 3.52 |
| after the run | 6:30  up 48 days,  8:55, 3 users, load averages: 3.29 3.22 3.54 |

## Run 2

| | |
|---|---|
| machine | orbstack |
| processor | CPU implementer 0x61, 10 processors, 16424796 KiB memory |
| system | Linux 7.2.12-orbstack-00394-gbecdd6130068, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-15 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 41 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 0.51, 0.42 and 0.46, over 1, 5 and 15 minutes |
| load average after the run | 0.63, 0.45 and 0.47, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in the loop (the form of the package) | 4.82 | 5.34 | 4.80 |
| one call of an empty function, beside those switches | 1.48 | 1.68 | 1.47 |
| those switches less that call, for each sample | 3.34 | 3.85 | 2.63 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in one function that both sides call (the form of the package) | 29.1 | 29.8 | 27.2 |
| one call of an empty function, beside those switches | 1.48 | 1.81 | 1.38 |
| those switches less that call, for each sample | 27.6 | 28.3 | 25.8 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in a function of each side (the form of the package) | 29.1 | 30.4 | 27.2 |
| one call of an empty function, beside those switches | 1.48 | 1.69 | 1.38 |
| those switches less that call, for each sample | 27.6 | 28.9 | 24.4 |
| one switch to a fiber and one switch back, with a call of std's switch, in the loop (a form to compare with) | 28.7 | 29.7 | 26.8 |
| one call of an empty function, beside those switches | 1.48 | 1.96 | 1.38 |
| those switches less that call, for each sample | 27.2 | 28.2 | 25.4 |
| one switch to a fiber and one switch back, with a call of std's switch, in one function that both sides call (a form to compare with) | 32.8 | 33.9 | 30.6 |
| one call of an empty function, beside those switches | 1.48 | 1.83 | 1.38 |
| those switches less that call, for each sample | 31.3 | 32.4 | 29.0 |
| one switch to a fiber and one switch back, with a call of std's switch, in a function of each side (a form to compare with) | 42.6 | 45.5 | 40.3 |
| one call of an empty function, beside those switches | 1.48 | 1.67 | 1.38 |
| those switches less that call, for each sample | 41.2 | 44.1 | 38.9 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

The probe ran in a container on linux/arm64. A container does not see the load of its host. On
the host, `uptime` gave:

| when | `uptime` on the host |
|---|---|
| before the run | 6:30  up 48 days,  8:55, 3 users, load averages: 3.29 3.22 3.54 |
| after the run | 6:30  up 48 days,  8:55, 3 users, load averages: 3.76 3.33 3.57 |

## Run 3

| | |
|---|---|
| machine | orbstack |
| processor | CPU implementer 0x61, 10 processors, 16424796 KiB memory |
| system | Linux 7.2.12-orbstack-00394-gbecdd6130068, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-15 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 41 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 0.63, 0.45 and 0.47, over 1, 5 and 15 minutes |
| load average after the run | 0.76, 0.48 and 0.48, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in the loop (the form of the package) | 4.91 | 5.33 | 4.79 |
| one call of an empty function, beside those switches | 1.48 | 1.68 | 1.47 |
| those switches less that call, for each sample | 3.43 | 3.85 | 2.69 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in one function that both sides call (the form of the package) | 29.1 | 30.0 | 27.2 |
| one call of an empty function, beside those switches | 1.48 | 1.67 | 1.38 |
| those switches less that call, for each sample | 27.6 | 28.5 | 25.8 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in a function of each side (the form of the package) | 29.1 | 30.4 | 27.3 |
| one call of an empty function, beside those switches | 1.48 | 1.73 | 1.38 |
| those switches less that call, for each sample | 27.7 | 28.9 | 16.7 |
| one switch to a fiber and one switch back, with a call of std's switch, in the loop (a form to compare with) | 28.7 | 31.2 | 26.8 |
| one call of an empty function, beside those switches | 1.48 | 1.81 | 1.38 |
| those switches less that call, for each sample | 27.2 | 29.7 | 25.2 |
| one switch to a fiber and one switch back, with a call of std's switch, in one function that both sides call (a form to compare with) | 32.8 | 34.3 | 30.6 |
| one call of an empty function, beside those switches | 1.48 | 1.82 | 1.39 |
| those switches less that call, for each sample | 31.3 | 32.8 | 28.8 |
| one switch to a fiber and one switch back, with a call of std's switch, in a function of each side (a form to compare with) | 43.0 | 44.6 | 40.3 |
| one call of an empty function, beside those switches | 1.48 | 1.80 | 1.39 |
| those switches less that call, for each sample | 41.5 | 43.1 | 38.6 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

The probe ran in a container on linux/arm64. A container does not see the load of its host. On
the host, `uptime` gave:

| when | `uptime` on the host |
|---|---|
| before the run | 6:30  up 48 days,  8:55, 3 users, load averages: 3.76 3.33 3.57 |
| after the run | 6:30  up 48 days,  8:55, 3 users, load averages: 3.78 3.34 3.57 |
