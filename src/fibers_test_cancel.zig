//! The tests of a cancel (rotor's decision 34, "How cancel works"): a cancel ends the wait in which
//! a std task blocks, the next cancel point returns `error.Canceled` once, and the protection holds
//! a cancel back. Each wait that a cancel ends has a test here. The wait of a group is in
//! `fibers_test_groups.zig`, and the wait for a free slot is in `fibers_test_reactor.zig`.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const fixtures = @import("fibers_test.zig");
const fiber_module = @import("fiber.zig");

const Fixture = fixtures.Fixture;
const millisecond_ns = fixtures.millisecond_ns;

const Outcome = struct {
    first: Io.Cancelable!void,
    second: Io.Cancelable!void,
};

/// Sleeps twice, each sleep a cancel point, and reports how each ended.
fn sleep_twice(io: Io, first_ns: u64, second_ns: u64) Outcome {
    const first = io.sleep(.fromNanoseconds(@intCast(first_ns)), .awake);
    const second = io.sleep(.fromNanoseconds(@intCast(second_ns)), .awake);
    return .{ .first = first, .second = second };
}

test "a cancel ends a sleep with Canceled, and the next cancel point does not return it again" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(sleep_twice, .{ io, 10_000 * millisecond_ns, 2 * millisecond_ns });
    // Let the std task block in its first sleep.
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const before = Io.Clock.awake.now(io);
    const outcome = future.cancel(io);
    try testing.expectError(error.Canceled, outcome.first);
    try outcome.second;
    // The first sleep ended early, and the second ran in full.
    const elapsed = Io.Clock.awake.now(io).nanoseconds - before.nanoseconds;
    try testing.expect(elapsed >= 2 * millisecond_ns);
    try testing.expect(elapsed < 1000 * millisecond_ns);
    try testing.expectEqual(0, fixture.reactor.in_flight());
    try fixture.expect_no_stall();
}

fn sleep_forever(io: Io) Io.Cancelable!void {
    const forever: Io.Timeout = .none;
    return forever.sleep(io);
}

test "a cancel ends a sleep with no time" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var future = try io.concurrent(sleep_forever, .{io});
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
    try fixture.expect_no_stall();
}

fn protected_sleep(io: Io) Outcome {
    const old = io.swapCancelProtection(.blocked);
    const first = io.sleep(.fromNanoseconds(2 * millisecond_ns), .awake);
    _ = io.swapCancelProtection(old);
    const second = io.checkCancel();
    return .{ .first = first, .second = second };
}

test "the protection holds a cancel back until the first cancel point after it" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(protected_sleep, .{io});
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const outcome = future.cancel(io);
    try outcome.first;
    try testing.expectError(error.Canceled, outcome.second);
    try fixture.expect_no_stall();
}

fn recancel_twice(io: Io) Outcome {
    const first = io.checkCancel();
    io.recancel();
    const second = io.checkCancel();
    return .{ .first = first, .second = second };
}

test "recancel makes the next cancel point return Canceled again" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    // The std task has not run when the cancel comes, so its first cancel point sees it.
    var future = io.async(recancel_twice, .{io});
    const outcome = future.cancel(io);
    try testing.expectError(error.Canceled, outcome.first);
    try testing.expectError(error.Canceled, outcome.second);
    try fixture.expect_no_stall();
}

test "checkCancel on the main context returns, because no cancel reaches it" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    try io.checkCancel();
    try testing.expectEqual(.unblocked, io.swapCancelProtection(.blocked));
    try testing.expectEqual(.blocked, io.swapCancelProtection(.unblocked));
    try fixture.expect_no_stall();
}

fn futex_canceled(io: Io, word: *u32, timed: bool) Io.Cancelable!void {
    const timeout: Io.Timeout = if (timed) .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } else .none;
    return io.futexWaitTimeout(u32, word, 0, timeout);
}

test "a cancel ends a futex wait, with a timer and without one" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    var untimed = io.async(futex_canceled, .{ io, &word, false });
    var timed = io.async(futex_canceled, .{ io, &word, true });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    try testing.expectError(error.Canceled, untimed.cancel(io));
    try testing.expectError(error.Canceled, timed.cancel(io));
    // The cancel ended the timer, and no context waits on the word.
    try testing.expectEqual(0, fixture.reactor.in_flight());
    try testing.expectEqual(fiber_module.index_none, fixture.fibers.lists.futex_head);
    try fixture.expect_no_stall();
}

fn futex_uncancelable(io: Io, word: *u32, log: *fixtures.Log) Io.Cancelable!void {
    io.futexWaitUncancelable(u32, word, 0);
    log.append('w');
    // The cancel is still there for the next cancel point.
    return io.checkCancel();
}

fn wake_later(io: Io, word: *u32, log: *fixtures.Log) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(2), .awake);
    log.append('k');
    word.* = 1;
    io.futexWake(u32, word, 1);
}

test "a cancel does not end an uncancelable futex wait, and reaches the next cancel point" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    var log: fixtures.Log = .{};
    var waiter = try io.concurrent(futex_uncancelable, .{ io, &word, &log });
    var waker = try io.concurrent(wake_later, .{ io, &word, &log });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    try testing.expectError(error.Canceled, waiter.cancel(io));
    try waker.await(io);
    try testing.expectEqualStrings("kw", log.text());
    try fixture.expect_no_stall();
}
