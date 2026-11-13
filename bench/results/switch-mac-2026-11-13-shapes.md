# The probe of the context switch on `mac`, three shapes, 2026-11-13

These are busy runs, and no final numbers. Other work ran on `mac` during each run: the load
average was 49.76 to 77.31 over one minute, and each report prints it. The medians of one row
moved by up to 2.7 times from run to run, and the least samples moved by up to 3.2 percent.

The session ran the probe three times, one after the other, at the tree of record 5 with three
shapes:

```bash
zig build bench-switch -- --machine mac
```

The disassembly of that ReleaseSafe build (`llvm-objdump -d`) shows these functions:

| function | what it holds |
|---|---|
| `Run(.copy, .loop).fiber_main` | the switch, with `br x3` |
| `Functions(.copy, .one_function).switch_and_return` | the switch, with `br x3`, then `ret` |
| `Functions(.copy, .two_functions).switch_on_fiber` | the switch, with `br x3`, a `nop`, then `ret` |
| `Run(.call, .loop).fiber_main` | `bl switch.switch_called`, and no copy |
| `Functions(.call, .one_function).switch_and_return` | `bl switch.switch_called`, then `ret` |
| `Functions(.call, .two_functions).switch_on_fiber` | `bl switch.switch_called`, a `nop`, then `ret` |

The build has no function `switch_on_main` of its own. Its code is the same as the code of
`switch_and_return` of the same form, and the build keeps one copy of that code. So in the shape
of a function of each side, the main context calls that copy, and the fiber calls
`switch_on_fiber`. The two sides still run two functions, as the test of the probe checks.

## Run 1

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
| load average before the run | 77.31, 56.57 and 52.51, over 1, 5 and 15 minutes |
| load average after the run | 68.49, 60.87 and 54.80, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in the loop (the form of the package) | 4.97 | 2093 | 4.79 |
| one call of an empty function, beside those switches | 1.52 | 610 | 1.47 |
| those switches less that call, for each sample | 3.43 | 1996 | -7726 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in one function that both sides call (the form of the package) | 30.2 | 5189 | 28.3 |
| one call of an empty function, beside those switches | 1.53 | 616 | 1.47 |
| those switches less that call, for each sample | 28.1 | 5087 | -3444 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in a function of each side (the form of the package) | 34.7 | 5114 | 28.8 |
| one call of an empty function, beside those switches | 1.52 | 656 | 1.47 |
| those switches less that call, for each sample | 30.1 | 5112 | -4672 |
| one switch to a fiber and one switch back, with a call of the switch, in the loop (the other form) | 34.3 | 5104 | 27.6 |
| one call of an empty function, beside those switches | 1.52 | 849 | 1.47 |
| those switches less that call, for each sample | 29.5 | 5100 | -8624 |
| one switch to a fiber and one switch back, with a call of the switch, in one function that both sides call (the other form) | 81.5 | 5978 | 32.2 |
| one call of an empty function, beside those switches | 1.53 | 589 | 1.47 |
| those switches less that call, for each sample | 65.2 | 5976 | -2570 |
| one switch to a fiber and one switch back, with a call of the switch, in a function of each side (the other form) | 307 | 6550 | 42.5 |
| one call of an empty function, beside those switches | 1.54 | 572 | 1.47 |
| those switches less that call, for each sample | 298 | 6549 | -1242 |

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
| date | 2026-11-13 (UTC) |
| clock | clock_gettime(CLOCK_UPTIME_RAW), with a least step of 41 ns |
| thread | not pinned (macOS on Apple silicon has no hard affinity); QoS class user-interactive requested |
| load average before the run | 66.93, 60.67 and 54.77, over 1, 5 and 15 minutes |
| load average after the run | 58.16, 60.60 and 55.52, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in the loop (the form of the package) | 5.00 | 1561 | 4.78 |
| one call of an empty function, beside those switches | 1.54 | 539 | 1.47 |
| those switches less that call, for each sample | 3.45 | 1535 | -4224 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in one function that both sides call (the form of the package) | 36.9 | 6010 | 28.7 |
| one call of an empty function, beside those switches | 1.53 | 818 | 1.48 |
| those switches less that call, for each sample | 33.6 | 5929 | -7549 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in a function of each side (the form of the package) | 73.1 | 6027 | 29.6 |
| one call of an empty function, beside those switches | 1.54 | 502 | 1.47 |
| those switches less that call, for each sample | 64.3 | 6026 | -7180 |
| one switch to a fiber and one switch back, with a call of the switch, in the loop (the other form) | 71.3 | 6161 | 27.6 |
| one call of an empty function, beside those switches | 1.53 | 1006 | 1.47 |
| those switches less that call, for each sample | 54.6 | 6143 | -4111 |
| one switch to a fiber and one switch back, with a call of the switch, in one function that both sides call (the other form) | 133 | 5437 | 31.4 |
| one call of an empty function, beside those switches | 1.55 | 621 | 1.47 |
| those switches less that call, for each sample | 120 | 5435 | -5198 |
| one switch to a fiber and one switch back, with a call of the switch, in a function of each side (the other form) | 114 | 7084 | 42.1 |
| one call of an empty function, beside those switches | 1.55 | 515 | 1.47 |
| those switches less that call, for each sample | 108 | 7033 | -5602 |

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
| date | 2026-11-13 (UTC) |
| clock | clock_gettime(CLOCK_UPTIME_RAW), with a least step of 41 ns |
| thread | not pinned (macOS on Apple silicon has no hard affinity); QoS class user-interactive requested |
| load average before the run | 58.16, 60.60 and 55.52, over 1, 5 and 15 minutes |
| load average after the run | 49.76, 57.35 and 54.89, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in the loop (the form of the package) | 5.54 | 2271 | 4.79 |
| one call of an empty function, beside those switches | 1.54 | 841 | 1.47 |
| those switches less that call, for each sample | 3.49 | 2268 | -4447 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in one function that both sides call (the form of the package) | 80.4 | 7442 | 28.3 |
| one call of an empty function, beside those switches | 1.55 | 696 | 1.47 |
| those switches less that call, for each sample | 73.0 | 7439 | -1836 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in a function of each side (the form of the package) | 52.1 | 5285 | 28.8 |
| one call of an empty function, beside those switches | 1.53 | 507 | 1.47 |
| those switches less that call, for each sample | 45.7 | 5284 | -7354 |
| one switch to a fiber and one switch back, with a call of the switch, in the loop (the other form) | 69.9 | 6256 | 27.6 |
| one call of an empty function, beside those switches | 1.54 | 622 | 1.47 |
| those switches less that call, for each sample | 61.4 | 5961 | -4297 |
| one switch to a fiber and one switch back, with a call of the switch, in one function that both sides call (the other form) | 85.3 | 7730 | 31.2 |
| one call of an empty function, beside those switches | 1.54 | 1171 | 1.47 |
| those switches less that call, for each sample | 74.4 | 7277 | -9878 |
| one switch to a fiber and one switch back, with a call of the switch, in a function of each side (the other form) | 153 | 8373 | 41.6 |
| one call of an empty function, beside those switches | 1.55 | 495 | 1.47 |
| those switches less that call, for each sample | 140 | 8293 | -3795 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.
