# tejedor

tejedor is a Zig package that gives a `std.Io` on fibers over a reactor of
[rotor](https://github.com/c4milo/rotor). With it, Zig's Future API works on the one thread that
owns the reactor: `io.async`, `future.await`, `future.cancel` and the `Io.Group` calls.

By the design, the program makes a `rotor.Reactor(rotor.Loop)` and hands it to the package. The
package runs the fibers and calls `tick`. It names no allocator: the program hands it one block of
memory for the fibers and their stacks.

## Status

Nothing is released, and the package has no public API yet. The design is accepted. The build
order has seven steps, 0 to 6. Step 0 is built: the context switch of a fiber, its tests, and a
probe that measures the switch. Its first numbers are in [bench/results](bench/results). They are
from a busy machine, so they are not final. Step 1 waits for a review of them. Camilo ruled on the
known errors of the switch on 2026-11-13, and [CLAUDE.md](CLAUDE.md) says where each ruling is,
under "Where the work stands".

## What it needs

| | |
|---|---|
| Zig | 0.16.0, and no other version |
| rotor | v0.11.0, which the build fetches |
| System and processor | macOS on aarch64, Linux on aarch64, or Linux on x86-64 |

Those are the three platforms that step 0 of the build order checks. No check covers macOS on
x86-64. `supported` of the context switch is false on Windows, on UEFI on x86-64, and where a
pointer is 32 bits. The switch follows other calling conventions. The
[fifth decision record](docs/decisions/0005-a-plain-call-of-the-switch-and-a-probe-of-a-jump.md)
gives the rule.

## Design

The [first decision record](docs/decisions/0001-the-package-starts-from-rotors-decision-34.md)
holds the rulings that bind the package, the build order, and what the first release holds. It
links the full design, which is decision 34 of rotor.

## License

Apache License 2.0. See [LICENSE](LICENSE).
