//! The futexes and the time (rotor's decision 34, "Which calls run where"). Each function takes the
//! `Fibers(Reactor)` value as `fibers`. `Wait(This)` holds the calls of the table for one
//! `Fibers(Reactor)` type, `This`.
//!
//! A futex wait puts the context at the end of the futex list, and a wake takes the first waiters
//! on the word, in the order of their waits. A wait with a timeout also runs one `timer`
//! operation. A wake then asks the reactor to end that timer, and the context goes on at the
//! timer's final event. So no event of the package comes after the wait that it belongs to
//! (rotor's decision 5).
//!
//! The `awake` and `boot` clocks read `now_ns` of the reactor, the time of its last tick. A timer
//! runs from that time too (the guide, "Submit and tick"). So `sleep` can end early, by at most
//! the time since the last tick (decision 34, "What it cannot keep"). Each other clock goes to
//! `rest`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const rotor = @import("rotor");
const constants = @import("constants.zig");
const run = @import("run.zig");

const cancel_point = run.cancel_point;
const end_wait = run.end_wait;
const index_none = @import("fiber.zig").index_none;

fn futex_wait(fibers: anytype, word: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const fiber = fibers.lists.running();
    try cancel_point(fiber);
    const after_ns = timeout_ns(fibers, timeout);
    if (after_ns) |ns| if (ns == 0) return;
    if (@atomicLoad(u32, word, .acquire) != expected) return;
    // In a callback, the block below halts.
    if (after_ns) |ns| {
        // A wake may come early, which std allows. So a long timeout is cut to the longest
        // timer.
        const timer = rotor.Operation.timer(0, @min(ns, rotor.constants.timeout_ns_max), 0);
        if (!try submit_timer(fibers, timer, word, expected)) return;
    }
    fibers.lists.push_futex(@intFromPtr(word));
    run.block(fibers, .futex, true);
    _ = try end_wait(fiber);
}

/// Submits the timer of a futex wait. Returns false when the word changed while the
/// context waited for a free slot: a wait that ends with no wake, which std allows.
fn submit_timer(fibers: anytype, timer: rotor.Operation, word: *const u32, expected: u32) error{Canceled}!bool {
    var tries: u32 = 1;
    while (!run.try_submit(fibers, timer)) : (tries += 1) {
        if (tries == constants.submit_tries_max) @panic(run.reactor_full);
        try run.wait_for_slot(fibers);
        if (@atomicLoad(u32, word, .acquire) != expected) return false;
    }
    return true;
}

fn futex_wait_uncancelable(fibers: anytype, word: *const u32, expected: u32) void {
    if (@atomicLoad(u32, word, .acquire) != expected) return;
    fibers.lists.push_futex(@intFromPtr(word));
    run.block(fibers, .futex, false);
}

/// Wakes the first `max_waiters` contexts that wait on `word`, in the order of their waits.
fn futex_wake(fibers: anytype, word: *const u32, max_waiters: u32) void {
    const lists = &fibers.lists;
    const address = @intFromPtr(word);
    var woken: u32 = 0;
    var index = lists.next_futex(lists.futex_head, address);
    while (index != index_none and woken < max_waiters) : (woken += 1) {
        // Each turn takes one context off the futex list, which holds each at most once.
        assert(woken <= constants.fibers_max);
        const after = lists.fibers[index].next;
        lists.unlink_futex(index);
        run.end_futex_wait(fibers, index, 0);
        index = lists.next_futex(after, address);
    }
}

fn sleep(fibers: anytype, timeout: Io.Timeout) Io.Cancelable!void {
    // A sleep halts in a callback on each run, also with no time, so a test finds it.
    if (fibers.in_callback) @panic(run.callback_blocks);
    const fiber = fibers.lists.running();
    try cancel_point(fiber);
    var remaining = timeout_ns(fibers, timeout) orelse {
        // With no time, only a cancel ends the sleep.
        run.block(fibers, .cancel, true);
        _ = try end_wait(fiber);
        return;
    };
    while (remaining > 0) {
        const step = @min(remaining, rotor.constants.timeout_ns_max);
        run.submit(fibers, rotor.Operation.timer(0, step, 0)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ReactorFull => @panic(run.reactor_full),
        };
        run.block(fibers, .operation, true);
        _ = try end_wait(fiber);
        remaining -= step;
    }
}

/// The nanoseconds from now until `timeout` passes, 0 when it passed, or null for none.
fn timeout_ns(fibers: anytype, timeout: Io.Timeout) ?u64 {
    const nanoseconds: i96 = switch (timeout) {
        .none => return null,
        .duration => |duration| duration.raw.nanoseconds,
        .deadline => |deadline| deadline.raw.nanoseconds - read_clock(fibers, deadline.clock).nanoseconds,
    };
    return @intCast(std.math.clamp(nanoseconds, 0, std.math.maxInt(u64)));
}

fn read_clock(fibers: anytype, clock: Io.Clock) Io.Timestamp {
    switch (clock) {
        .awake, .boot => {
            // `init` ticks when the reactor read no clock yet, so this one is set.
            const now_ns = fibers.reactor.now_ns();
            assert(now_ns != 0);
            return .{ .nanoseconds = now_ns };
        },
        else => return fibers.rest.vtable.now(fibers.rest.userdata, clock),
    }
}

pub fn Wait(comptime This: type) type {
    return struct {
        pub fn futex_wait_call(userdata: ?*anyopaque, word: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
            return futex_wait(run.from(This, userdata), word, expected, timeout);
        }

        pub fn futex_wait_uncancelable_call(userdata: ?*anyopaque, word: *const u32, expected: u32) void {
            futex_wait_uncancelable(run.from(This, userdata), word, expected);
        }

        pub fn futex_wake_call(userdata: ?*anyopaque, word: *const u32, max_waiters: u32) void {
            futex_wake(run.from(This, userdata), word, max_waiters);
        }

        pub fn sleep_call(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
            return sleep(run.from(This, userdata), timeout);
        }

        pub fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
            return read_clock(run.from(This, userdata), clock);
        }
    };
}
