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
   other call halts there (decision 34, questions 8 and 15). `Fibers` is the name of the design,
   and it is a proposal.
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

- An optimized build can copy the body of `switch_context` into its caller, and a Debug build
  calls the function. Only the copy lets a caller keep a value in a register across the switch.
- On aarch64 macOS the compiler saves the callee-saved registers in pairs. So the function still
  saves a register that the list misses, when the list holds the other register of its pair.
- On x86-64 the names `zmm0` to `zmm31` kept no value out of an `xmm` register, for a target with
  no AVX-512 (record 2). The Linux gate builds for the baseline processor, which has none.

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
"Upkeep"). The halt check comes with step 1, which lists its first eight scenarios (decision 34,
"Build order"). The package has no halt check before that step.

Two assertions wait for the halt check: the two of `initial_context` in `src/switch.zig`. A
caller's mistake reaches both, with a stack end that is not aligned, or with a stack end of 0. A
mutation that deletes them is NOT CAUGHT today. Their two scenarios come beside the eight of step
1.

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
  | `bench` | the probe, and each program that measures the package |
  | `tools` | developer tools |

  A commit that adds a part of the library adds its scope to this table. A commit that touches the
  build files or the root file alone takes no scope. The three scopes and these two rules are a
  proposal of the session of 2026-11-12, and Camilo has not ruled on them.
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
- `tools/compile_fail/` holds each program that must not compile. `build.zig` holds the message
  that such a compile must print.
- Tests belong in the file that they test. The tests of the context switch are in files of their
  own, because they need a stack and contexts that outlive a function.
- The limits belong in `src/constants.zig`, which comes with the first limit. A comptime assert
  stays with the constant that it pins.
- `src/switch.zig` holds the context switch of a fiber, the entry of a new fiber, and the first
  context of a new fiber. It is assembly. The module `tejedor` exports no name of it.
- `src/switch_test.zig` and `src/switch_test_registers.zig` hold the tests of the switch. A file
  whose stem ends in `_test`, or holds `_test_`, holds tests alone.
- `docs/hot-path-ledger.md` is the ledger of the package for ugly code, such as assembly
  (decision 34, "What it keeps"). Each use has a row there, and `src/switch.zig` is the one file
  of the library that holds such code.
- `docs/decisions/` holds the decision records.
- `bench/` holds each program that measures the package, and `bench/results/` holds one Markdown
  file for each recorded run. `bench/README.md` says what each program measures, and how to record
  a result. A bench program takes a file of the library as a module of its own, which
  `build/bench.zig` makes. So the module `tejedor` exports no name for a probe.
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
  of each Zig source. Every change passes it before it is committed. The tests run in both modes
  because the faults of the context switch showed only in an optimized build (decision 34,
  "Upkeep"). It also compiles the unit tests for Linux on aarch64 and on x86-64, and runs none of
  them. So a change that does not compile or assemble for Linux fails on a Mac. It runs the unit
  tests of the bench programs in both modes, and it compiles the probe for the host and for Linux.
- One mode alone: `zig build test-debug` and `zig build test-release`.
- Compile-fail check: `zig build test-compile-fail` builds the program of `tools/compile_fail/`.
  Its compile must fail with the message of the check of the Zig version. `zig build test` runs
  this step too.
- Tests that do not run: a plain `zig build test` prints nothing for a test that it does not
  run. `zig build test --summary all` gives the count of such tests for each step, and the Linux
  gate prints a `SKIP` line for each one. Today one test does not run on each platform, where a
  known error of the switch shows ("Where the work stands").
- Linux gate: `zig build test-linux && bash tools/linux_test.sh`. The build step compiles the unit
  tests for Linux on aarch64 and on x86-64, in Debug and in ReleaseSafe, into `zig-out/linux/`.
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
  - The tests of step 0 enter no io_uring. Step 1 adds the runs with io_uring and with epoll
    (decision 34, "Upkeep").
- Probe of the context switch: `zig build bench-switch -- --machine <name>` builds the probe in
  ReleaseSafe and runs it on this host. The report is Markdown on standard output.
  - `zig build bench-linux && bash tools/linux_bench.sh --machine orbstack` runs the Linux build
    in Docker. The script prints the load of the host too, because a container does not see it.
  - `zig build test-bench` runs the unit tests of the bench programs alone. Measure a mutation
    of a bench program against it.
  - A number is taken on an idle machine. A run on a busy machine is no final number, and its
    file in `bench/results/` says so. `bench/README.md` names the machines.
- Format: `zig build fmt` formats each Zig source.
- Lint: `zig build lint` scores the cognitive complexity of each function over `build.zig`,
  `bench`, `build`, `src` and `tools`. Then it runs the rules of `tools/lint`: heap, determinism,
  unbounded-loop, relative-import, markdown, file-length, magic-numbers, defer-order,
  unreleased-acquire, static-alignment, global-state and undefined-fill. A canary tree in
  `build/lint.zig` proves that each rule runs. `zig build test` runs the lint too, with the tests
  of the tools, the hook check, and the format check of `build` and `tools`.
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
    what its runner is. No run of it exists yet.
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

| step | what it holds | state |
|---:|---|---|
| 0 | the context switch of a fiber, its tests and its probe | built on 2026-11-12. Camilo has not read the numbers, and two errors of the clobber lists wait for his word |
| 1 | contexts, std tasks, `Io.Group`s, cancel, futexes, `now`, `sleep` and the `netLookup` wrapper, on one thread | not started |
| 2 | the wake from another thread | not started |
| 3 | the calls of the package's own: `perform` and `call` | not started |
| 4 | the network calls and `fileClose`, with the batch calls for one `net_receive` with its deadline | not started |
| 5 | the numbers | not started |
| 6 | datagrams, batches and files, when a consumer asks | not started |

The first release holds steps 0 to 5. Step 4 carries one part of step 6, the batch calls for one
`net_receive`, by the ruling of 2026-11-11 under question 19. The rest of step 6 waits for a
consumer.

Camilo reads the numbers of the probe before step 1, so nothing of step 1 is built before he does.
He reads the results of step 5 before a release.

The package holds the build files, the root file with no public name, and the check of the Zig
version.

The context switch and its tests are built. The switch is the code that rotor's decision 22
removed, with its three corrections of std's clobber lists. It also holds a fourth correction,
of the package's own.

**The fourth correction is record 2, by Camilo's ruling of 2026-11-12.** On x86-64 the list of std
names `zmm0` to `zmm31` alone. For a target with no AVX-512, an optimized build then kept a
floating-point value in an `xmm` register across the switch. The other context changed it.
The list of the package names `xmm0` to `xmm15` too. Decision 34 takes the switch with "nothing
but the names" changed, and record 2 departs from that sentence. Record 2 also says what the
correction does not cover.

**Two more errors of the clobber lists are known, and they are not corrected.** A test of
2026-11-12 shows each one, in `src/switch_test.zig`. Each test does not run where its error shows.
Each correction needs Camilo's word before step 1, as the fourth did. On a platform with such an
error, a fiber of step 1 can lose the value at each call that blocks.

| what the list misses | where the test failed, in ReleaseSafe | the test, and where it does not run | what a changed list did |
|---|---|---|---|
| the condition flags of aarch64, `nzcv` | aarch64 macOS on `mac`, and aarch64 Linux in Docker | "a comparison before a switch decides the same way after the switch", on aarch64 (`flags_covered`) | with `nzcv` in the list, the test passed |
| the x87 registers of x86-64, which hold an `f80` value | x86-64 Linux in Docker, under Rosetta | "the main context and a fiber each keep an f80 value across a switch", on x86-64 (`extended_covered`) | with `st0` to `st7` in the list, the test still failed. Those names have no effect in Zig 0.16.0 (record 2) |

With a `noinline` `switch_context` and no change of a list, both tests passed in ReleaseSafe on
the three platforms. That is a change of the design, and it is Camilo's choice too.

Step 0's check names three platforms. This is what ran on 2026-11-12:

| platform | where the tests ran | modes |
|---|---|---|
| aarch64 macOS | `mac`, with `zig build test` | Debug and ReleaseSafe |
| aarch64 Linux | Docker on `mac`, with the Linux gate | Debug and ReleaseSafe |
| x86-64 Linux | Docker on `mac`, with the Linux gate, under Rosetta | Debug and ReleaseSafe |

No real x86-64 processor has run the tests. CI runs them on one, and no push has started the CI.

The probe is built, and `bench/results/` holds two files, for `mac` and for `orbstack`. Each
holds four runs. Each run was on a busy machine, so none is a final number. The probe has not
run on a quiet `mac` or on a GitHub runner. It measures the switch in two forms: as the compiler
builds the call, and with `switch_context` never inlined. The second form is what a `noinline`
switch costs.

The lint on pepegrillo is built, as Camilo ruled on 2026-11-12.
