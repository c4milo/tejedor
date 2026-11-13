# 5. A plain call of the switch, and a probe of a jump: the probe

This file is a piece of record 5, [`0005-a-plain-call-of-the-switch-and-a-probe-of-a-jump.md`](0005-a-plain-call-of-the-switch-and-a-probe-of-a-jump.md). The record passed 500 lines, so its
part on the probe is here. Its status and its rulings are those of the record.

## A prior to test: the prediction of returns

The session reasoned this part, and it is no measurement. Camilo has not read it.

The first probe switched in a loop that never returns. A caller of step 1 switches in a function,
`block`, and then returns. A processor predicts a return from a stack of the return addresses of
the calls that it saw. After a switch, a return can go to an address that the other context
pushed. The processor then predicts that return wrong. By this model, one pair predicts these
returns wrong:

| form | in the loop | in one function that both sides call | in a function of each side |
|---|---:|---:|---:|
| a copy of the switch | 0 | 2 | 2 |
| a call of the switch | 2 | 2 | 4 |
| the jump candidate, on x86-64 | 0 | 2 | 2 |

- In the loop, a copy makes no call. A call of the switch returns one time on each side, to an
  address of the other side.
- In one function, each side returns from that function to the loop of the other side. A call of
  the switch returns too, but both sides make that call from the same place of the function. So
  the processor predicts that return right.
- In a function of each side, the return from a call of the switch also goes to the function of
  the other side. So a call makes four wrong returns there.
- The candidate resumes with a jump, so its call of `jump_switch` never returns. In the loop it
  makes no return. In a function, the return of the function goes to the other side, as for a
  copy.

A review of 2026-11-13 corrected the count of a call in one function from four to two. So the loop
can make the copy look better against the call than it is in step 1.

Step 1 is closest to a function of each side. A fiber blocks in `block`, and the main context
resumes it from a function of its own. A switch from the `block` of one fiber to the `block` of
another is closest to one function.

### The three shapes

The probe runs each form in three shapes (`bench/switch_probe_forms.zig`):

- **In the loop**, on both sides.
- **In one function that both sides call.** The function is never inlined. After the switch, an
  empty block of assembly keeps a call of the switch a call. So the function returns after the
  switch in each form.
- **In a function of each side.** The two functions are never inlined, and each returns after the
  switch. The function of the fiber holds one `nop` more, so an optimized build cannot merge the two
  into one.

The probe runs each row one time, in a fixed order. First come the three shapes of the form of
the package, then the three of the other form. On x86-64 the three of the candidate come last. So
a row of the candidate runs six rows after the row of the call in the same shape. A drift of the
machine can fall on one row more than on another.

### The test of the form of a row

The test of the probe reads the address that each side saved at its last switch. It finds the
function that holds the address, among the function of the call and the functions of each row.
For a call, that is the function of the call. The test also reads the return address of the call
from the frame of the switch. That address must be in the function of the side. For a copy, the
saved address must be in the function of the side. In the shape of a function of each side,
the test also checks that the two sides have two functions.

In the loop, the main context switches in the code of `measure.zig`, which has no address in the
test. There the test checks the form alone. A call saves the address in `switch_called` that the
fiber of the call in the loop saved too, and a copy saves another one. So a row that runs another
form than its label fails, and so does a row that runs another function in a shape with functions.

### Busy numbers of `mac`

The session ran the probe three times on `mac` on 2026-11-13, with
`zig build bench-switch -- --machine mac`. The load average was 49.76 to 77.31 over one minute, so
these are no final numbers. `bench/results/switch-mac-2026-11-13-shapes.md` holds the three
reports. The medians of a row moved by up to 2.7 times from run to run. So the table gives the
least sample of each row, which other work delayed least, in ns, for the three runs:

| form | in the loop | in one function that both sides call | in a function of each side |
|---|---|---|---|
| a copy of the switch, the form of the package on aarch64 | 4.79, 4.78, 4.79 | 28.3, 28.7, 28.3 | 28.8, 29.6, 28.8 |
| a call of the switch | 27.6, 27.6, 27.6 | 32.2, 31.4, 31.2 | 42.5, 42.1, 41.6 |

What the numbers show against the prior:

- The order agrees with the counts of the model. A copy in the loop, with no wrong return, is the
  fastest. The cells with two come next, and a call in a function of each side, with four, is the
  slowest.
- A call takes about 10 ns more in a function of each side than in one function, for two more
  wrong returns. Those two cells differ by one `nop`, and by the function that each side calls.
- A copy takes about 24 ns more in a function than in the loop. That step adds two wrong returns,
  and more work. In a function the copy saves and restores the callee-saved registers at each
  switch, as the call does, and in the loop it does not. In the ReleaseSafe probe on `mac`, a copy
  in one function holds the same instructions as `switch_called`. Its least sample, 28.3 ns, is
  close to the 27.6 ns of a call in the loop.
- A call in one function takes about 4 ns more than a call in the loop, with the same count. That
  is the cost of the call and the return of the function, which the processor predicts right.
- So on `mac` the copy leads the call by about 23 ns in the loop, and by about 3 ns in one
  function. It leads by about 13 ns in a function of each side.

### The mutations of the probe

The session ran each mutation on 2026-11-13, on `mac`, against `zig build test-bench`. That step
runs the unit tests of the bench programs in Debug and in ReleaseSafe. Each cell gives Debug, then
ReleaseSafe. C is CAUGHT, and n is NOT CAUGHT.

| mutation | `zig build test-bench` |
|---|---|
| none | pass, pass |
| the row of the other form runs the form of the package | C, C |
| the rows of the form of the package run the other form | C, C |
| in a function of each side, the fiber calls the function of the main context | C, C |
| in a function of each side, the main context calls the function of the fiber | C, C |
| the function of the fiber holds no `nop` | n, C |
| in one function, each side switches in the loop | C, C |
| the probe measures two shapes alone | C, C |
| a function of each side prints the words of one function | C, C |
| the fiber does not count its runs | C, C |
| the buffer of the report is 1,024 bytes | C, C |
| in the loop, the main context of the copy and of the call runs the other form | C, C |
| in a function of each side, the fiber of the call calls the function of the main context | C, C |
| in a function of each side, the main context of the call calls the function of the fiber | C, C |
| in one function, the fiber of the copy switches in its own loop, and counts as the function does | C, C |
| in a function of each side, the fiber of the copy switches in its own loop, and counts | C, C |
| in one function, the fiber of the call calls the switch from its own loop, and counts | C, C |

With the first test of the form, five of the last six mutations were NOT CAUGHT in both modes. A
review of 2026-11-13 found four of them, and the session found the fifth. That test read no return
address of a call, and only three functions of the probe. The session ran each mutation of the
table again after the change. It also ran the four of them that change the call on x86-64 Linux
under Rosetta, where the call is the form of the package. Each was CAUGHT in Debug and in
ReleaseSafe there.

With no `nop`, the two functions of the sides hold the same code. A ReleaseSafe build then keeps
one copy of that code, so the two sides run one function, and the test of the form fails. A Debug
build keeps both functions, so the test passes there. That NOT CAUGHT is expected.

## 1, second part: the jump candidate

### The design

`bench/jump_switch.zig` holds a switch for x86-64 System V in the style of Boost.Context. The
session wrote it from the design of `jump_x86_64_sysv_elf_gas.S` of Boost.Context, and copied no
code of Boost:

1. A caller calls `jump_switch`, a function in assembly. The call pushes the address to resume at.
2. The function pushes `rbp`, `rbx` and `r12` to `r15`.
3. It saves the stack pointer in the context that it leaves, and loads the stack pointer of the
   context that it resumes.
4. It pops the six registers of that context, and then the address to resume at. It resumes with
   `jmp` to that address, and not with `ret`.

So a context is one word, its stack pointer, and its stack holds the rest. The switch of the
package writes three words to a context, and `switch_called` saves the callee-saved registers
around it. Boost's function also saves MXCSR and the x87 control word. The candidate does not, as
the switch of the package does not (record 3).

A new fiber of the candidate starts at `jump_entry`, from a first stack of seven words. The entry
moves the argument from `r12` to `rdi`, pushes a return address of zero, and jumps to `main`, whose
address is in `rbx`. The probe runs the candidate on x86-64 alone, in each shape, as a third form.

The candidate needs a process with no shadow stack and no indirect branch tracking of the
processor (CET). So do each form of the switch of the package and std's switch. After a switch, a
return can go to an address that the other context pushed, and the call of `jump_switch` never
returns. A shadow stack refuses both. The header of `src/switch.zig` says what the build writes
for that. Boost's design has a path for shadow stacks, which the candidate leaves out. The session
recalled that path, and did not read it on 2026-11-13.

### The tests

`zig build test-bench` runs four tests of the candidate, on x86-64 alone. On aarch64 they skip. The
Linux gate now runs the unit tests of the bench programs too, so the tests ran on x86-64 Linux under
Rosetta. The test of the form of a row checks the rows of the candidate too. The address to resume
at of the fiber must be in the function of the fiber. The candidate keeps the address of the main
context on the stack of the test. Later calls write over it, so the test does not read it.

- **"a switch of the candidate out and back keeps each callee-saved register"**: each side puts its
  own values in `rbx`, `rbp` and `r12` to `r15`, and reads them back after the switch.
- **"the main context and the fiber of the candidate each keep an f80 value across a switch"**.
- **"the fiber of the candidate runs one time for each of many switches"**: 100,000 switches.
- **"a new fiber of the candidate starts with its argument, with no caller, on an aligned frame"**:
  the first stack of `initial_context` and the entry, as record 4 asks of the switch of the package.

### The mutations

The session ran each mutation on 2026-11-13, on x86-64 Linux in Docker under Rosetta, with
`--test-filter candidate`. That filter ran the four tests of the candidate and two other tests of
the probe, six in the last run. The test of the forms of the probe runs the candidate too, and a
crash there hides what the tests of the candidate do. Each cell gives Debug, then ReleaseSafe. C is
CAUGHT, and n is NOT CAUGHT. The code of the candidate did not change after these runs.

| mutation | x86-64 Linux, under Rosetta |
|---|---|
| none | pass, pass |
| `rbx` not restored: its word is popped into no register | C, C |
| `rbp` not restored | C, C |
| `r13` not restored | C, C |
| `r15` not restored | C, C |
| the pops of `r12` and `r13` swapped | C, C |
| the old context and the new one swapped | C, C |
| the stack pointer saved one word high | C, C |
| `ret` in place of the pop and the jump | n, n |
| the entry hands `main` the value of `r13` | C, C |
| the entry pushes no return address of zero | C, C |
| the caller calls the candidate from assembly whose list names no x87 or `xmm` register | n, C |

How to read the table:

- `ret` pops the address to resume at and jumps to it, as the pop and the jump do. So the
  candidate stays correct, and no test can see the change. That NOT CAUGHT is expected. The
  difference is in the prediction of the return, which only the probe can show.
- With a call from such assembly, a Debug build still keeps the `f80` sum in memory across the
  switch. A ReleaseSafe build keeps it in an x87 register, and the test of the `f80` value fails.
- With no return address of zero, the tests passed until the session added the test of the first
  stack. That test caught it in both modes.

### The numbers

No real x86-64 processor has run the candidate. `mac` runs it only under Rosetta, which is an
emulator, so a time from there is no result. The session ran the Linux build of the probe for
x86-64 one time, to show that the candidate runs in each shape:

```bash
zig build bench-linux && BENCH_PLATFORM=linux/amd64 bash tools/linux_bench.sh --machine orbstack-rosetta
```

The probe exited with status 0, and printed a row for each form in each shape. Each row of the
candidate counted one run of the fiber for each switch. Its times measure Rosetta and not an x86-64
processor, so this record gives none of them. CI runs the probe on a real x86-64 processor when a
person starts its job `probe`. Camilo reads those numbers, and the numbers of a quiet `mac`, before
a ruling on the candidate.
