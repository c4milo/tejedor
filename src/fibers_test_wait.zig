//! The tests of the futexes and of the time (rotor's decision 34, "Which calls run where"):
//! `sleep`, `now`, `futexWait`, `futexWaitUncancelable` and `futexWake`. Each call that blocks
//! runs once on the main context and once on a fiber (decision 34, step 1).
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const fixtures = @import("fibers_test.zig");
const fiber_module = @import("fiber.zig");

const Fixture = fixtures.Fixture;
const Log = fixtures.Log;
const millisecond_ns = fixtures.millisecond_ns;

fn nap(io: Io, log: *Log, mark: u8, delay_ns: u64) Io.Cancelable!void {
    log.append(mark);
    try io.sleep(.fromNanoseconds(@intCast(delay_ns)), .awake);
    log.append(mark);
}

fn two_naps(io: Io) anyerror!void {
    var log: Log = .{};
    var long = try io.concurrent(nap, .{ io, &log, 'a', 4 * millisecond_ns });
    var short = try io.concurrent(nap, .{ io, &log, 'b', millisecond_ns });
    try long.await(io);
    try short.await(io);
    try testing.expectEqualStrings("abba", log.text());
}

test "a sleep hands the thread to the next context, and the shorter sleep ends first" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), two_naps);
    try fixture.expect_no_stall();
}

fn sleep_by_the_clock(io: Io) anyerror!void {
    const before = Io.Clock.awake.now(io);
    try io.sleep(.fromMilliseconds(2), .awake);
    const after = Io.Clock.awake.now(io);
    try testing.expect(after.nanoseconds - before.nanoseconds >= 2 * millisecond_ns);
    // A sleep to a deadline on the boot clock ends after that deadline.
    const deadline = Io.Clock.boot.now(io).nanoseconds + 2 * millisecond_ns;
    try Io.Timeout.sleep(.{ .deadline = .{ .raw = .{ .nanoseconds = deadline }, .clock = .boot } }, io);
    try testing.expect(Io.Clock.boot.now(io).nanoseconds >= deadline);
}

test "a sleep waits on a timer of the reactor, by the awake and the boot clocks" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), sleep_by_the_clock);
    try fixture.expect_no_stall();
}

test "the awake and boot clocks are now_ns of the reactor, and the real clock goes to rest" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    // `init` ticked once, so the reactor read its clock.
    try testing.expect(fixture.reactor.now_ns() != 0);
    try testing.expectEqual(@as(i96, fixture.reactor.now_ns()), Io.Clock.awake.now(io).nanoseconds);
    try testing.expectEqual(@as(i96, fixture.reactor.now_ns()), Io.Clock.boot.now(io).nanoseconds);
    // The real clock of `rest` reads the time since 1970, far above the reactor's clock.
    try testing.expect(Io.Clock.real.now(io).nanoseconds > fixture.reactor.now_ns());
    try fixture.expect_no_stall();
}

fn wait_for(io: Io, word: *u32, log: *Log, mark: u8) Io.Cancelable!void {
    try io.futexWait(u32, word, 0);
    log.append(mark);
}

fn wake_in_order(io: Io) anyerror!void {
    var word: u32 = 0;
    var log: Log = .{};
    var first = try io.concurrent(wait_for, .{ io, &word, &log, 'a' });
    var second = try io.concurrent(wait_for, .{ io, &word, &log, 'b' });
    var third = try io.concurrent(wait_for, .{ io, &word, &log, 'c' });
    // Let the three block, then wake two of them.
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    io.futexWake(u32, &word, 2);
    try first.await(io);
    try second.await(io);
    try testing.expectEqualStrings("ab", log.text());
    io.futexWake(u32, &word, 1);
    try third.await(io);
    try testing.expectEqualStrings("abc", log.text());
}

test "a futex wake takes the waiters in the order of their waits, and no more than it asks" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    // On a fiber, the three waiters take each other fiber.
    try fixtures.on_both(fixture.io(), wake_in_order);
    try fixture.expect_no_stall();
}

fn wake_later(io: Io, word: *u32, delay_ns: u64) Io.Cancelable!void {
    try io.sleep(.fromNanoseconds(@intCast(delay_ns)), .awake);
    word.* = 1;
    io.futexWake(u32, word, 1);
}

fn wait_woken(io: Io) anyerror!void {
    var word: u32 = 0;
    var waker = try io.concurrent(wake_later, .{ io, &word, millisecond_ns });
    try io.futexWait(u32, &word, 0);
    try testing.expectEqual(1, word);
    try waker.await(io);
    // A word that differs from the expected value returns at once.
    try io.futexWait(u32, &word, 0);
}

test "a futex wait ends at a wake from another context" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), wait_woken);
    try fixture.expect_no_stall();
}

fn wait_uncancelable(io: Io) anyerror!void {
    var word: u32 = 0;
    var waker = try io.concurrent(wake_later, .{ io, &word, millisecond_ns });
    io.futexWaitUncancelable(u32, &word, 0);
    try testing.expectEqual(1, word);
    try waker.await(io);
}

test "an uncancelable futex wait ends at a wake from another context" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), wait_uncancelable);
    try fixture.expect_no_stall();
}

fn wait_timed(io: Io) anyerror!void {
    var word: u32 = 0;
    const before = Io.Clock.awake.now(io);
    try io.futexWaitTimeout(u32, &word, 0, .{ .duration = .{ .raw = .fromMilliseconds(2), .clock = .awake } });
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds >= 2 * millisecond_ns);
    // A wake ends a wait whose timer is long, and the timer ends with it.
    var waker = try io.concurrent(wake_later, .{ io, &word, millisecond_ns });
    const start = Io.Clock.awake.now(io);
    try io.futexWaitTimeout(u32, &word, 0, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - start.nanoseconds < 1000 * millisecond_ns);
    try waker.await(io);
}

test "a futex wait with a timeout ends with no wake, and a wake ends it before its timer" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), wait_timed);
    try testing.expectEqual(0, fixture.reactor.in_flight());
    try testing.expectEqual(fiber_module.index_none, fixture.fibers.lists.futex_head);
    try fixture.expect_no_stall();
}
