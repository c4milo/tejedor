# 7. Step 1: the fibers on one thread

Status: **accepted for its rulings**. Camilo closed step 0 on 2026-11-14, and asked for step 1. The
session asked him four questions that day, and he chose the first choice of each. The session
built step 1 the same day, and wrote this record with it. Each other choice of this record is the
session's, and Camilo has not read it ("Choices of the session").

## The rulings of 2026-11-14

The first choice of each question was the session's recommendation. Camilo gave no reason with a
choice.

| question | the choices | Camilo chose |
|---|---|---|
| The public names of step 1 | the sketch's names; the sketch's with `fiber_count` for `count`; the sketch's with `fibers` for `count` | **the sketch's names** |
| Does tejedor export `supported`? | export it, and `Fibers` fails to compile where it is false; no export | **export it** |
| The named limits of step 1 | add them with the values of decision 34 and decision 22; add them with no `stack_bytes_max` | **add them as listed** |
| The first numbers: the timer program | copy rotor's program and run it now; defer the numbers | **copy it and run it now** |

So these are the public names of the package. Each one is in `src/tejedor.zig`:

| name | what it is |
|---|---|
| `Fibers(Reactor)` | the `std.Io` on fibers over a reactor of type `Reactor` |
| `Fibers.Options` | `count = 256`, `stack_bytes = 256 KiB`, `event_handler = null` |
| `Fibers.InitError` | `SystemResources` and `PollersFull` |
| `Fibers.memory_bytes`, `Fibers.operations` | the memory of `init`, and the operations that the package holds in flight |
| `Fibers.init`, `Fibers.deinit`, `Fibers.io` | the start in place, the end, and the `std.Io` |
| `EventHandler` | `state` and `handle`: the taker of each event that no record of the package takes |
| `memory_alignment` | the alignment of the memory of `init`: 16 |
| `constants` | the named limits |
| `supported` | true where the context switch has a form for the target |

`Options.loop_id`, `Options.sockets`, `perform`, `call`, `WakePath` and `set_wake_path` wait for
steps 2 to 4. Each of them is still a proposal of decision 34.

The limits are in `src/constants.zig`:

| limit | value | source |
|---|---:|---|
| `fibers_max` | 4,096 | decision 34, question 4 |
| `stack_granule_bytes` | 64 KiB | decision 22 |
| `stack_bytes_min` | 128 KiB | decision 34, question 5 |
| `stack_bytes_max` | 64 MiB | decision 22 |
| `context_bytes_max` | 1,024 | decision 34, "When the reactor is full" |
| `result_bytes_max` | 512 | decision 34, "When the reactor is full" |
| `resumes_between_ticks_max` | 64 | decision 34, question 13 |
| `submit_tries_max` | 8 | decision 34, a prior with no measurement |
| `events_per_tick` | 64 | decision 34, "When the reactor is full" |
| `lookup_results_max` | 32 | decision 34, "Why `netLookup` is a wrapper" |

## What step 1 holds

Step 1 of the build order holds "contexts, std tasks, `Io.Group`s, cancel, futexes, `now`,
`sleep` and the `netLookup` wrapper, on one thread". The package runs 17 calls of the table. Each
other call goes to `rest`, and each of the 109 calls halts from another thread, `futexWake`
included. Step 2 makes `futexWake` work from another thread.

| file | what it holds |
|---|---|
| `src/fibers.zig` | `Fibers(Reactor)`: `init`, `deinit`, `io`, and the table |
| `src/reactor_check.zig` | the comptime check of the reactor's type |
| `src/fiber.zig` | `Fiber`, the record of one context |
| `src/lists.zig` | the free list, the ready list, the futex list and the slot list |
| `src/memory.zig` | the layout of the memory, and the guard page of each stack |
| `src/run.zig` | the block, the switch, the tick on the main context, the record and the poller |
| `src/tasks.zig` | the std tasks of a future, and the cancel state |
| `src/groups.zig` | the calls of an `Io.Group` |
| `src/wait.zig` | the futexes, `now` and `sleep` |
| `src/lookup.zig` | the `netLookup` wrapper |
| `src/rest.zig` | the forwarders to `rest` |

The design is decision 34's, with the four rules of "The ready list and the tick". Only the main
context ticks. A fiber that blocks switches to the first ready context. When no context is ready,
or after 64 switches to a fiber, it switches to the main context. The main context then ticks.
Each operation of a context names the record of that context, and the record puts the context at
the end of the ready list. The poller of the package answers `.now` while a context is ready. It
moves behind each other poller before each tick that can wait.

## The checks

Each check of decision 34, step 1, and where it is:

| check | where |
|---|---|
| a test of each of the 17 calls, and of a cancel of each wait | `src/fibers_test*.zig`. A test of a call that blocks runs it on the main context and on a fiber (`on_both`) |
| a cancel of a fiber in `Group.await` reaches each member, and the call returns after the last | `src/fibers_test_groups.zig` |
| a lookup through `failing`, and a `rest` that puts two addresses | `src/fibers_test_lookup.zig` |
| two fibers that wake each other, and a timer of the test's record | `src/fibers_test_reactor.zig` |
| a poller of the test that wakes a fiber, and a tick that does not wait | `src/fibers_test_reactor.zig` |
| a record of the test that starts a std task with `concurrent` | `src/fibers_test_reactor.zig` |
| an event with no record, and a sleep on a full reactor | `src/fibers_test_reactor.zig` |
| `statistics().stalls` is 0 at the end of each test | `Fixture.expect_no_stall` in `src/fibers_test.zig` |
| `Fibers` of a type that lacks `tick` and `shared` fails to compile | `tools/compile_fail/fibers_without_tick.zig` |
| the calls of std tasks over the test's twin, and two runs with one order | `src/fibers_test_twin.zig` and `src/fibers_test_replay.zig` |
| the eight halt scenarios, and a scenario for each other assertion that a caller reaches | `tools/halt/` and `zig build halt-check` |
| the mutations of decision 22's step 1 | "The mutations", below |
| the first numbers | `bench/std_io_timers.zig` and "The numbers", below |

The tests run on kqueue with `zig build test`. The Linux gate runs each test of the package twice
in Docker: with io_uring, in a container whose seccomp profile is relaxed, and with epoll, under the
default profile. The tool `tools/linux_backend.zig` proves which backend each kind of container
takes.

On the development Mac, Rosetta runs the x86-64 containers, and it lacks system calls of rotor. It
gives no io_uring ring, and the `init` of an epoll reactor returns `Unsupported`. So on that
platform each test that needs a reactor skips, and the gate says so. The new job `linux-gate` of CI
runs the gate on the runner of each Linux platform, on its own processor. So CI runs the x86-64
tests with both backends.

## The halt check

Step 1 adds the halt check of decision 34, "Upkeep". `tools/halt_check.zig` is rotor's tool, with
two changes:

- Each scenario names a text that its panic prints. The check requires that text on standard
  error. So a halt of another kind does not pass, such as an overflow after a deleted assertion.
- Each scenario runs with a watchdog of 10 s. A scenario whose check is deleted can wait with no
  end, and the watchdog then ends it with an exit, which the check reports.

The canary holds three scenarios that must not pass: one that breaks nothing, one that dies before
its marker, and one that dies with another text.

The scenarios of `Fibers` are in `tools/halt/fibers_scenarios.zig` and its piece
`fibers_scenarios_calls.zig`. The eight cases of decision 34 are there. Each other assertion that
a mistake of the caller reaches has a scenario too: the five checks of the options, `recancel`
with no cancel, an `await` of a future twice, an `await` from two contexts, a group on another
value, a `deinit` from another thread and a `deinit` in a callback. `tools/halt/switch_scenarios.zig`
holds the two scenarios of `initial_context` that CLAUDE.md names.

## The numbers

`bench/std_io_timers.zig` is rotor's timer program at v0.11.0, with one more branch: the package
makes the reactor and a `Fibers` value, and calls `churn` on the main context. Its harness is a copy
of the parts of rotor's harness that it uses, `bench/timers_harness.zig`. rotor's package holds no
`bench/`, so the package holds the copies, by Camilo's ruling of 2026-11-14.

The program ran on `mac` on 2026-11-14, at a load average of 36 to 44, beside rotor's
`rotor_timers` and `std.Io.Threaded`. `bench/results/timers-mac-2026-11-14.md` holds each run. The
machine was busy, so no number is final. The medians of three rounds, at a period of 1,000 µs:

| timers | candidate | fires a second | p50 lateness, ns | p99 lateness, ns |
|---:|---|---:|---:|---:|
| 256 | rotor | 166,640 | 75,667 | 2,758,666 |
| 256 | std.Io.Threaded | 173,693 | 412,625 | 3,042,833 |
| 256 | tejedor | 178,334 | 206,833 | 3,730,875 |
| 4,096 | rotor | 3,057,116 | 72,292 | 599,375 |
| 4,096 | std.Io.Threaded | 350,246 | 315,208 | 1,730,334 |
| 4,096 | tejedor | 1,280,740 | 1,616,083 | 22,950,208 |

At 4,096 timers the package lost to rotor's own program in each round, and fired more often than
`std.Io.Threaded` in each round. A timer of the package runs from the stamp of the last tick, so the
rows of the package can favour it against `std.Io.Threaded`. A run on a quiet `mac` replaces these
numbers.

## The mutations

Each mutation breaks one check, and each is measured against the narrowest step that can catch it
(CLAUDE.md, "Tests are proved by mutation"). The runs were on `mac`, aarch64, on a copy of the
tree. Five mutants did not compile at their first run, so each ran again in a form that compiles,
and the row says "again". A mutant that hangs a test is caught too, because a test that hangs ends
the gate at its time limit.

The first group is decision 22's list of its step 1, in the words of the package. The second holds
the checks of decision 34, step 1. The third deletes each check that a halt scenario names. The
fourth holds decision 22's two mutations of the clobber list of aarch64, which step 0 proved first.

| mutation | step | result |
|---|---|---|
| canceled wait not acknowledged | `test-debug` | CAUGHT |
| cancel point ignores the acknowledgement | `test-debug` | CAUGHT |
| cancel does not end the operation of a wait | `test-debug` | CAUGHT |
| futex wake takes one waiter too many | `test-debug` | CAUGHT |
| futex waiters woken in reverse order | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| futex wake leaves the timer of the wait running | `test-debug` | CAUGHT |
| futex wait ignores the expected value | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| uncancelable futex wait ignores the expected value (again) | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| wait ignores the protection | `test-debug` | CAUGHT |
| recancel keeps the flag | `test-debug` | CAUGHT |
| future does not wake its awaiter | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| group member does not wake its awaiter | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| group cancel cancels no member (again) | `test-debug` | CAUGHT |
| group await does not pass a cancel on | `test-debug` | CAUGHT |
| event of no record not handed to the event handler | `test-debug` | CAUGHT |
| result too large taken onto a fiber | `test-debug` | CAUGHT |
| awake clock read from rest | `test-debug` | CAUGHT |
| fiber not freed by await | `test-debug` | CAUGHT |
| forwarder drops the userdata of rest | `test-debug` | CAUGHT |
| no tick before the first operation | `test-debug` | CAUGHT |
| no limit on the switches between two ticks | `test-debug` | CAUGHT |
| poller not moved behind the other pollers | `test-debug` | CAUGHT |
| poller answers none with a context ready | `test-debug` | CAUGHT |
| slot waiters not released after a tick (again) | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| no tick between two tries on a full reactor | `test-debug` | CAUGHT |
| cancel does not end the wait for a slot | `test-debug` | CAUGHT |
| cancel does not end a futex wait | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| record leaves the context on the futex list | `test-debug` | CAUGHT |
| ready list last in, first out | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| lookup leaves the caller's queue open | `test-debug` | CAUGHT: a test hangs, and the time limit of the run ends it |
| lookup moves no result | `test-debug` | CAUGHT |
| guard pages stay protected after deinit | `test-debug` | CAUGHT |
| halt: owner check of a call | `halt-check` | CAUGHT |
| halt: owner check of deinit | `halt-check` | CAUGHT |
| halt: block in a callback | `halt-check` | CAUGHT |
| halt: sleep in a callback | `halt-check` | CAUGHT |
| halt: flag of a callback not set | `halt-check` | CAUGHT |
| halt: tick by the program | `halt-check` | CAUGHT |
| halt: event with no event handler | `halt-check` | CAUGHT |
| halt: memory short | `halt-check` | CAUGHT |
| halt: deinit with a fiber in use | `halt-check` | CAUGHT |
| halt: deinit in a callback | `halt-check` | CAUGHT |
| halt: sleep on a full reactor | `halt-check` | CAUGHT |
| halt: futex wait on a full reactor | `halt-check` | CAUGHT |
| halt: a tick that waits with a context in a slot wait | `halt-check` | CAUGHT |
| halt: no guard page | `halt-check` | CAUGHT |
| halt: options with no fiber | `halt-check` | CAUGHT |
| halt: options with too many fibers | `halt-check` | CAUGHT |
| halt: a stack below the smallest | `halt-check` | CAUGHT |
| halt: a stack above the largest | `halt-check` | CAUGHT |
| halt: a stack off the granule | `halt-check` | CAUGHT |
| halt: recancel with no cancel | `halt-check` | CAUGHT |
| halt: await a future twice | `halt-check` | CAUGHT |
| halt: await a future from two contexts | `halt-check` | CAUGHT |
| halt: await a group on another value (again) | `halt-check` | CAUGHT |
| halt: cancel a group on another value (again) | `halt-check` | CAUGHT |
| halt: a stack end not aligned | `halt-check` | CAUGHT |
| halt: a stack end of 0 | `halt-check` | CAUGHT |
| switch: x1 back in the aarch64 list | `test-release` | CAUGHT |
| switch: lr left out of the aarch64 list | `test-release` | CAUGHT |

So each of the 60 mutations is CAUGHT. Nine of them hang a test. No x86-64 mutation of the switch
ran, because step 1 changes no line of the switch.

## Choices of the session

Camilo has not read these.

1. **`init` ticks once with a wait of 0** when the reactor read no clock. Decision 34 says that the
   package ticks once "before its first operation". A fiber cannot tick, and a fiber can run
   before the first tick. So the tick is in `init`.
2. **The futex list is linked both ways.** `Fiber.previous` lets the record of a timed futex wait
   take its context off the list with no walk. So each record does a fixed amount of work
   (non-negotiable 7).
3. **`Fiber` is 88 bytes on aarch64 and 72 bytes on x86-64.** Decision 34 gave a prior of 80
   bytes. The saved context of the switch is three words on aarch64 and one on x86-64. The flags
   are one packed byte, so the back link of the futex list fits.
4. **A slot list.** A context that finds the reactor full waits on it. After each tick, each
   context of the list goes to the end of the ready list, in order. A tick has a wait of 0 while
   the list holds a context.
5. **A futex wait checks its word again after each wait for a slot.** A word that changed ends the
   wait with no wake, which std allows.
6. **A halt with a message** for each mistake of a caller that decision 34 names: a call from
   another thread, a call that blocks in a callback, a tick by the program, an event with no event
   handler, a reactor that stays full, and a `deinit` in a callback. Each other check is an
   `assert`.
7. **A `sleep` halts in a callback on each run**, also with no time, as decision 34 asks. A futex
   wait halts there only when it must block.
8. **The lint rule `heap` allows `std.heap.pageSize`.** The guard page of each stack takes one
   page of the host, and that call names no allocator.
9. **The casts of the interface of `std.Io` have no row in the ledger.** The `userdata` of the
   table, a future, `Io.Group.state`, the argument of a new fiber, and the carve of the caller's
   memory are casts that std's own `std.Io` code makes. They use no technique of rotor's decision
   7, so step 1 adds no file to the ledger.
10. **The twin of the tests** (`src/fibers_test_twin.zig`) moves its clock by at least 1 ns in each
    tick, so `now_ns` is above 0 after the first tick, as decision 34 asks of a twin. It ends the
    events that are due in the order of their submits, and keeps a trace of them.
11. **The fixture of the tests uses `std.Io.Threaded` for `rest`,** with no thread, as decision
    22's tests did.
12. **The tests skip on a reactor that the emulator refuses**, as "The checks" says. A real
    kernel never refuses it, and the gate says when a platform skips.
13. **The halt check requires the text of each scenario, and has a watchdog** ("The halt check").
14. **The job `linux-gate` of CI.** It runs the Linux gate on the runner of each Linux platform,
    so the x86-64 tests run with both backends on a real processor. Camilo ruled CI on GitHub's
    runners on 2026-11-12, and this job is one more job of that CI.
15. **The scope `fibers`** of the commit messages, for `Fibers` and its pieces.
16. **No check that another check always reaches first.** A deleted check of that kind leaves the
    other one to halt, so no mutation can prove it. So the session removed three: a check of a
    futex wait in a callback, two checks of the lists in `deinit`, and a check of the state in
    `request_cancel`.

## Sources

- rotor's decision 34 at `f8b1df4`, the main of rotor on 2026-11-14: "Build order", step 1, "The
  ready list and the tick", "Where a call comes from", "When the reactor is full", "How cancel
  works", "Why `netLookup` is a wrapper", "Over a twin" and "Upkeep".
- rotor at v0.11.0: `src/rotor/rotor.zig`, `src/reactor/reactor.zig`,
  `src/reactor/dispatch/dispatch.zig`, `src/reactor/reactor_tick.zig`, `examples/twin.zig`,
  `tools/halt_check.zig`, `tools/halt/scenario.zig` and `tools/linux_test.sh`.
- The tree of rotor before `46235cb`: decision 22's `src/rotor/adapter/` and
  `tools/halt/adapter_scenarios.zig`, and decision 22's list of the mutations of its step 1.
- `std/Io.zig` and `std/Io/net/HostName.zig` of Zig 0.16.0.
