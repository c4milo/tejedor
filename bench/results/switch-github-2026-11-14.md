# The probe of the context switch on `github`, three CI runs, 2026-11-14

These are CI runs on GitHub's hosted runners, and no runs of a named machine or of a quiet
machine. Each run is one run of the job `probe` of `.github/workflows/ci.yml`, at `ba1daf0`, which
a person started by hand. GitHub gives a job whichever runner it has, so each run had another
runner and another processor.

Each run is one run of this command, in the job "Linux x86-64, the probe of the switch":

```bash
zig build bench-switch -- --machine github
```

| run | CI run | processor | load average before the run | load average after the run |
|---|---|---|---|---|
| 1 | 43605307180 | Intel Xeon Platinum 8573C | 1.11, over 1 minute | 1.09, over 1 minute |
| 2 | 43605798617 | AMD EPYC 9V45 | 0.66, over 1 minute | 0.69, over 1 minute |
| 3 | 43605822985 | Intel Xeon 6973P-C | 0.86, over 1 minute | 0.88, over 1 minute |

The session copied each report from the log of its job. The log holds no empty line, so the
session put back the empty lines between the tables of a report. The heading of each part below
replaces the first line of its report, the title `# The probe of the context switch`. The session
changed no byte of the other lines.

At `ba1daf0` the form of the package on x86-64 was a call of the switch, and the jump was a
candidate of the probe (record 5). The session did not read the disassembly of these builds.
Each one was built on its runner, for the processor of that runner.

## Run 1: CI run 43605307180, Intel Xeon Platinum 8573C

| | |
|---|---|
| machine | github |
| processor | INTEL(R) XEON(R) PLATINUM 8573C, 4 processors, 16366508 KiB memory |
| system | Linux 7.0.0-1017-azure, x86_64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-14 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 20 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 1.11, 0.53 and 0.21, over 1, 5 and 15 minutes |
| load average after the run | 1.09, 0.55 and 0.22, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a call of the switch, in the loop (the form of the package) | 28.4 | 35.4 | 26.8 |
| one call of an empty function, beside those switches | 1.62 | 2.87 | 0.97 |
| those switches less that call, for each sample | 26.9 | 33.3 | 23.0 |
| one switch to a fiber and one switch back, with a call of the switch, in one function that both sides call (the form of the package) | 29.7 | 32.1 | 28.2 |
| one call of an empty function, beside those switches | 1.62 | 2.06 | 0.97 |
| those switches less that call, for each sample | 28.1 | 30.5 | 25.6 |
| one switch to a fiber and one switch back, with a call of the switch, in a function of each side (the form of the package) | 46.3 | 49.5 | 45.2 |
| one call of an empty function, beside those switches | 1.62 | 2.01 | 0.97 |
| those switches less that call, for each sample | 44.8 | 47.9 | 42.9 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in the loop (the other form) | 2.48 | 3.08 | 2.38 |
| one call of an empty function, beside those switches | 1.00 | 1.73 | 0.97 |
| those switches less that call, for each sample | 1.45 | 2.04 | -0.42 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in one function that both sides call (the other form) | 27.7 | 30.3 | 26.8 |
| one call of an empty function, beside those switches | 1.52 | 2.04 | 0.97 |
| those switches less that call, for each sample | 26.2 | 28.7 | 24.3 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in a function of each side (the other form) | 28.3 | 32.5 | 26.8 |
| one call of an empty function, beside those switches | 1.66 | 2.19 | 0.97 |
| those switches less that call, for each sample | 26.7 | 30.8 | 24.8 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in the loop (a candidate) | 8.26 | 12.1 | 7.99 |
| one call of an empty function, beside those switches | 1.00 | 2.84 | 0.97 |
| those switches less that call, for each sample | 7.07 | 10.1 | 4.67 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in one function that both sides call (a candidate) | 28.3 | 30.7 | 27.0 |
| one call of an empty function, beside those switches | 1.41 | 1.99 | 0.97 |
| those switches less that call, for each sample | 26.9 | 29.2 | 24.3 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in a function of each side (a candidate) | 28.2 | 30.5 | 27.4 |
| one call of an empty function, beside those switches | 1.62 | 2.08 | 0.97 |
| those switches less that call, for each sample | 26.6 | 28.9 | 24.3 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

## Run 2: CI run 43605798617, AMD EPYC 9V45

| | |
|---|---|
| machine | github |
| processor | AMD EPYC 9V45 96-Core Processor, 4 processors, 16367524 KiB memory |
| system | Linux 7.0.0-1017-azure, x86_64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-14 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 10 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 0.66, 0.22 and 0.08, over 1, 5 and 15 minutes |
| load average after the run | 0.69, 0.23 and 0.08, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a call of the switch, in the loop (the form of the package) | 17.1 | 17.9 | 16.8 |
| one call of an empty function, beside those switches | 0.89 | 1.20 | 0.89 |
| those switches less that call, for each sample | 16.2 | 17.0 | 15.2 |
| one switch to a fiber and one switch back, with a call of the switch, in one function that both sides call (the form of the package) | 18.5 | 19.3 | 17.7 |
| one call of an empty function, beside those switches | 0.89 | 1.20 | 0.89 |
| those switches less that call, for each sample | 17.5 | 18.4 | 16.6 |
| one switch to a fiber and one switch back, with a call of the switch, in a function of each side (the form of the package) | 29.1 | 31.2 | 28.5 |
| one call of an empty function, beside those switches | 0.89 | 1.21 | 0.89 |
| those switches less that call, for each sample | 28.2 | 30.3 | 27.0 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in the loop (the other form) | 1.67 | 7.40 | 1.66 |
| one call of an empty function, beside those switches | 0.89 | 3.13 | 0.89 |
| those switches less that call, for each sample | 0.78 | 6.02 | -6.70 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in one function that both sides call (the other form) | 18.4 | 19.2 | 18.1 |
| one call of an empty function, beside those switches | 0.89 | 1.21 | 0.89 |
| those switches less that call, for each sample | 17.5 | 18.2 | 15.8 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in a function of each side (the other form) | 18.7 | 19.8 | 18.4 |
| one call of an empty function, beside those switches | 0.89 | 1.21 | 0.89 |
| those switches less that call, for each sample | 17.8 | 18.8 | 16.7 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in the loop (a candidate) | 6.01 | 6.60 | 4.93 |
| one call of an empty function, beside those switches | 0.90 | 1.21 | 0.89 |
| those switches less that call, for each sample | 5.11 | 5.67 | 3.37 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in one function that both sides call (a candidate) | 19.1 | 19.9 | 19.0 |
| one call of an empty function, beside those switches | 0.90 | 1.24 | 0.89 |
| those switches less that call, for each sample | 18.2 | 18.9 | 17.5 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in a function of each side (a candidate) | 19.1 | 19.8 | 18.8 |
| one call of an empty function, beside those switches | 0.90 | 1.21 | 0.89 |
| those switches less that call, for each sample | 18.2 | 18.9 | 17.3 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.

## Run 3: CI run 43605822985, Intel Xeon 6973P-C

| | |
|---|---|
| machine | github |
| processor | Intel(R) Xeon(R) 6973P-C, 4 processors, 16366504 KiB memory |
| system | Linux 7.0.0-1017-azure, x86_64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe |
| date | 2026-11-14 (UTC) |
| clock | clock_gettime(CLOCK_MONOTONIC), with a least step of 17 ns |
| thread | not pinned; the probe pins no thread on this system |
| load average before the run | 0.86, 0.23 and 0.08, over 1, 5 and 15 minutes |
| load average after the run | 0.88, 0.26 and 0.09, over 1, 5 and 15 minutes |

| what one sample times | median, ns | p99, ns | least, ns |
|---|---:|---:|---:|
| one switch to a fiber and one switch back, with a call of the switch, in the loop (the form of the package) | 23.2 | 24.9 | 22.0 |
| one call of an empty function, beside those switches | 0.55 | 0.82 | 0.50 |
| those switches less that call, for each sample | 22.6 | 24.3 | 20.9 |
| one switch to a fiber and one switch back, with a call of the switch, in one function that both sides call (the form of the package) | 23.8 | 26.1 | 21.7 |
| one call of an empty function, beside those switches | 0.53 | 0.93 | 0.50 |
| those switches less that call, for each sample | 23.3 | 25.5 | 21.2 |
| one switch to a fiber and one switch back, with a call of the switch, in a function of each side (the form of the package) | 39.2 | 44.6 | 36.9 |
| one call of an empty function, beside those switches | 0.56 | 2.75 | 0.53 |
| those switches less that call, for each sample | 38.6 | 44.0 | 32.7 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in the loop (the other form) | 2.06 | 6.41 | 2.04 |
| one call of an empty function, beside those switches | 0.56 | 0.81 | 0.56 |
| those switches less that call, for each sample | 1.50 | 5.85 | 0.57 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in one function that both sides call (the other form) | 23.6 | 24.5 | 21.3 |
| one call of an empty function, beside those switches | 0.56 | 0.88 | 0.50 |
| those switches less that call, for each sample | 23.0 | 23.9 | 20.8 |
| one switch to a fiber and one switch back, with a copy of the switch in the caller, in a function of each side (the other form) | 22.4 | 23.7 | 21.0 |
| one call of an empty function, beside those switches | 0.53 | 0.78 | 0.50 |
| those switches less that call, for each sample | 21.9 | 23.1 | 20.4 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in the loop (a candidate) | 6.54 | 7.20 | 6.20 |
| one call of an empty function, beside those switches | 0.53 | 0.56 | 0.50 |
| those switches less that call, for each sample | 6.01 | 6.66 | 5.03 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in one function that both sides call (a candidate) | 23.1 | 24.6 | 21.2 |
| one call of an empty function, beside those switches | 0.54 | 0.65 | 0.50 |
| those switches less that call, for each sample | 22.6 | 24.0 | 20.7 |
| one switch to a fiber and one switch back, with a call of the jump candidate, in a function of each side (a candidate) | 23.0 | 24.1 | 21.3 |
| one call of an empty function, beside those switches | 0.53 | 0.66 | 0.50 |
| those switches less that call, for each sample | 22.5 | 23.6 | 20.6 |

Each sample is the time of a batch of 16384 operations, divided by 16384. For each row, the run kept
2000 samples, after 64 batches whose times it threw away. The p99 is the p99 of batch means, and not
of single operations.
