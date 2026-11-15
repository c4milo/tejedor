//! `netLookup`, a wrapper around the call of `rest` (rotor's decision 34, "Why `netLookup` is a
//! wrapper"). `Lookup(This)` holds the call of the table for one `Fibers(Reactor)` type, `This`.
//!
//! `netLookup` takes a `Queue` of the caller, and a fiber can wait on that queue with the `io` of
//! the package. `rest` cannot wake such a fiber: `std.Io.Threaded` fills and closes the queue with
//! its own `io`, and `std.Io.failing` returns `error.NetworkDown` and does not close it. So the
//! package runs the call itself:
//!
//! 1. It makes a queue of its own on the caller's stack, with room for `lookup_results_max`
//!    results. A lookup of std does not block on a queue of 16 or more.
//! 2. It calls `netLookup` of `rest` with that queue. No context waits on it, so `rest` wakes none.
//! 3. It moves each result to the caller's queue with the `io` of the package. A move that must
//!    wait for room blocks the context, as each `Queue.put` does.
//! 4. It closes the caller's queue with the `io` of the package, also when `rest` returned an
//!    error, as std's rule asks. Then it returns what `rest` returned.
//!
//! The caller gets no result before the whole lookup of `rest` ends. With a `Threaded`, the lookup
//! holds the reactor's thread for its length, as each call of `rest` that sleeps in the kernel.
const std = @import("std");
const Io = std.Io;
const HostName = Io.net.HostName;
const constants = @import("constants.zig");
const run = @import("run.zig");

const LookupResult = HostName.LookupResult;

/// The value that each place of the queue of the package holds before `rest` writes it.
const no_result: LookupResult = .{ .canonical_name = .{ .bytes = "" } };

/// Runs the lookup of `rest` with a queue of its own, then moves each result to `resolved` with
/// `io`, the `io` of the package, and closes `resolved`.
fn look_up(
    io: Io,
    rest: Io,
    host_name: HostName,
    resolved: *Io.Queue(LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    defer resolved.close(io);
    var buffer: [constants.lookup_results_max]LookupResult = @splat(no_result);
    var own: Io.Queue(LookupResult) = .init(&buffer);
    const outcome = rest.vtable.netLookup(rest.userdata, host_name, &own, options);
    try move(io, &own, resolved);
    return outcome;
}

/// Moves each result of `own` to `resolved`, in order. `own` holds at most `lookup_results_max`
/// results, and a get with a least count of 0 never waits.
fn move(io: Io, own: *Io.Queue(LookupResult), resolved: *Io.Queue(LookupResult)) Io.Cancelable!void {
    for (0..constants.lookup_results_max) |_| {
        var one: [1]LookupResult = .{no_result};
        const got = own.getUncancelable(io, &one, 0) catch |err| switch (err) {
            error.Closed => return,
        };
        if (got == 0) return;
        resolved.putOne(io, one[0]) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // std asserts that the caller does not close the queue before the lookup returns
            // (`std/Io/net/HostName.zig`, line 157).
            error.Closed => unreachable,
        };
    }
}

pub fn Lookup(comptime This: type) type {
    return struct {
        pub fn net_lookup(
            userdata: ?*anyopaque,
            host_name: HostName,
            resolved: *Io.Queue(LookupResult),
            options: HostName.LookupOptions,
        ) HostName.LookupError!void {
            const fibers = run.from(This, userdata);
            return look_up(fibers.io(), fibers.rest, host_name, resolved, options);
        }
    };
}
