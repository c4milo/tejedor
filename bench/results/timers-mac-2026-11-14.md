**A busy run, and no final number.** `mac` ran other work at the time, at a load average of 36 to
44. A number is taken on an idle machine, so a run on a quiet `mac` must replace this file.

# The timer program, the first numbers of step 1

These are the first numbers of step 1 of rotor's decision 34 ("The timer program"). Three
candidates kept `N` timers armed for a period of 1,000 µs each, and armed each one again as it
fired, for 3 s. Each run printed one line of rotor's harness. The percentiles are lateness, the time
from the deadline of a fire to the wake, and not latency.

| | |
|---|---|
| machine | mac |
| processor | Apple M1 Pro, 10 cores |
| system | macOS 26.6.2, aarch64 |
| Zig | 0.16.0 |
| build mode | ReleaseSafe, for each candidate |
| date | 2026-11-14 |
| load average | 41.01 at the start, 36.09 at the last round |

The candidates:

| candidate | program | what runs each timer |
|---|---|---|
| rotor | `rotor_timers --mode oneshot`, rotor's own program, built with `zig build bench-echo -Drelease` from rotor v0.11.0 | one `timer` operation of a plain loop, armed again by the program at each fire |
| std.Io.Threaded | `std_io_timers --backend threaded`, `bench/std_io_timers.zig` | one thread for each timer, with `clock_nanosleep` |
| tejedor | `std_io_timers --backend tejedor`, `bench/std_io_timers.zig` | one fiber of 256 KiB for each timer, with `io.sleep`, over `rotor.Reactor(rotor.Loop)` on kqueue |

The commands, three rounds, with each candidate in turn at each count:

```sh
rotor_timers --timers N --period-us 1000 --seconds 3 --mode oneshot
std_io_timers --timers N --period-us 1000 --seconds 3 --backend threaded
std_io_timers --timers N --period-us 1000 --seconds 3 --backend tejedor
```

At a period of 1,000 µs, a candidate that keeps up fires 256,000 times a second at 256 timers, and
4,096,000 times at 4,096 timers. No candidate kept up on this machine.

## Each run

| timers | round | candidate | fires a second | p50, ns | p99, ns | p999, ns |
|---:|---:|---|---:|---:|---:|---:|
| 256 | 1 | rotor | 166,640 | 75,667 | 1,182,084 | 10,282,500 |
| 256 | 1 | std.Io.Threaded | 106,037 | 800,459 | 4,742,500 | 9,102,625 |
| 256 | 1 | tejedor | 109,210 | 395,417 | 21,003,750 | 64,699,209 |
| 4,096 | 1 | rotor | 1,785,639 | 149,209 | 2,980,208 | 2,980,792 |
| 4,096 | 1 | std.Io.Threaded | 274,676 | 440,875 | 2,798,750 | 5,111,833 |
| 4,096 | 1 | tejedor | 1,234,395 | 2,751,209 | 22,950,208 | 26,593,708 |
| 256 | 2 | rotor | 153,759 | 293,542 | 5,188,167 | 7,436,250 |
| 256 | 2 | std.Io.Threaded | 173,693 | 412,625 | 3,042,833 | 7,683,458 |
| 256 | 2 | tejedor | 178,334 | 206,833 | 3,730,875 | 7,525,083 |
| 4,096 | 2 | rotor | 3,637,113 | 72,292 | 534,084 | 554,459 |
| 4,096 | 2 | std.Io.Threaded | 379,668 | 285,209 | 1,493,542 | 2,320,333 |
| 4,096 | 2 | tejedor | 1,280,740 | 1,616,083 | 41,393,833 | 41,461,333 |
| 256 | 3 | rotor | 220,668 | 40,167 | 2,758,666 | 3,913,333 |
| 256 | 3 | std.Io.Threaded | 182,165 | 301,000 | 1,930,416 | 2,894,250 |
| 256 | 3 | tejedor | 229,728 | 24,583 | 849,417 | 1,525,958 |
| 4,096 | 3 | rotor | 3,057,116 | 41,625 | 599,375 | 620,791 |
| 4,096 | 3 | std.Io.Threaded | 350,246 | 315,208 | 1,730,334 | 3,136,250 |
| 4,096 | 3 | tejedor | 2,137,080 | 1,565,667 | 4,314,542 | 4,525,375 |

## The median of the three rounds

Each cell is the median of the three runs of its column, each one taken alone.

| timers | candidate | fires a second | p50, ns | p99, ns |
|---:|---|---:|---:|---:|
| 256 | rotor | 166,640 | 75,667 | 2,758,666 |
| 256 | std.Io.Threaded | 173,693 | 412,625 | 3,042,833 |
| 256 | tejedor | 178,334 | 206,833 | 3,730,875 |
| 4,096 | rotor | 3,057,116 | 72,292 | 599,375 |
| 4,096 | std.Io.Threaded | 350,246 | 315,208 | 1,730,334 |
| 4,096 | tejedor | 1,280,740 | 1,616,083 | 22,950,208 |

## What the runs show, and what they do not

- The runs of one candidate at one count differ by up to a factor of 25 in p99. The machine was
  busy, so these numbers rank nothing.
- At 4,096 timers the package lost to rotor's own program in each round: it fired 0.35 to 0.70 times
  as often, and its p50 lateness was 18 to 38 times larger. It fired 3.4 to 6.1 times as often as
  `std.Io.Threaded`, whose p50 lateness was smaller in each round.
- At 256 timers no candidate led in each round.
- A timer of the package runs from the stamp of the last tick, so a sleep can end early, and the
  program reads such a wake as a lateness of 0. So the rows of the package can favour it against
  `std.Io.Threaded` (decision 34, "The timer program").
- The package ran with its default stack of 256 KiB. At 4,096 fibers the stacks take 1 GiB of
  address space, of which a run touches a few pages of each stack.
