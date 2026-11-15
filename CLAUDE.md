# tejedor rules

tejedor is a Zig 0.16 package that gives a `std.Io` on fibers over a reactor of rotor. The reactor
is the program's `rotor.Reactor(rotor.Loop)`, or the reactor of a twin. With the package, Zig's
Future API works on the one thread that owns the reactor: `io.async`, `future.await`,
`future.cancel` and the `Io.Group` calls. Home: github.com/c4milo/tejedor.

It is a package of its own, outside rotor. rotor does not depend on it, and names it in no source
file. The design is rotor's decision 34, which Camilo accepted on 2026-11-11.

tejedor is not:

- A thread pool. It starts no thread, and no fiber moves to another thread or another reactor.
- A module of rotor. It is outside rotor's module graph and outside its releases.
- A `std.Io` for several threads. Each call but `futexWake` halts from another thread.
- A library for a program with a tick loop of its own. The package calls `tick`.
- A way to rotor's speed sources through `std.Io`. Code that wants a registered buffer or a
  multishot receive calls rotor.

## Read before you change behaviour

- `docs/decisions/0001-the-package-starts-from-rotors-decision-34.md` is the first record of
  tejedor. It holds the rulings that bind the package, the build order, and what the first release
  holds.
- rotor's decision 34 is the design. The first record links it at the commit that it pins. Cite
  its sections by name, and its open questions by number ("decision 34, question 13").
- rotor's guide, `docs/using.md`, part "A reactor", at the rotor tag that `build.zig.zon` pins:
  <https://github.com/c4milo/rotor/blob/v0.11.0/docs/using.md#a-reactor>. It says what a reactor
  gives a library. At that tag it also says that only the program calls `tick`. That text is
  older than decision 34. The guide at `128b8da` holds the note of decision 34, in the part "A
  library on a reactor". The note says that a program may hand its reactor to one package that
  ticks in its place.
  <https://github.com/c4milo/rotor/blob/128b8da/docs/using.md#a-library-on-a-reactor>
- `docs/decisions/0002-the-switch-names-the-xmm-registers.md` is the fourth correction of the
  clobber lists of the context switch. Read it before you change a list.
- `docs/decisions/0003-a-copy-on-aarch64-and-a-call-on-x86-64.md` sets how each caller calls the
  switch, and names `nzcv` in the aarch64 list. Read it before you change a call of the switch.
- `docs/decisions/0004-the-argument-of-a-new-fiber-is-above-its-stack-pointer.md` sets the first
  context and the entry of a new fiber.
- `docs/decisions/0005-a-plain-call-of-the-switch-and-a-probe-of-a-jump.md` puts the form of record
  3 in the declaration of `switch_context`. Read it before you change a call of the switch, or the
  probe.
- `docs/decisions/0006-the-jump-is-the-switch-of-x86-64.md` makes the jump, a function in assembly
  that saves the callee-saved registers itself, the switch of x86-64. Read it before you change the
  switch of x86-64, or its first stack.
- `docs/decisions/0007-step-1-the-fibers-on-one-thread.md` holds the rulings of 2026-11-14 on the
  public names and the limits, what step 1 built, its checks and mutations, and the choices of the
  session. Read it before you change a file of the fibers.
- `docs/decisions/` holds the records of tejedor. Each later record takes the next number.

If you are about to do something a record rejected, say so and stop. Do not reverse it in code.
A record whose status is "proposed" does not yet allow what it describes.

## Non-negotiables

1. **No allocator, and the caller owns the memory.** No file under `src/` names an allocator. The
   program hands the package its memory at `init`. Every loop is bounded. Every limit has a name
   and a doc comment in a `constants.zig`, and no limit is written inline. Assertions stay on in a
   release build. A function holds about two: one for what must be true, and one for what must
   not be.
2. **One thread owns a `Fibers` value.** Each fiber of a value runs on the thread that owns the
   reactor. The package starts no thread. Only `futexWake` may come from another thread, and each
   other call halts there (decision 34, questions 8 and 15). At step 1, `futexWake` from another
   thread halts too, and step 2 makes it work. Camilo ruled the name `Fibers` on 2026-11-14
   (record 7).
3. **The package calls `tick`, and the program makes the reactor** (decision 34, questions 2 and
   11). While the value lives, the package is the one caller of `tick`. The program keeps each
   other call of the reactor.
4. **The two conditions of rotor's decision 22 bind** (decision 34, question 10). That record
   states them in these words: it keeps rotor's performance, and its API follows rotor's own
   primitives. Camilo ruled that the first means that rotor's own paths do not slow down. The
   package's own speed has no fixed bar, and Camilo reads the numbers before a release.
5. **Each release pins one Zig version and one rotor tag.** `src/zig_version.zig` refuses each
   other Zig version, because the table of a `std.Io` differs between versions. `build.zig.zon`
   holds the rotor tag and its hash. A Zig upgrade is a release of the package.
6. **What the package decides is deterministic** (decision 34, "What it keeps"). The package
   reads no clock and no random source, and it orders nothing by a pointer value. A test that
   draws its inputs from a seed prints that seed when it fails. Decision 34, "What it cannot
   keep", lists what the package does not decide: `rest`, the real kernel, and a `futexWake` from
   another thread.
7. **Each operation ends with exactly one final event** (rotor's decision 5). Each record of the
   package does a small, fixed amount of work (rotor's decision 30).
8. **Invariants are code.** A broken invariant halts. Decision 34, "What it cannot keep", names
   two cases with no halt: a stack that overflows, and a context that nothing can wake.
9. **The real kernel is the test** (rotor's decision 10). The tests run through rotor on kqueue,
   on io_uring and on epoll. The replay of a whole program needs a twin under the reactor.

## Tests are proved by mutation

A test must fail when the code it covers is broken. When you add a check, break it on purpose
and confirm that a test fails. Report the result as `CAUGHT` or `NOT CAUGHT` for each mutation in
the commit body. A `NOT CAUGHT` means that no test covers the code, so write the test. Measure a
mutation against the narrowest target that can catch it: `zig build test-debug` or
`zig build test-release`. For a fault that shows only on Linux, or only on x86-64, that target is
the Linux gate.

A mutant that fails to compile for another reason proves nothing. Change it until it compiles,
and run it again.

A fault of the context switch can show in one build mode and on one platform alone. Measure a
mutation of the switch where its fault shows, and give the mode and the platform with the result.
These facts decide where a fault of a clobber list shows:

- Only a copy of the switch lets a caller keep a value in a register across the switch. On
  aarch64 each caller holds a copy, in Debug and in ReleaseSafe (records 3 and 5). A Debug build
  keeps few values in registers, so most faults of the aarch64 list show in ReleaseSafe alone.
- On x86-64 each caller calls the jump (record 6). The jump has no clobber list. It pushes and
  pops the callee-saved registers itself, and the test of `src/switch_test_registers.zig` proves
  each one. The calling convention covers each caller-saved register. The jump does not save the
  control bits of MXCSR or the x87 control word, which System V makes callee-saved. They belong to
  the thread (record 3).
- The x86-64 list is in `bench/std_switch_x86_64.zig`, std's switch that the probe compares with
  the jump. Its test of 32 values runs its copy, and proves the `xmm` names in ReleaseSafe. Its
  test of the callee-saved registers runs its call. Measure a mutation of that list against
  `zig build test-bench`, and on x86-64 against the Linux gate.
- The test of `src/switch_test_form.zig` and two programs of `tools/compile_fail/` prove the form
  of `switch_context` (records 5 and 6). Measure a mutation of the form against the step
  `zig build test-compile-fail` too.
- No test can see a name of a reserved register in a list, because the compiler keeps no value in
  such a register. `zig build test-reserved` sees the warning of LLVM for `ffr` and for `x18`
  (record 5). Measure such a mutation against it.
- On aarch64 macOS the compiler saves the callee-saved registers in pairs. So the function still
  saves a register that the list misses, when the list holds the other register of its pair.
- On x86-64 the names `zmm0` to `zmm31` kept no value out of an `xmm` register, for a target with
  no AVX-512 (record 2). That fault showed with a copy of the switch, before record 3.

The comptime check of `src/zig_version.zig` cannot fail inside a test. Its rule, `accepts`, has
tests. `zig build test-compile-fail` proves `require`, the function that stops the compile. A
program hands it another version, and that compile must fail with the message of the check. One
line has no such proof: the line that hands `require` the version of the compiler. To prove that
line, change `pinned` and confirm that the build stops with the message.

With Zig 0.17.1, a whole `zig build` does not reach the check. Zig parses each build file first,
and `build/lint.zig` holds a line that Zig 0.17.1 does not parse, in the package and in the
pinned rotor. So that build stops with a parse error and no reason. With that Zig,
`zig test src/zig_version.zig` shows the message.

An assertion is a check too. A Zig test cannot expect a panic in its own process. So an
assertion that a caller's mistake can reach gets a halt scenario. A scenario is a program that
breaks the assertion in a child process, and that process must die by a signal (decision 34,
"Upkeep"). `zig build halt-check` runs each scenario of `tools/halt/` in Debug and in
ReleaseSafe. Measure a mutation of such a check against it.

- Each scenario names a text that its panic prints, and the check requires that text. So a halt of
  another kind does not pass. An `assert` prints `reached unreachable code`, and a halt of the
  package prints its message.
- A watchdog ends a scenario after 10 s. A scenario whose check is deleted can wait with no end.
- A new check that a caller's mistake reaches gets its scenario in the same commit. A check that
  another check always reaches first cannot be proved: remove it.

## Performance discipline

These are rotor's rules (rotor's `CLAUDE.md`, "Performance discipline"). The package follows them,
with its own programs under `bench/` in the place of rotor's harness.

- **Estimate before you build.** A design argument cites rows of rotor's `docs/costs.md`, and
  shows its arithmetic. An estimate can decide what to build first. Only a measured number
  supports a claim.
- **Measure, never assume.** A change that claims a gain carries a number from a program of
  `bench/`, with the command and the machine. If no program can show the gain, the change is no
  `perf` commit.
- **No speed claim without a number that a person can get again.** Such a claim goes in no
  commit message and in no document. Report each run that the package loses, and each noisy run.
- **Statistics are sampled, and nothing logs on a hot path** (rotor's decision 9).
- **A hot structure says its size and its alignment in a comment.** A comptime assert holds
  both.
- **Ugly code needs a ledger row** (decision 34, "What it keeps"). Assembly, a naked function, a
  raw pointer, a forced inline and a safety check that is off live only in a named file.

## Conventions

- Zig 0.16.0. One module, `tejedor`. A dependent package gets no binary. `zig build` installs one
  tool for the pre-push hook, the commit linter. `bench/` holds the programs that measure the
  package.
- Names spell words out: `stack_bytes`, not `stack_sz`. The vocabulary of std stays as std spells
  it (`futexWake`, `netRead`, `VTable`), and the vocabulary of rotor stays as rotor spells it.
  One-letter names are only for loop indices. `_bytes` and `_len` count bytes, and `_max` names a
  limit.
- A public API follows TigerStyle first, then the idioms of Zig's standard library where TigerStyle
  says nothing. A Zig programmer must not find the API strange.
  - TigerStyle wins where the two differ: snake_case functions, no allocator, and storage that the
    caller owns. A large struct has an `init` in place through an out-pointer. An argument over
    16 bytes goes by `*const`.
  - A generic type takes the name of the thing, as `std.ArrayList(T)` does.
  - An options struct gives each field a default. A type copies what it keeps from the options,
    and keeps no pointer to them after `init` returns.
  - A type that `init` starts has a `deinit` that ends it.
  - The `next()` of an iterator returns `?T`.
  - No public name repeats its namespace.
  - Where the package departs from both TigerStyle and std, a numbered decision names the reason.
    The fields of `Io.VTable` are one such place: they are std's, in camelCase.
  - `docs/api.md` of pepegrillo holds the full guide, with cases.
- Functions stay at cognitive complexity 15 or less, and `test` blocks have the same limit. Split
  the function. Never raise the limit.
- A source file that a person wrote stays at or under 500 lines, with its tests. Split the file,
  and name each piece after the file it came from. Keep the first name as the entry point.
- An operational error returns an error value: a refused operation, a short buffer, a limit
  reached. Assertions are for programmer error only. Five paths of the design end in a halt at a
  limit, and Camilo accepted them (decision 34, question 9). A new halt at a limit needs his word.
  The session wrote that last sentence: question 9 rules on those five alone.
- **A container-level `var` of a struct type restates its alignment**:
  `var value: T align(@alignOf(T)) = undefined;`. Zig 0.16's own x86-64 backend builds Debug on
  x86-64. It places such a static without the alignment that its type takes from an aligned
  field, unless the variable declares it. rotor found this on 2026-09-23.
- Write all prose in **simple English**, in the active voice, with plain words. Use short
  sentences with one idea each. Define a term before you use it. Use a list for list-like content.
  Use no metaphor. Write it in ASD-STE100 Simplified Technical English too:
  - descriptive sentences of 25 words or fewer, and procedural sentences of 20 or fewer;
  - one topic in each sentence, and simple tenses;
  - one word for one meaning, and the same word for the same thing each time;
  - no -ing form used as a noun or a modifier, except in a technical name;
  - no noun cluster of more than three words.
- **No mannered prose.** Say the thing plainly and stop. Use no flourish, no sentence inversion for
  effect, no dramatic fragment and no "not X, but Y". Do not personify code. A comment explains
  what the code does and why. This rule covers source comments, doc comments, `docs/`, README
  files and commit messages alike.
- One name for one thing, and it is the name in the code. For the things of the design, use the
  words of decision 34, "Words". Examples are std task, rotor task, context, main context, callback
  and record.
- Every Markdown file is GitHub-flavored Markdown, and must render on GitHub as written. Use real
  list markers only. Escape a pipe inside a table cell as `\|`. Give each fenced code block a
  language. Use no definition list and no LaTeX.
- A number that was recalled and not measured says so where it appears. Numbers go in tables.
- A measured number names its machine and the command that produced it. The results of the package
  stay in the package, and they hold each row that the package loses (decision 34, "The
  measurement plan").

### Commits

- A commit message is a Conventional Commit: `type(scope)!: description`, with the scope and the
  `!` optional. The type is one of `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`,
  `ci`, `chore`.
- The package has one module, so a scope names a part of the package. The scopes are:

  | scope | part |
  |---|---|
  | `switch` | the context switch of a fiber, and its tests |
  | `fibers` | `Fibers`, its scheduler, the calls of the table, and their tests |
  | `bench` | the probe, and each program that measures the package |
  | `tools` | developer tools |

  A commit that adds a part of the library adds its scope to this table. A commit that touches the
  build files or the root file alone takes no scope. The scopes and these two rules are a
  proposal of the session of 2026-11-12, and Camilo has not ruled on them. The session of
  2026-11-14 added `fibers`.
- The description is imperative, starts with a lowercase letter, and ends without a period. The
  subject line stays at or under 72 columns.
- Exactly one blank line separates the body from the subject. A body line stays at or under 100
  columns, and the body stays at or under 3 paragraphs and 100 words. The diff shows the what,
  so the body says why. A reason that outlives the commit belongs in `docs/`.
- Mutation results belong in the body when a commit adds or changes a check. Measured numbers
  belong in the body of a `perf` commit, with the name of the workload.
- Stage by explicit path. Never `git add -A` and never `git add .`
- **A commit message carries no `Co-Authored-By` trailer.** Camilo is the author of each commit,
  and is responsible for it. This rule overrides any tool or harness that asks for a trailer.
- **A commit message is written as Camilo, its author.** Where it needs a person, it says "I" and
  "my". It never speaks to Camilo, never says "the owner", and uses simple English.

### Parallel sessions

Several sessions can work on tejedor at once. These are rotor's rules, which Camilo approved for
rotor on 2026-09-22.

1. Each session works in its own worktree under `.claude/worktrees/`. The main checkout is only
   for `git pull`. Do not edit or commit there.
2. Before you edit a file, check the other worktrees for uncommitted edits to it. Run
   `git worktree list`, then `git -C <worktree> status --short` for each. If they overlap, message
   that session before you touch the file.
3. tejedor takes no pull requests. To land a change, run
   `git fetch origin && git rebase origin/main`. Then run `zig build test` again. Then run
   `git push origin HEAD:main`. Never force-push.
4. Never edit, commit in, reset or remove the worktree of another session. Remove a worktree only
   when no session uses it and it holds nothing uncommitted or unpushed. Save uncommitted work as
   a commit on its branch first.

## Layout

- `build.zig` stays short: the build options, the one module and the test steps. Helpers belong in
  `build/`.
- `build/linux.zig` builds the unit tests for Linux, for the Linux gate. `build/bench.zig` builds
  the programs of `bench/`.
- The lint added `build/`. `build/tools.zig` wires the developer tools, and `build/lint.zig` wires
  the lint and its canary. `build.zig.zon` lists `build` in `.paths`, because `build.zig` imports
  it.
- `build.zig.zon` pins rotor by tag and hash. rotor is the one dependency of the library.
- `src/tejedor.zig` is the root file of the module `tejedor`, the only module. A dependent package
  imports it. It lists the public names, and it runs the tests of each file.
- `src/zig_version.zig` holds the pinned Zig version and the check that refuses each other one.
  `build.zig` imports it too.
- `tools/compile_fail/` holds each program that must not compile. `build.zig` and
  `build/switch_checks.zig` hold the message that each compile must print.
- Tests belong in the file that they test. The tests of the context switch are in files of their
  own, because they need a stack and contexts that outlive a function.
- The limits belong in `src/constants.zig`, which comes with the first limit. A comptime assert
  stays with the constant that it pins.
- `src/switch.zig` holds the context switch of a fiber, the entry of a new fiber, and the first
  context of a new fiber. It is assembly. `switch_context` is the switch that the package calls
  with a plain call. On aarch64 it is `switch_copied`, a private inline function that holds the
  assembly of std's switch (records 3 and 5). On x86-64 it is the jump of `src/switch_jump.zig`
  (record 6). `switch_other_form` is the call of aarch64, and only the tests and the probe name
  it. It does not compile on x86-64. The module `tejedor` exports no name of either file.
- `src/switch_jump.zig` is a piece of `src/switch.zig`: the jump, its one-word `Context`, and the
  first stack of a new fiber on x86-64.
- `src/switch_test.zig`, `src/switch_test_start.zig`, `src/switch_test_registers.zig`,
  `src/switch_test_floats.zig`, `src/switch_test_entry.zig` and `src/switch_test_form.zig` hold
  the tests of the switch. A file whose stem ends in `_test`, or holds `_test_`, holds tests
  alone.
- `build/switch_checks.zig` holds the checks of the switch that are compiles. One of them builds
  `tools/switch_reserved.zig`, a copy of the switch, for each target of `zig build test-reserved`.
- `src/fibers.zig` holds `Fibers(Reactor)` and its table. Its pieces are `src/reactor_check.zig`,
  the check of the reactor's type, `src/fiber.zig`, the record of a context, `src/lists.zig`, the
  lists of the contexts, `src/memory.zig`, the memory and the guard pages, `src/run.zig`, the
  scheduler and the tick, `src/tasks.zig`, `src/groups.zig`, `src/wait.zig`, `src/lookup.zig` and
  `src/rest.zig`. Each function of a piece takes the value as `fibers: anytype`, and a type
  function of a piece holds only the calls of the table, because the lint scores a type function
  as one function. The limits are in `src/constants.zig`.
- `src/fibers_test.zig` holds the fixture of the tests on the host's reactor, and its pieces hold
  the other tests of the fibers. `src/fibers_test_twin.zig` is the package's own twin, and
  `src/fibers_test_replay.zig` runs the calls of std tasks over it twice.
- `tools/halt_check.zig` and `tools/halt/` hold the halt check and its scenarios, after rotor's.
  `build/halt.zig` builds them for the host and for the Linux gate.
- `tools/linux_backend.zig` prints the backend that rotor chooses in a container, and whether a
  reactor starts there. The Linux gate runs it before the tests of a platform.
- `bench/std_io_timers.zig` is rotor's timer program with a branch for the package, and
  `bench/timers_harness.zig` holds the parts of rotor's harness that it uses.
- `docs/hot-path-ledger.md` is the ledger of the package for ugly code, such as assembly
  (decision 34, "What it keeps"). Each use has a row there. `src/switch.zig` and
  `src/switch_jump.zig` are the two files of the library that hold such code.
- `docs/decisions/` holds the decision records.
- `bench/` holds each program that measures the package. `bench/results/` holds the reports of the
  runs that the steps of `bench/README.md` recorded. A file can hold several runs. Record 5 holds
  the first CI run, and `bench/results/switch-github-2026-11-14.md` holds three more.
  `bench/README.md` says what each program measures, and how to record a result. A bench program
  takes a file of the library as a module of its own, which `build/bench.zig` makes. So the
  module `tejedor` exports no name for a probe.
- `bench/switch_probe.zig` is the entry of the probe. `bench/switch_probe_forms.zig`,
  `bench/switch_probe_ways.zig` and `bench/switch_probe_report.zig` are its pieces.
  `bench/std_switch_x86_64.zig` holds std's switch for x86-64 with the list of the package, as a
  copy and as a call, for the probe to compare with the jump (record 6).
  `bench/std_switch_x86_64_test.zig` holds its tests. No file of the library imports them.
- `tools/` holds the developer tools. `zig build lint` runs them, and the build links no part of
  them into the package. The rules come from pepegrillo, a lazy package in `build.zig.zon` that
  only the root build asks for. `tools/` holds tejedor's configuration of each rule. rotor stays
  the one dependency of the library.
- `.githooks/pre-push` is a copy of pepegrillo's hook. It checks the commit messages of a push.
- `tools/linux_test.sh` runs the Linux gate in Docker. `tools/docker_limit.sh` holds the time limit
  of a container, and it is rotor's file. The lint reads the length of each shell script.
- `tools/linux_bench.sh` runs the Linux build of the probe in Docker.

## Ask before

Ask Camilo before you do one of these:

- Add or change a public name. Each public name but `tejedor` is a proposal until Camilo rules it
  with the code.
- Add or change a named limit.
- Change the size or the layout of a hot structure.
- Add a file to the named files of `docs/hot-path-ledger.md`.
- Add a dependency other than rotor.
- Change what the first release holds.
- Change a ruling that the first record lists.
- Weaken an assertion or an invariant to make a test pass.
- Do a thing that rotor's decision 34 lists under "Ask before", for rotor or for the package. rotor
  adds nothing for the package without Camilo's word.

## Commands

- Build: `zig build` compiles the unit tests. `-Drelease` builds ReleaseSafe. ReleaseFast and
  ReleaseSmall are not offered, because assertions stay on in a release build.
- Test: `zig build test` runs the unit tests in Debug and in ReleaseSafe, then checks the format
  of each Zig source but the attachments of `docs/zig-report/`. Every change passes it before it
  is committed. The tests run in both modes
  because the faults of the context switch showed only in an optimized build (decision 34,
  "Upkeep"). It also compiles the unit tests of the package and of the bench programs for Linux on
  aarch64 and on x86-64, and runs none of them. So a change that does not compile or assemble for
  Linux fails on a Mac. It runs the unit tests of the bench programs in both modes, and it compiles
  the probe for the host and for Linux. It runs the four checks below that are compiles.
- One mode alone: `zig build test-debug` and `zig build test-release`.
- Compile-fail check: `zig build test-compile-fail` builds each program of `tools/compile_fail/`,
  and each compile must fail with its message. One program hands the check of the Zig version
  another version. One hands `Fibers` a type that lacks `tick` and `shared`, and the message must
  name both. Two ask for the form of the switch that the package does not use. One asks for
  a copy on x86-64, and Zig refuses an inline call through the cast of the jump (record 6). One
  asks for a call on aarch64 (record 5). `zig build test` runs this step too.
- Check of Windows: `zig build test-windows` compiles the tests of `src/switch.zig` for Windows on
  x86-64 and on aarch64, and runs none. Two comptime asserts of one test stop that compile. One
  stops it when `supported` differs from the rule of `supports`, and one when `supported` is true
  on Windows (record 5). `zig build test` runs this step too.
- Check of Fuchsia: `zig build test-fuchsia` compiles `src/switch.zig` as an object for Fuchsia on
  x86-64 and on aarch64, and emits nothing. The test runner of std 0.16.0 does not compile for
  Fuchsia, so a comptime assert outside the tests of that file stops the compile when `supported`
  is true on Fuchsia (record 5). `zig build test` runs this step too.
- Check of the reserved registers: `zig build test-reserved` builds a copy of the switch for eight
  aarch64 targets where LLVM reserves a register. Each compile must print nothing. LLVM reserves
  `ffr` on a processor with SVE. It reserves `x18` on the systems of Apple, Android, OpenHarmony,
  Fuchsia, UEFI and Windows, and with the feature `reserve_x18`. The aarch64 list names neither
  there (record 5). `zig build test` runs this step too.
- Halt check: `zig build halt-check` runs each scenario of `tools/halt/` in Debug and in
  ReleaseSafe, and the canary. `zig build test` runs this step too.
- Timer program: `zig build bench-timers -- --backend tejedor --timers 256` runs the timer
  program in ReleaseSafe. `--backend threaded` runs `std.Io.Threaded`. Record 7 says how its
  first numbers ran, beside rotor's `rotor_timers`.
- Tests that do not run: a plain `zig build test` prints nothing for a test that it does not
  run. `zig build test --summary all` counts them for each step, and the Linux gate prints a
  `SKIP` line for each one. The test of `src/switch_test_entry.zig` makes system calls of Linux,
  so it does not run on macOS (record 4). A test of `src/switch_test_floats.zig` runs only for a
  target with AVX-512 (record 6). `zig build test` builds for the processor of the host, so a
  host with no AVX-512 skips it. The five tests of
  `bench/std_switch_x86_64_test.zig` run on x86-64 alone.
- Linux gate: `zig build test-linux && bash tools/linux_test.sh`. The build step compiles the unit
  tests of the package and of the bench programs for Linux on aarch64 and on x86-64, in Debug and
  in ReleaseSafe, into `zig-out/linux/`. The bench programs are in the gate because some of their
  tests run on x86-64 alone (record 5).
  It runs none of them. The script runs each one in a Docker container of its own, and stops at
  the first failure.
  - `bash tools/linux_test.sh linux/arm64` runs the executables of one platform alone.
  - Docker runs an executable of the host's processor on that processor, and each other one under
    an emulator. The script says which. On the development Mac, OrbStack runs the x86-64
    executables with Rosetta. An emulator ran those tests, so a pass does not show what a real
    x86-64 processor does. A real x86-64 processor runs the tests in CI.
  - The script refuses an install that is older than a source, and it fails a container that
    runs longer than the limit of `tools/docker_limit.sh`.
  - `zig build test` does not run the gate, because it needs Docker.
  - Each test executable of the package runs twice: with io_uring, in a container whose seccomp
    profile is relaxed, and with epoll, under Docker's default profile. `tools/linux_backend.zig`
    proves the backend of each kind of container first. The halt check runs with both too.
  - Rosetta lacks system calls of rotor: it gives no io_uring ring, and the `init` of an epoll
    reactor returns `Unsupported`. So on the development Mac each x86-64 test that needs a
    reactor skips, and so do the halt scenarios of `Fibers`, and the script says so. The job
    `linux-gate` of CI runs the gate on each Linux platform with its own processor.
- Probe of the context switch: `zig build bench-switch -- --machine <name>` builds the probe in
  ReleaseSafe and runs it on this host. The report is Markdown on standard output. It gives each
  form of the switch in three shapes: in the loop, in one function that both sides call, and in a
  function of each side. Each function returns after the switch (record 5).
  - `zig build bench-linux && bash tools/linux_bench.sh --machine orbstack` runs the Linux build
    in Docker. The script prints the load of the host too, because a container does not see it.
  - `zig build test-bench` runs the unit tests of the bench programs alone. Measure a mutation
    of a bench program against it. On an aarch64 host it runs none of the x86-64 tests, so
    measure those against the Linux gate.
  - A number is taken on an idle machine. A run on a busy machine is no final number, and its
    file in `bench/results/` says so. `bench/README.md` names the machines.
- Format: `zig build fmt` formats each Zig source but the attachments of `docs/zig-report/`.
- Lint: `zig build lint` scores the cognitive complexity of each function over `build.zig`,
  `bench`, `build`, `src` and `tools`. Then it runs the rules of `tools/lint`: heap, determinism,
  unbounded-loop, relative-import, markdown, file-length, magic-numbers, defer-order,
  unreleased-acquire, static-alignment, global-state, undefined-fill and switch-form. A canary
  tree in `build/lint.zig` proves that each rule runs. `zig build test` runs the lint too, with
  the tests of the tools, the hook check, and the format check of `build` and `tools`.
  - determinism refuses a clock or a random source under `src/`. `std.Io.Clock` is no finding,
    because the `now` of the table takes one. rotor's configuration refuses `std.Io.Clock`. That
    difference is a choice of the session, and so are the ten host calls that the rule adds
    (`tools/lint/determinism.zig`). Camilo has not read them.
  - global-state refuses a container-level `var` under `src/` that is not `threadlocal`.
  - undefined-fill refuses a local array that a function under `src/` sets to `undefined`, because
    Debug and ReleaseSafe fill it on each call. It passes an array of at most 8 elements, and an
    array whose declaration shows a size under 64 bytes. It stops at the line
    `const testing = std.testing;` of a file.
  - A file whose stem ends in `_test`, or holds `_test_`, holds tests alone. magic-numbers,
    global-state and undefined-fill do not read it.
  - magic-numbers does not read `src/zig_version.zig`, whose one number is the minor number of the
    pinned Zig version.
  - switch-form refuses a reference to `switch_other_form` under `src/`, but in `src/switch.zig`
    and in the test files (record 5). Its header lists the references that it cannot see. The
    rule is a choice of the session, and Camilo accepted it on 2026-11-14.
  - static-alignment does not read `docs/zig-report/`, the attachments of the report to Zig.
    They are the programs that ran, and the build compiles none of them. The complexity score,
    the file-length rule and the format check do not read them either (record 5). The exemption
    is a choice of the session, and Camilo accepted it on 2026-11-14.
  - A commit that adds a directory of sources adds it to the lists of `build/tools.zig`.
- Tools: `zig build test-tools` runs the tests of the tools alone. Measure a mutation of the
  configuration of a rule against it.
- Commit messages: run `zig build hooks` once after you clone. It points `core.hooksPath` at
  `.githooks`. `zig build lint-commits` checks `origin/main..HEAD`. `tools/commit_lint.zig` holds
  the scopes of the table in "Commits", so a commit that adds a scope adds it there too.
  `.githooks/pre-push` is a copy of pepegrillo's hook, and `zig build test` fails when the two
  differ.
- Pin of the tools: the first build fetches pepegrillo. To move the pin, run
  `zig fetch --save=pepegrillo git+https://github.com/c4milo/pepegrillo#<commit>`. Then confirm
  that `.lazy = true` is still set in `build.zig.zon`, and copy the new hook.
- Dependency: the first build fetches rotor at the pinned tag.
- Continuous integration: `.github/workflows/ci.yml` runs on each push to `main`, and when a
  person starts it by hand. tejedor takes no pull requests, so no job runs for one.
  - The job `test` runs `zig build test` on three kinds of GitHub-hosted runner: macOS on Apple
    silicon, Linux on x86-64 and Linux on arm64.
  - The job `probe` runs only on a start by hand, on Linux on x86-64. It runs
    `zig build bench-switch -- --machine github`, the probe of the context switch, and it prints
    what its runner is. It ran on 2026-11-13 at `ded6989` (record 5), and three times on 2026-11-14
    at `ba1daf0` (record 6).
  - The job `commits` runs on a push only. It checks the commit messages that the push added to
    `main`, with the linter of `tools/commit_lint.zig`. `zig build lint-commits` checks
    `origin/main..HEAD`, which holds no commit after a push, so the job gives the linter the range
    of the push. The job needs the lint and the CI.
  - `.github/actions/zig` downloads Zig from ziglang.org and checks it against a pinned SHA-256.
    No third-party action runs. GitHub's own `actions/cache` keeps the Zig tarball and Zig's
    package cache between runs.
  - A number from CI is no number of a quiet machine. It names its runner.
  - Camilo ruled on 2026-11-12 that the package has CI on GitHub's runners (decision 34, "Ask
    before"). "Where the work stands" holds what he ruled.

## Where the work stands

Camilo accepted rotor's decision 34 on 2026-11-11. The work on the package started on 2026-11-12.
Nothing is released.

Camilo ruled on the package on 2026-11-12. The session asked each question with its choices:

| what Camilo ruled on 2026-11-12 | where it shows |
|---|---|
| pepegrillo gives the lint tools of the package, wired as rotor wires them (decision 34, "Ask before") | `tools/` and `build/tools.zig` |
| The package has CI on GitHub's runners (decision 34, "Ask before"). The setup and step 0 go to `main` by a push. The package takes no pull requests, as rotor takes none | `.github/` |
| The switch gets a fourth correction of the clobber lists: the x86-64 list names `xmm0` to `xmm15`. A record of the package states the departure from decision 34, and rotor's decision 34 gets a note | record 2. rotor does not hold the note yet |

On 2026-11-13 Camilo ruled on the errors that the reviews of the switch found. He read the
measured failures and the busy numbers of the probe first:

| what Camilo ruled on 2026-11-13 | where it shows |
|---|---|
| On aarch64 the list names `nzcv`, and each caller holds a copy of the switch. On x86-64 each caller calls the switch, and the compiler never inlines the call | record 3. Since record 5, the declaration of `switch_context` in `src/switch.zig` |
| The switch saves no control register. The rounding mode and the exception masks belong to the thread, and a fiber that changes them restores them before it blocks | record 3, and the header of `src/switch.zig` |
| The argument of a new fiber is above its first stack pointer, and `main` starts with a return address of zero, on both architectures | record 4, and `initial_context` in `src/switch.zig` |

Later on 2026-11-13 the CI ran the probe on a real x86-64 processor, and Camilo ruled a second
round. He asked first why the switch is never inlined on x86-64, and read the session's answer:

| what Camilo ruled on 2026-11-13, second round | where it shows |
|---|---|
| "Call, and probe a jump": a plain call of `switch_context` is a call on x86-64 and a copy on aarch64, and `call_modifier` goes | record 5, `switch_context` in `src/switch.zig`, `src/switch_test_form.zig` and `tools/compile_fail/` |
| The probe gets a candidate for x86-64: a switch in assembly in the style of Boost.Context, under `bench/` alone. It replaces the call only if it measures faster, and Camilo rules it | record 5. Since record 6 the jump is the switch of x86-64, in `src/switch_jump.zig` |
| The aarch64 list does not name `ffr`, a register that LLVM reserves. A record states the departure from std's list | record 5, the list in `src/switch.zig`, and `zig build test-reserved` |
| `supported` is false on Windows, so a `true` is never wrong. The session chose the exact set of systems | record 5, `supports` and `supported` in `src/switch.zig`, and `zig build test-windows` |
| A report to Zig. A separate agent drafts it, and Camilo posts it himself | `docs/zig-report.md`, its three issues beside it, and `docs/zig-report/` |

On 2026-11-14 the CI ran the probe three times at `ba1daf0`, on three runners with three x86-64
processors. Camilo read the numbers, and ruled a third round:

| what Camilo ruled on 2026-11-14, third round | where it shows |
|---|---|
| The jump replaces the call as the switch of x86-64, with its one-word `Context` and its own first stack, a ledger row and a record 6. Its tests and mutations move with it, in step 0, before step 1 | record 6, `src/switch_jump.zig`, `switch_context` in `src/switch.zig`, and rows L4 to L6 of `docs/hot-path-ledger.md` |
| `supported` is false on Fuchsia, on both architectures | record 5, `supports` and `supported` in `src/switch.zig`, and `zig build test-fuchsia` |
| The choices of the session that record 5 lists stay as built | record 5, "Choices of the session" |
| The three CI reports of the probe go in the tree | `bench/results/switch-github-2026-11-14.md` |

| step | what it holds | state |
|---:|---|---|
| 0 | the context switch of a fiber, its tests and its probe | built on 2026-11-12, and changed by the rulings of 2026-11-13 and 2026-11-14. The final numbers of the probe on aarch64 are from `mac` and `orbstack` on 2026-11-15. Its numbers on x86-64 are from CI |
| 1 | contexts, std tasks, `Io.Group`s, cancel, futexes, `now`, `sleep` and the `netLookup` wrapper, on one thread | built on 2026-11-14 (record 7). Its first numbers are from a busy machine |
| 2 | the wake from another thread | not started |
| 3 | the calls of the package's own: `perform` and `call` | not started |
| 4 | the network calls and `fileClose`, with the batch calls for one `net_receive` with its deadline | not started |
| 5 | the numbers | not started |
| 6 | datagrams, batches and files, when a consumer asks | not started |

The first release holds steps 0 to 5. Step 4 carries one part of step 6, the batch calls for one
`net_receive`, by the ruling of 2026-11-11 under question 19. The rest of step 6 waits for a
consumer.

Camilo closed step 0 on 2026-11-14, and asked for step 1. He ruled four questions of step 1 that
day, and chose the first choice of each (record 7):

| what Camilo ruled on 2026-11-14, for step 1 | where it shows |
|---|---|
| The public names of step 1 are the names of the sketch of decision 34 | `src/tejedor.zig`, and record 7 |
| tejedor exports `supported`, and `Fibers` fails to compile where it is false | `src/tejedor.zig` and `src/fibers.zig` |
| The named limits of step 1 have the values of decision 34 and decision 22 | `src/constants.zig` |
| The first numbers come now, from a copy of rotor's timer program | `bench/std_io_timers.zig`, and record 7 |

He reads the results of step 5 before a release.

The package holds the build files, the root file with no public name and the check of the Zig
version. Its lint on pepegrillo is built, as Camilo ruled on 2026-11-12.

The context switch and its tests are built. On aarch64 the switch is the code that rotor's
decision 22 removed, with its corrections of std's clobber lists. On x86-64 it is the jump of
record 6, which holds no code of std. Records 2 to 6 hold each change since then, by the rulings
above and by the choices that records 5 and 6 list.

Step 0's check names three platforms, and each ran the tests in Debug and in ReleaseSafe on
2026-11-14, with the jump. aarch64 macOS ran them on `mac` with `zig build test`. aarch64 Linux and
x86-64 Linux ran them in Docker on `mac` with the Linux gate, x86-64 under Rosetta. The CI ran
`zig build test` at `ded6989` on GitHub's runners of macOS on Apple silicon, Linux on arm64 and
Linux on x86-64, and each job passed. No real x86-64 processor has run the tests of the jump in
`src/` yet: the next CI run does. The test of AVX-512 runs there only on a runner whose
processor has AVX-512, and no log has shown such a run yet.

The probe is built. Each run of `mac` and `orbstack` in `bench/results/` was on a busy machine, so
none is a final number. Record 5 gives one CI run at `ded6989`, and the prior of the session on
three shapes. `bench/results/switch-github-2026-11-14.md` holds three CI runs at `ba1daf0`, which
record 6 reads. No run of the probe has measured the jump in `src/` yet.
