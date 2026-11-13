# Report to Zig, issue 3

### Title

`std.Io` evented backends: a new fiber starts with a false return address, and `Kqueue.mainIdleEntry` reads its argument below the stack pointer

### Body

**Zig version:** 0.16.0 and 0.17.1. Each entry below has the same text in both versions.

**Targets:** `aarch64-macos`, `aarch64-linux-musl`, `x86_64-macos` and `x86_64-linux-musl`.

std starts a new fiber with a naked entry function. These are the entries, with their lines in
0.16.0:

| entry | aarch64 | x86_64 |
|---|---|---|
| `Kqueue.mainIdleEntry`, Kqueue.zig:541 | `ldr x0, [sp, #-8]`: the argument is 8 bytes below the stack pointer. `lr` is not cleared | `movq (%rsp), %rdi`: the argument is in the word that `mainIdle` takes as its return address |
| `Kqueue.fiberEntry`, Kqueue.zig:559 | `mov x0, sp`. `lr` is not cleared | `leaq 8(%rsp), %rdi`. The return address is the word below the closure. The code that makes the fiber does not set it |
| `Uring.mainIdleEntry`, Uring.zig:1110 | the argument is in `fp`. `lr` is not cleared | the argument is in `rbp`. `rsp` is the end of the allocation, so the return address is the word after it |
| `Uring` `AsyncClosure.entry`, Uring.zig:1392, and its `Group` twin, Uring.zig:1757 | `mov x0, sp`. `lr` is not cleared | `leaq 8(%rsp), %rdi`. The return address is the word below the closure |
| `Dispatch.mainLoopEntry`, Dispatch.zig:600 | the argument is in `fp`. `lr` is not cleared | the argument is in `rbp`. The return address is the last word of the stack. `init` does not set it |
| `Dispatch` `AsyncClosure.entry`, Dispatch.zig:1003, and its `Group` twin, Dispatch.zig:1347 | `mov x0, sp`. `lr` is not cleared | `leaq 8(%rsp), %rdi`. The return address is the word below the closure |

Each row comes from the code. Reproduction 1 runs the row of the `Dispatch` `AsyncClosure.entry`.
`Uring` and `Kqueue` do not compile for my programs (see "Limits").

**What happens.**

1. **On aarch64 no entry clears `lr`.** The first function of the fiber gets the `lr` of the
   context that switched to it. It takes that value as its return address. A stack trace from the
   fiber then prints a false frame. A panic in the fiber can then end with SIGSEGV, not SIGABRT.
2. **On x86_64 the return address of the first function is a word that std does not set.** For
   `Kqueue.mainIdleEntry` that word is the argument. A stack trace prints a false frame and
   `Unwind error`.
3. **On aarch64 Linux, `Kqueue.mainIdleEntry` reads its argument below the stack pointer.** The
   kernel writes a signal frame below the stack pointer. A signal that arrives before the entry
   reads the argument changes it. std uses `Kqueue` only on the BSD systems, and I did not test a
   BSD system. `std.Io.Kqueue` does not compile in 0.16.0 or 0.17.1. So I show this fault with a
   copy of the entry on Linux.

**What should happen.** A stack trace from a fiber ends at the first function of the fiber. A
panic in a fiber ends the process as a panic on the main thread does: with SIGABRT, status 134. A
fiber gets the argument that its creator wrote.

**Reproduction 1: a panic in a task of `std.Io.Evented`.** On macOS, `std.Io.Evented` is
`std.Io.Dispatch`.

```zig
const std = @import("std");

pub fn main() !void {
    var evented: std.Io.Evented = undefined;
    try evented.init(std.heap.page_allocator, .{});
    // No `deinit`: the task halts first. `Dispatch.deinit` of Zig 0.16.0 does not compile.
    const io = evented.io();
    var future = io.async(halt_here, .{});
    future.await(io);
}

noinline fn halt_here() void {
    @panic("a panic in a task");
}
```

```sh
zig build-exe halt_in_task.zig -O ReleaseSafe
./halt_in_task; echo "exit status $?"
zig build-exe halt_in_task.zig -target x86_64-macos -mcpu=baseline -O ReleaseSafe
./halt_in_task; echo "exit status $?"
```

Results with Zig 0.16.0, three runs of each build. Each run of a build printed the same frames
and ended the same way. The x86_64 build ran under Rosetta:

| target | mode | frames after `call` (Dispatch.zig:1028) | how the process ended |
|---|---|---|---|
| aarch64-macos | Debug | `resume` (Dispatch.zig:280): a function that did not call `call` | SIGSEGV, status 139 |
| aarch64-macos | ReleaseSafe | one frame `???`, at an address that changed from run to run, for example `0x105c0bfff` | SIGABRT, status 134 |
| x86_64-macos | Debug and ReleaseSafe | `???:?:?: 0xaaaaaaaaaaaaaaa9 in ??? (???)`, then `Unwind error at address ???:0xaaaaaaaaaaaaaaa9` | SIGABRT, status 134 |

The frames `halt_here`, `start` (Io.zig:2337) and `call` came first in each run. On x86_64 the
return address of `call` is the word below the closure. That word held `0xaaaaaaaaaaaaaaaa`, and
the trace prints the address minus 1.

Zig 0.17.1 does not compile this program: `std/Io/Dispatch.zig:2137:18: error: enum ... has no
member named 'net_accept'`.

**Reproduction 2: the entry of `Kqueue`, with std's switch.** The attached `halt_in_fiber.zig`
copies the text of `Kqueue.mainIdleEntry` and the first context of `Kqueue.init`
(Kqueue.zig:193-207). It switches with `std.Io.fiber.contextSwitch`, and panics in the fiber.
A naked function puts the message in the register that std's switch reads, so the first error
of issue 1 does not change the result. The argument `fixed` starts the fiber with the suggested
entry in place of std's.

```sh
zig build-exe halt_in_fiber.zig -O ReleaseSafe
./halt_in_fiber std; echo "exit status $?"
./halt_in_fiber fixed; echo "exit status $?"
```

Results, the same with Zig 0.16.0 and 0.17.1, in Debug and in ReleaseSafe:

| target | entry | frames | how the process ended |
|---|---|---|---|
| aarch64-macos | std's | `halt_here`, `fiber_main`, then `switch_to`, a function of the main context | SIGSEGV, status 139 |
| aarch64-linux-musl, Docker | std's | the same | SIGSEGV, status 139 |
| x86_64-linux-musl, Docker under Rosetta | std's | `halt_here`, `fiber_main`, then `0x5a5a000012345677`, which is the argument minus 1, then `Unwind error` | SIGABRT, status 134 |
| each of the three | suggested | `halt_here`, `fiber_main` | SIGABRT, status 134 |

**Reproduction 3: a signal at the first stack pointer of a `Kqueue` idle fiber.** The attached
`entry_signal.zig` makes the first context of `Kqueue.init` on aarch64. A step runs at the first
stack pointer. It sends SIGUSR1 to its own thread with a system call, and then it jumps to the
entry. So the handler runs at that stack pointer each time. It switches as reproduction 2 does.
These are the instructions of std's entry that it copies:

```zig
fn main_idle_entry() callconv(.naked) void {
    asm volatile (
        \\ ldr x0, [sp, #-8]
        \\ b %[mainIdle]
        :
        : [mainIdle] "X" (&main_idle),
    );
}
```

```sh
zig build-exe entry_signal.zig -target aarch64-linux-musl -O ReleaseSafe
./entry_signal; echo "exit status $?"
./entry_signal fixed; echo "exit status $?"
```

Results, the same with Zig 0.16.0 and 0.17.1, in Debug and in ReleaseSafe, two runs each:

| target | entry | the argument that the fiber got |
|---|---|---|
| aarch64-linux-musl, Docker | std's | an address in the code of the program, for example `0x1022c64` in `main`. The argument was `0x5a5a000012345678` |
| aarch64-linux-musl, Docker | suggested | `0x5a5a000012345678` |
| aarch64-macos | std's and suggested | `0x5a5a000012345678` |

The handler ran one time in each run.

**Suggested change.** I use this entry in my own fiber code. The results above show it as the
"suggested" entry. `stack_end` is the address one byte after the stack of the fiber:

| | aarch64 | x86_64 |
|---|---|---|
| the word of the argument | `stack_end - 8` | `stack_end - 8` |
| the first stack pointer | `stack_end - 16` | `stack_end - 24`, and the word there is 0 |
| the entry | `ldr x0, [sp, #8]`, `mov lr, xzr`, `b main` | `movq 16(%rsp), %rdi`, `jmp main` |

So the argument is above the first stack pointer, and the first function of the fiber sees a
return address of zero. For the entries that take the argument in `fp`, or that take the closure
at `sp`, the same idea applies:

- On aarch64, add `mov lr, xzr` to each entry.
- On x86_64, write 0 into the word at the first stack pointer of each fiber. For
  `Uring.mainIdleEntry` that stack pointer is the end of the allocation, so first move it 8 bytes
  below the end, as `Dispatch` does.
- For `Kqueue.mainIdleEntry`, move the argument above the first stack pointer, or pass it in
  `fp` as `Uring` and `Dispatch` do.

I did not test a change of std's own files.

**Limits.**

- `std.Io.Evented` on Linux is `Uring`. It does not compile in 0.16.0 for reproduction 1:
  `std/Io/Uring.zig:2732:32` and `std/Io/Uring.zig:3157:28`, an error set that does not match. In
  0.17.1 `Uring` and `Dispatch` do not compile, with the `net_accept` errors.
- `std.Io.Kqueue` does not compile in 0.16.0 or 0.17.1: `std/Io/Kqueue.zig:637:14: error: no
  field named 'fileWriteStreaming' in struct 'Io.VTable'`.
- Each x86_64 result ran under Rosetta, and not on a real x86_64 processor.

**Attachments:** `halt_in_task.zig`, `halt_in_fiber.zig`, `entry_signal.zig`.
