# 4. The argument of a new fiber is above its stack pointer

Status: **accepted**. Camilo ruled on 2026-11-13. The session wrote this record the same day, with
the change. The ruling is Camilo's. The reasons against each alternative below are the session's,
and Camilo has not read them.

Note of 2026-11-14: record 6 makes the jump the switch of x86-64, with its own first stack and its
own entry. So the x86-64 column of this record no longer describes `src/switch.zig`, and
`bench/std_switch_x86_64.zig` keeps it for std's switch in the probe. The first stack of the jump
keeps the rules of this record. Each word that the fiber needs is at or above its first stack
pointer, and the argument reaches `main` in a register. `main` starts with a return address of zero,
a frame pointer of zero, and a stack pointer 8 bytes past a multiple of 16. Record 6 holds its tests
and mutations. The aarch64 column does not change. The test of the first stack is now in
`src/switch_test_start.zig`, and it also checks that `initial_context` writes no byte below the
first stack pointer. So the aarch64 macOS mutation that this record gives as NOT CAUGHT is CAUGHT in
Debug and in ReleaseSafe (record 6).

## The decision

`initial_context` and the entry of a new fiber in `src/switch.zig` change on both architectures.
`stack_end` is the address one byte after the stack of the fiber:

| | aarch64 | x86-64 |
|---|---|---|
| the word of the argument | `stack_end - 8`, as before | `stack_end - 8`, as before |
| the first stack pointer | `stack_end - 16`. It was `stack_end` | `stack_end - 24`. It was `stack_end - 8` |
| the return address that `main` sees | zero: the entry clears the link register | zero: the word at the first stack pointer |
| the stack pointer that `main` sees | a multiple of 16 | 8 bytes past a multiple of 16, as after a call |

So the word of the argument is above the first stack pointer on both architectures. A stack trace
from a fiber ends at the frame of `main`.

## The errors

The first context and the entry came from rotor's decision 22, which took them from std's
`Kqueue.mainIdleEntry`. A review of 2026-11-12 found three faults, and a second session measured
each one again:

1. **On aarch64 the entry read its argument below the stack pointer**, with `ldr x0, [sp, #-8]`.
   On Linux, a signal handler that runs on the fiber's stack before that read writes over the
   word. The kernel puts its signal frame right below the stack pointer.
2. **On aarch64 `main` started with the link register of the other context.** A stack trace from
   a fiber then printed one false frame. A halt in a fiber then died by SIGSEGV, where a halt on
   the main context died by SIGABRT.
3. **On x86-64 `main` took the argument as its return address.** A stack trace from a fiber then
   printed one false frame, and an "Unwind error" line.

## The measured failures

Each run was on `mac`, and each is one run on a busy machine. The aarch64 Linux runs were in
Docker, in the Linux virtual machine of OrbStack, with no emulator. The x86-64 runs were in Docker
under Rosetta.

On aarch64 Linux, a program of the second session set the stack pointer of the first context.
Then it sent itself one SIGUSR1, and jumped to the entry:

| the entry | mode | signal | the argument that the fiber saw |
|---|---|---|---|
| the old entry | ReleaseSafe | none | the argument |
| the old entry | ReleaseSafe | one | a code address of the program |
| the old entry | Debug | one | a code address of the program |
| the argument 8 bytes above the stack pointer | Debug and ReleaseSafe | one | the argument |

Programs of the review and of the second session started fibers in a loop, with a SIGALRM each 20
microseconds:

| who ran it | system | mode | signals | new fibers | fibers with a wrong argument |
|---|---|---|---:|---:|---:|
| the review | aarch64 Linux | ReleaseSafe | 200,006 | 630,363,901 | 2,588 |
| the review | aarch64 Linux | Debug | 200,008 | 90,821,322 | 1,620 |
| the second session | aarch64 Linux | ReleaseSafe | 200,006 | 660,836,350 | 568 |
| the second session | aarch64 Linux | Debug | 200,018 | 102,514,911 | 204 |
| the second session, with the argument 8 bytes above the stack pointer | aarch64 Linux | ReleaseSafe | 200,006 | 701,102,309 | 0 |
| the second session | aarch64 macOS | ReleaseSafe | 200,010 | 565,176,632 | 0 |
| the second session | aarch64 macOS | Debug | 200,014 | 92,440,484 | 0 |

A program that halts in a fiber, with the old entry:

| system | mode | frames printed | how the process ended |
|---|---|---:|---|
| aarch64 macOS | Debug and ReleaseSafe | 3, and the third is false | SIGSEGV, status 139 |
| aarch64 Linux | Debug and ReleaseSafe | 3, and the third is false | SIGSEGV, status 139 |
| x86-64 Linux, under Rosetta | Debug and ReleaseSafe | 2, then a false frame and "Unwind error" | SIGABRT, status 134 |

With the link register cleared on aarch64, the same program printed 2 frames and ended with
SIGABRT, status 134. With a zero word in the place of the return address on x86-64, it printed the
2 true frames and no "Unwind error".

The session ran the program that halts again on 2026-11-13, with the change of this record. A
halt in a fiber then printed 2 frames, `halt_here` and `fiber_main`, and the process ended with
SIGABRT, status 134. That held on aarch64 macOS, aarch64 Linux and x86-64 Linux under Rosetta, in
Debug and in ReleaseSafe. No line read "Unwind error".

## The tests

- **"a new fiber gets its argument when a signal arrives at its first stack pointer"**, in
  `src/switch_test_entry.zig`. It starts a fiber through a step that runs at the first stack
  pointer. The step sends SIGUSR1 to its own thread, and then it jumps to the entry. So the
  handler runs at that stack pointer each time, with no race. It runs on Linux alone, because it
  makes system calls of Linux. macOS showed no fault in the runs above.
- **"a new fiber starts with its argument, on an aligned stack that ends at the stack's end"**, in
  `src/switch_test.zig`. It now checks that `main` sees a return address of zero, on both
  architectures.

## The mutations

The session ran each mutation on 2026-11-13, with this change in place. Each cell gives Debug,
then ReleaseSafe. C is CAUGHT, n is NOT CAUGHT, and a dash is a build that did not run. The x86-64
runs were under Rosetta.

| mutation | aarch64 macOS | aarch64 Linux | x86-64 Linux |
|---|---|---|---|
| none | pass, pass | pass, pass | pass, pass |
| the old aarch64 entry, whole | C, C | C, C | - |
| the argument below the stack pointer on aarch64, with the link register cleared | n, n | C, C | - |
| the link register not cleared on aarch64 | C, C | C, C | - |
| the old x86-64 entry, whole | - | - | C, C |
| no zero word at the first stack pointer of x86-64 | - | - | C, C |
| the first stack pointer 8 bytes off | C, C | C, C | C, C |
| the word of the argument one word low | C, C | C, C | C, C |
| a first frame pointer that is not zero | C, C | C, C | C, C |
| the entry loads the wrong register | C, C | C, C | C, C |
| the first stack pointer above the end of the stack | C, C | C, C | C, C |

The NOT CAUGHT on aarch64 macOS is expected: the review showed no fault there, and the test of the
signal does not run on macOS. On aarch64 Linux the test of the signal catches it.

## Alternatives that lost

1. **Keep the entry, and give each thread an alternate signal stack.** The program owns the
   signal setup of its threads, and a handler with no `SA_ONSTACK` still runs on the fiber's stack.
2. **Carry the argument in the frame pointer, as std's `Uring.mainIdleEntry` does.** It corrects
   the first fault: in the review's run with a timer, no fiber got a wrong argument. It changes
   nothing for a stack trace, and the two architectures then differ in how the argument comes.
3. **Correct the first fault alone.** A halt in a fiber then still prints a false frame, and on
   aarch64 it still dies by SIGSEGV.
4. **State the false frame in a comment, and change no code.** The halts of step 1 run in fibers,
   and assertions stay on in a release build. So each such halt would print the false frame.

## What departs from std and from rotor's decision 34

- **std.** `Kqueue.mainIdleEntry` reads `[sp, #-8]` on aarch64 and `(%rsp)` on x86-64, and it
  leaves the link register as it finds it. The entry of the package reads `[sp, #8]` and
  `16(%rsp)`, and it clears the link register.
- **rotor's decision 34, "Where the code starts".** It takes the switch, the entry and the first
  context with "nothing but the names" changed. This record departs from that sentence for the
  entry and the first context.
- **The cost.** The first frame takes 16 bytes of each stack on aarch64, and 24 on x86-64. It took
  0 and 8 before. A stack of decision 34 has 256 KiB.

Row L2 of `docs/hot-path-ledger.md` names the test of the signal. The package changes no file of
rotor.

## Sources

- `std/Io/Kqueue.zig` and `std/Io/Uring.zig` of Zig 0.16.0, for `mainIdleEntry`.
- The reviews of 2026-11-12, and the runs of the second session the same night. Their programs and
  logs are outside the tree.
- rotor's decision 34 at `128b8da`, "Where the code starts".
