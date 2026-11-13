# Reports to Zig: the fiber switch and the fiber entries of std

This is a draft for Camilo to post. He posts it himself, as new issues at
<https://codeberg.org/ziglang/zig/issues>, and nobody of the session posts it. Each issue is in a
file of its own, and is written as Camilo, in the first person. Post the part under "Title" as the
title, and the part under "Body" as the body. The attachments are in
[`zig-report/`](zig-report/). This file is for Camilo alone, and is not for the tracker.

## What to post where

| file | issue | labels that fit | related items on the tracker |
|---|---|---|---|
| [`zig-report-issue-1.md`](zig-report-issue-1.md) | the clobber lists of `std.Io.fiber.contextSwitch` | `lib/std`, `bug` | #35724 (open) reports the message register and notes `nzcv`. #31284 (closed) and LLVM PR #167783 cover `x30` |
| [`zig-report-issue-2.md`](zig-report-issue-2.md) | the clobber names of the LLVM backend | `backend/llvm`, `bug` | #31284, LLVM PR #167783 |
| [`zig-report-issue-3.md`](zig-report-issue-3.md) | the entries of a new fiber in `std.Io` | `lib/std`, `bug` | none found |

Issue #35724 already reports error 1 of issue 1, and it notes error 4. There are two choices:

1. Post issue 1 as a new issue, with its link to #35724. It reports four errors that #35724 does
   not name: `lr`, `x18`, `xmm0` to `xmm31`, and the `ffr` message.
2. Post the parts of issue 1 that #35724 does not hold as a comment on #35724.

The draft recommends choice 1.

One more error of std needs no issue. std 0.16.0 gives the C calling convention `x86_64_sysv` to
the x32 ABIs `gnux32` and `muslx32`, and `x86_64_x32` to `gnuabin32` and `muslabin32`, the names
of the n32 ABI of MIPS (`std/Target.zig`). Zig 0.17.1 gives `x86_64_x32` to `gnux32`, `muslx32`
and `x32`, so it corrects the mapping. Record 5 says how `supports` of the package reads the width
of a pointer for that reason.

## How the session measured

- Machine: `mac`, an Apple M1 Pro with macOS 26.6.2. The load average was 30 to 89 during the
  runs. No number in this file is a time, so the load changes no result.
- Linux: Docker in OrbStack, kernel 7.2.12, image
  `alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc`, the image of
  tejedor's `tools/linux_test.sh`. The containers had no seccomp filter.
- x86-64: Rosetta ran each x86-64 program, in Docker and on macOS. That is emulation. No real
  x86-64 processor ran a program of this file.
- AVX-512 and APX: no processor here has them. Each result for them is from the disassembly only.
- Zig: the Homebrew builds of 0.16.0 and 0.17.1. `zig cc --version` prints clang 21.1.8 and
  clang 22.1.8. Each program ran with both versions.
- Each result in the issues comes from the runs of the session on 2026-11-13. The session copied
  no result from the records of tejedor or rotor.

## What differs from the records

- rotor's decision 22 found the fault of the `x1` and `rsi` entry. Issue #35724 reported the same
  fault on 2026-06-11, and it is open. The records do not name #35724.
- The records do not say that the `riscv64` list has the same error: it names `x11`, which is
  `a1`, the message register. A riscv64 build of std's switch does not load `a1` (disassembly
  only; no riscv64 machine ran it).
- Records 2 and 3 already say that `xmm16` to `xmm31` matter for a target with AVX-512VL and no
  512-bit registers (`-mcpu=x86_64_v4-evex512`, Zig 0.16.0 only). The difference is in what the
  draft suggests: issue 1 asks std to name `xmm0` to `xmm31`, and tejedor's own list keeps `xmm0`
  to `xmm15`.
- Records 2 and 3 say that the clobber type has no names for `k0` to `k7` and `r16` to `r31`.
  They do not say if LLVM honours such names. LLVM 21.1.8 honours them. The session added `~{k0}` to
  `~{k7}` and `~{r16}` to `~{r31}` to the IR of std's switch. The build then saved the mask and
  the integers on the stack. So new fields in the clobber type are enough for those registers.
- Record 4 says that a halt in a fiber on aarch64 ends with SIGSEGV. With std's own `Dispatch` on
  aarch64 macOS, a ReleaseSafe build printed the false frame and ended with SIGABRT, status 134.
  A Debug build ended with SIGSEGV. With the entry of `Kqueue`, both modes ended with SIGSEGV, as
  the record says.
- The first fault of record 4 is in `Kqueue.mainIdleEntry` alone. std uses `Kqueue` only on the
  BSD systems, and `std.Io.Kqueue` does not compile in Zig 0.16.0 or 0.17.1. So issue 3 shows the
  fault with a copy of its entry on Linux, and says that.

## What the session could not run

- `std.Io.Evented` on Linux is `Uring`. It does not compile in Zig 0.16.0 for a program that calls
  `io.async`. The errors are at `std/Io/Uring.zig:2732:32` and `std/Io/Uring.zig:3157:28`: an
  error set that does not match.
- In Zig 0.17.1, `std.Io.Evented` does not compile on any target here. The errors are at
  `std/Io/Dispatch.zig:2137:18`, `std/Io/Uring.zig:2405:14` and `std/Io/Uring.zig:2528:18`: the
  enum of `Io.Operation` has no member `net_accept`.
- `std.Io.Dispatch.deinit` does not compile in Zig 0.16.0 (`std/mem/Allocator.zig:445`, through
  `std/Io/Dispatch.zig:584`).
- `std.Io.Kqueue` does not compile in either version: `std/Io/Kqueue.zig:637:14`, no field named
  `fileWriteStreaming` in `Io.VTable`.

These four compile errors are a separate matter, and the draft has no issue for them.
