# 1. The package starts from rotor's decision 34

Status: **written by the session on 2026-11-12, and Camilo has not read it.** It adds no ruling to
rotor's decision 34, which Camilo accepted on 2026-11-11. It came with the skeleton of the package.

## The decision

tejedor is a Zig package that gives a `std.Io` on fibers over a reactor of rotor. Its design is
decision 34 of rotor, "A package of its own for `std.Io` and its Future API". This record pins that
design at one commit of rotor:

<https://github.com/c4milo/rotor/blob/128b8da/docs/decisions/0034-a-package-for-std-io-futures.md>

This record does not copy the design. It holds three things for a person who starts work on the
package:

- the rulings that bind the package;
- the build order, and what the first release holds;
- the state of each public name.

Where this record and the pinned text differ, this record has an error.

Each later record of tejedor takes the next number, from 2.

## The rulings that bind the package

Camilo ruled on the package on 2026-11-09, and then in four rounds on 2026-11-10 and 2026-11-11.
Each row gives one ruling. A number in the first column is the number of an open question of the
pinned text. That question holds the choices, and the cost of each answer.

| question | ruling | date |
|---|---|---|
| Where the Future API goes | A package of its own, outside rotor. | 2026-11-09 |
| 1. The name of the package | `tejedor`. | 2026-11-10 |
| 1, the rest. Each other name | Camilo rules each name with the code. | 2026-11-10 |
| 2. Who calls `tick` | The package. | 2026-11-10 |
| 3. The first rotor release that the package builds on | v0.11.0. | 2026-11-10 |
| 4. The default fibers, the default stack and the limit | 256 fibers of 256 KiB, with a limit of 4,096 fibers. | 2026-11-10 |
| 5. A guard page for each stack | Always. | 2026-11-10 |
| 6. What the first release holds | Through the network calls: steps 0 to 5 of the build order. | 2026-11-10 |
| 7. A default for `rest`, the `std.Io` that runs each call that the package does not run | No default. | 2026-11-10 |
| 8. The calls that another thread may make | Only `futexWake`. | 2026-11-10 |
| 9. The five halts at a limit | Camilo accepts all five. | 2026-11-10 |
| 10. The two conditions of rotor's decision 22 | Both bind. The first means that rotor's own paths do not slow down. | 2026-11-10 |
| 11. Who makes the reactor | The program. | 2026-11-10 |
| 12. A record or a tag for each operation of a fiber | A record. | 2026-11-10 |
| 13. A limit on the fibers that run between two ticks | A constant of 64. | 2026-11-10 |
| 14. Whether the package can run over a twin of the reactor | A type that is generic over the reactor's type. | 2026-11-10 |
| 15. Whether the 75 calls that go to `rest` halt from another thread | Each call checks the owner, and halts from another thread. | 2026-11-10 |
| 16. A halt when nothing can wake a fiber | No halt. | 2026-11-10 |
| 17. Where a twin's socket calls come from | An option. | 2026-11-11 |
| 18. A twin of the package's own, for its tests | Yes, a small one. | 2026-11-11 |
| 19. A deadline inside a network call | For one `net_receive`, the package maps std's `Timeout` to the `timeout_ns` of the operation. | 2026-11-11 |
| 19, after the acceptance. The release that holds that receive | The first release. | 2026-11-11 |
| Whether Camilo accepts the record | He accepts it. | 2026-11-11 |

Camilo set the two conditions of question 10 on 2026-09-27. Decision 22 of rotor states them in
these words: it keeps rotor's performance, and its API follows rotor's own primitives.

Two more parts of the accepted design bind each release:

- Each release pins one Zig version and one rotor tag. Today the package pins Zig 0.16.0, the
  version of the pinned text, and rotor v0.11.0.
- rotor does not depend on the package, and names it in no source file.

## The build order

The pinned text gives each step in full, with its checks ("Build order"). Each check is proved by
mutation.

0. The context switch of a fiber, its tests and its probe. Camilo reads the numbers of the probe
   before step 1.
1. Contexts, std tasks, `Io.Group`s, cancel, futexes, `now`, `sleep` and the `netLookup` wrapper,
   on one thread.
2. The wake from another thread.
3. The calls of the package's own: `perform` and `call`.
4. The network calls, and `fileClose`.
5. The numbers. Camilo reads the results before a release.
6. Datagrams, batches and files, when a consumer asks.

## What the first release holds

The first release holds steps 0 to 5, by the ruling on question 6.

It also holds one part of step 6, by the ruling of 2026-11-11 under question 19. That part is
`operate`, `batchAwaitConcurrent` and `batchCancel` for one `net_receive` with its deadline. It is
built with step 4. The rest of step 6 waits for a consumer.

## The names

Camilo ruled one name: `tejedor`. Each other public name of the package is a proposal until Camilo
rules it with the code. The names of the pinned text are proposals too, such as `Fibers`, `perform`
and `call`.

*Noted on 2026-11-14.* Camilo ruled the names of step 1 with its code: the names of the sketch of
the pinned text, and `supported`. Record 7 lists them. `perform`, `call`, `WakePath`,
`set_wake_path`, `Options.loop_id` and `Options.sockets` are still proposals.

## Sources

- rotor's decision 34 at `128b8da`: "Ruling, 2026-11-09", "Rulings, 2026-11-10", "The decision, as
  proposed", "Upkeep", "Build order" and "Open questions".
- rotor's decision 22, open question 1, for the two conditions.
