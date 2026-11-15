# The probe of the context switch on `mac`, three runs at a load average of about 3, 2026-11-15

These are the first runs of the probe on a quiet `mac`. They replace the busy runs of
`switch-mac-2026-11-13.md` and `switch-mac-2026-11-13-shapes.md` as the numbers to read. The
session ran the probe three times, one after the other, at `4f5f215`. The tree of step 1,
`a043623`, changes no file of the probe or of the switch, so the runs hold for that tree too.

Each run is one run of this command:

```bash
zig build bench-switch -- --machine mac
```

| run | load average before the run, over 1, 5 and 15 minutes | load average after the run |
|---|---|---|
| 1 | 2.79, 3.14 and 3.52 | 2.89, 3.15 and 3.52 |
| 2 | 2.89, 3.15 and 3.52 | 3.05, 3.18 and 3.52 |
| 3 | 3.05, 3.18 and 3.52 | 3.05, 3.17 and 3.52 |

The session waited for a 1-minute load average at or under 3.0 and a 5-minute one at or under
5.0, on two readings 60 s apart. A first wait of 12 hours found no such reading. Runs 1 and 2
started under that bound. Run 3 started at a 1-minute load average of 3.05, just over it. The
medians of a row differ by at most 0.10 ns from run to run. So the session takes these runs as
the final numbers of `mac` at this tree, and not as busy runs.

The session read the disassembly of the ReleaseSafe binary that the runs used
(`llvm-objdump -d`, `switch_probe` of the build cache). It shows these functions:

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
| machine | mac |
| processor | Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory |
| system | macOS 26.6.2, Darwin 25.6.0, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-15 (UTC) |
| clock | clock_gettime(CLOCK_UPTIME_RAW), with a least step of 41 ns |
| thread | not pinned (macOS on Apple silicon has no hard affinity); QoS class user-interactive requested |
| load average before the run | 2.79, 3.14 and 3.52, over 1, 5 and 15 minutes |
| load average after the run | 2.89, 3.15 and 3.52, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in the loop (the form of the package) | 4.88 | 5.08 | 4.52 |
| one call of an empty function, beside those switches | 1.47 | 1.51 | 1.38 |
| those switches less that call, for each sample | 3.40 | 3.61 | 2.91 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in one function that both sides call (the form of the package) | 28.8 | 33.0 | 27.0 |
| one call of an empty function, beside those switches | 1.50 | 1.65 | 1.38 |
| those switches less that call, for each sample | 27.3 | 31.5 | 25.3 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in a function of each side (the form of the package) | 28.5 | 29.5 | 26.7 |
| one call of an empty function, beside those switches | 1.50 | 1.53 | 1.39 |
| those switches less that call, for each sample | 27.0 | 28.0 | 25.3 |
| one switch to a fiber and one switch back, with a call of std's switch, in the loop (a form to compare with) | 27.6 | 28.2 | 26.7 |
| one call of an empty function, beside those switches | 1.50 | 1.54 | 1.41 |
| those switches less that call, for each sample | 26.1 | 26.7 | 22.9 |
| one switch to a fiber and one switch back, with a call of std's switch, in one function that both sides call (a form to compare with) | 32.3 | 33.6 | 30.2 |
| one call of an empty function, beside those switches | 1.49 | 1.52 | 1.39 |
| those switches less that call, for each sample | 30.8 | 32.2 | 28.8 |
| one switch to a fiber and one switch back, with a call of std's switch, in a function of each side (a form to compare with) | 43.4 | 45.6 | 40.5 |
| one call of an empty function, beside those switches | 1.49 | 1.57 | 1.38 |
| those switches less that call, for each sample | 41.9 | 44.2 | 38.7 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

## Run 2

| | |
|---|---|
| machine | mac |
| processor | Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory |
| system | macOS 26.6.2, Darwin 25.6.0, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-15 (UTC) |
| clock | clock_gettime(CLOCK_UPTIME_RAW), with a least step of 41 ns |
| thread | not pinned (macOS on Apple silicon has no hard affinity); QoS class user-interactive requested |
| load average before the run | 2.89, 3.15 and 3.52, over 1, 5 and 15 minutes |
| load average after the run | 3.05, 3.18 and 3.52, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in the loop (the form of the package) | 4.88 | 5.21 | 4.51 |
| one call of an empty function, beside those switches | 1.47 | 1.51 | 1.38 |
| those switches less that call, for each sample | 3.40 | 3.74 | 1.27 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in one function that both sides call (the form of the package) | 28.7 | 30.4 | 27.0 |
| one call of an empty function, beside those switches | 1.48 | 1.52 | 1.38 |
| those switches less that call, for each sample | 27.3 | 28.9 | 25.2 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in a function of each side (the form of the package) | 28.4 | 30.2 | 27.5 |
| one call of an empty function, beside those switches | 1.48 | 1.52 | 1.38 |
| those switches less that call, for each sample | 26.9 | 28.7 | 23.8 |
| one switch to a fiber and one switch back, with a call of std's switch, in the loop (a form to compare with) | 27.6 | 28.7 | 25.9 |
| one call of an empty function, beside those switches | 1.48 | 1.51 | 1.38 |
| those switches less that call, for each sample | 26.1 | 27.3 | 23.7 |
| one switch to a fiber and one switch back, with a call of std's switch, in one function that both sides call (a form to compare with) | 32.3 | 33.0 | 31.2 |
| one call of an empty function, beside those switches | 1.49 | 1.51 | 1.39 |
| those switches less that call, for each sample | 30.8 | 31.5 | 28.5 |
| one switch to a fiber and one switch back, with a call of std's switch, in a function of each side (a form to compare with) | 43.4 | 44.9 | 40.5 |
| one call of an empty function, beside those switches | 1.48 | 1.53 | 1.38 |
| those switches less that call, for each sample | 41.9 | 43.4 | 39.1 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

## Run 3

| | |
|---|---|
| machine | mac |
| processor | Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory |
| system | macOS 26.6.2, Darwin 25.6.0, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-15 (UTC) |
| clock | clock_gettime(CLOCK_UPTIME_RAW), with a least step of 41 ns |
| thread | not pinned (macOS on Apple silicon has no hard affinity); QoS class user-interactive requested |
| load average before the run | 3.05, 3.18 and 3.52, over 1, 5 and 15 minutes |
| load average after the run | 3.05, 3.17 and 3.52, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in the loop (the form of the package) | 4.88 | 5.29 | 4.51 |
| one call of an empty function, beside those switches | 1.48 | 1.55 | 1.38 |
| those switches less that call, for each sample | 3.40 | 3.81 | 0.50 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in one function that both sides call (the form of the package) | 28.7 | 29.5 | 27.0 |
| one call of an empty function, beside those switches | 1.48 | 1.52 | 1.38 |
| those switches less that call, for each sample | 27.3 | 28.0 | 25.2 |
| one switch to a fiber and one switch back, with a copy of std's switch in the caller, in a function of each side (the form of the package) | 28.4 | 29.0 | 26.7 |
| one call of an empty function, beside those switches | 1.48 | 1.53 | 1.39 |
| those switches less that call, for each sample | 26.9 | 27.5 | 25.3 |
| one switch to a fiber and one switch back, with a call of std's switch, in the loop (a form to compare with) | 27.6 | 29.9 | 25.9 |
| one call of an empty function, beside those switches | 1.48 | 1.53 | 1.38 |
| those switches less that call, for each sample | 26.1 | 28.4 | 23.6 |
| one switch to a fiber and one switch back, with a call of std's switch, in one function that both sides call (a form to compare with) | 32.3 | 33.2 | 30.2 |
| one call of an empty function, beside those switches | 1.49 | 1.51 | 1.38 |
| those switches less that call, for each sample | 30.8 | 31.7 | 28.8 |
| one switch to a fiber and one switch back, with a call of std's switch, in a function of each side (a form to compare with) | 43.4 | 45.7 | 40.5 |
| one call of an empty function, beside those switches | 1.49 | 1.53 | 1.38 |
| those switches less that call, for each sample | 41.9 | 44.1 | 38.6 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.
