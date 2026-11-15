//! The tests of the tick and of its callbacks (rotor's decision 34, "The ready list and the tick",
//! "Where a call comes from", "Other libraries on the same reactor" and "When the reactor is
//! full"). Each test is one check of step 1 of the build order.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const rotor = @import("rotor");
const fixtures = @import("fibers_test.zig");
const fibers_module = @import("fibers.zig");

const Fixture = fixtures.Fixture;
const Log = fixtures.Log;
const millisecond_ns = fixtures.millisecond_ns;

/// A timer of the test's own record.
const Timer = struct {
    completion: rotor.Completion = .init(Timer, "completion", on_event),
    fired: bool = false,

    fn on_event(timer: *Timer, event: rotor.Event) void {
        std.debug.assert(event.is_final());
        timer.fired = true;
    }

    fn submit(timer: *Timer, reactor: *fixtures.Reactor, after_ns: u64) !void {
        const operation = rotor.Completion.mark(&timer.completion, rotor.Operation.timer(0, after_ns, 0));
        if (reactor.submit(&.{operation}, &.{}) != 1) return error.NotTaken;
    }
};

/// The most turns of each fiber of the test of two fibers that wake each other.
const turns_max = 100_000;

const PingPong = struct {
    /// Whose turn it is: 0 or 1.
    word: u32 = 0,
    timer: *Timer,
    turns: u32 = 0,
    done: bool = false,
};

/// Waits for its turn, and hands the turn to the other fiber, until the timer fires.
fn ping(io: Io, state: *PingPong, mine: u32) void {
    for (0..turns_max) |_| {
        while (state.word != mine) io.futexWaitUncancelable(u32, &state.word, 1 - mine);
        if (state.timer.fired) state.done = true;
        state.turns += 1;
        state.word = 1 - mine;
        io.futexWake(u32, &state.word, 1);
        if (state.done) return;
    }
}

test "two fibers that wake each other without end still let a timer of the test's record fire" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var timer: Timer = .{};
    try timer.submit(&fixture.reactor, 0);
    var state: PingPong = .{ .timer = &timer };
    var first = try io.concurrent(ping, .{ io, &state, 0 });
    var second = try io.concurrent(ping, .{ io, &state, 1 });
    first.await(io);
    second.await(io);
    // The main context ticked after each 64 switches, so the timer fired long before the end.
    try testing.expect(timer.fired);
    try testing.expect(state.turns < turns_max);
    try fixture.expect_no_stall();
}

/// A poller of the test, which wakes a fiber once.
const Waker = struct {
    poller: rotor.Poller = .init(Waker, "poller", on_poll),
    io: Io,
    word: *u32,
    woke: bool = false,

    fn on_poll(waker: *Waker) rotor.WaitLimit {
        if (!waker.woke) {
            waker.woke = true;
            waker.word.* = 1;
            waker.io.futexWake(u32, waker.word, 1);
        }
        return .none;
    }
};

fn wait_on(io: Io, word: *u32) Io.Cancelable!void {
    try io.futexWait(u32, word, 0);
}

test "a poller of the test, added after init, wakes a fiber, and that tick does not wait" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    var waker: Waker = .{ .io = io, .word = &word };
    try fixture.reactor.add_poller(&waker.poller);
    defer fixture.reactor.remove_poller(&waker.poller);
    const before = fixture.reactor.now_ns();
    var future = try io.concurrent(wait_on, .{ io, &word });
    // The fiber waits with nothing in flight, so the main context ticks with a wait of 10 s. The
    // poller of the package runs after the test's poller, sees the woken fiber, and stops the wait.
    try future.await(io);
    try testing.expect(waker.woke);
    try testing.expect(fixture.reactor.now_ns() - before < 1000 * millisecond_ns);
    try fixture.expect_no_stall();
}

/// A record of the test that starts a std task with `concurrent`.
const Starter = struct {
    completion: rotor.Completion = .init(Starter, "completion", on_event),
    io: Io,
    log: *Log,
    future: ?Io.Future(void) = null,

    fn on_event(starter: *Starter, event: rotor.Event) void {
        std.debug.assert(event.is_final());
        starter.log.append('r');
        starter.future = starter.io.concurrent(mark_fiber, .{starter.log}) catch unreachable;
        // The fiber runs after the tick, so it did not run yet.
        starter.log.append('s');
    }
};

fn mark_fiber(log: *Log) void {
    log.append('f');
}

test "a record of the test starts a std task with concurrent, and its fiber runs after that tick" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var log: Log = .{};
    var starter: Starter = .{ .io = io, .log = &log };
    const operation = rotor.Completion.mark(&starter.completion, rotor.Operation.timer(0, millisecond_ns, 0));
    try testing.expectEqual(1, fixture.reactor.submit(&.{operation}, &.{}));
    try io.sleep(.fromMilliseconds(3), .awake);
    try testing.expectEqualStrings("rsf", log.text());
    starter.future.?.await(io);
    try fixture.expect_no_stall();
}

/// A record of the test that awaits a future whose std task returned.
const Taker = struct {
    completion: rotor.Completion = .init(Taker, "completion", on_event),
    io: Io,
    future: *Io.Future(u32),
    value: u32 = 0,

    fn on_event(taker: *Taker, event: rotor.Event) void {
        std.debug.assert(event.is_final());
        taker.value = taker.future.await(taker.io);
    }
};

fn seven() u32 {
    return 7;
}

test "a record awaits a future whose std task returned, and frees its fiber" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var future = try io.concurrent(seven, .{});
    var taker: Taker = .{ .io = io, .future = &future };
    const operation = rotor.Completion.mark(&taker.completion, rotor.Operation.timer(0, millisecond_ns, 0));
    try testing.expectEqual(1, fixture.reactor.submit(&.{operation}, &.{}));
    // The sleep lets the std task run and return, then the record runs.
    try io.sleep(.fromMilliseconds(3), .awake);
    try testing.expectEqual(7, taker.value);
    try testing.expectEqual(null, future.any_future);
    try fixture.expect_no_stall();
}

/// The event handler of a test: it counts each event, and keeps the last.
const Handled = struct {
    events: u32 = 0,
    last: rotor.Event = undefined,

    fn handle(state: *anyopaque, event: rotor.Event) void {
        const handled: *Handled = @ptrCast(@alignCast(state));
        handled.events += 1;
        handled.last = event;
    }

    fn handler(handled: *Handled) fibers_module.EventHandler {
        return .{ .state = handled, .handle = handle };
    }
};

test "an event of an operation with no record reaches the event handler" {
    var handled: Handled = .{};
    var fixture: Fixture = undefined;
    try fixture.init(.{ .event_handler = handled.handler() });
    defer fixture.deinit();
    const io = fixture.io();
    try testing.expectEqual(1, fixture.reactor.submit(&.{rotor.Operation.timer(77, millisecond_ns, 0)}, &.{}));
    try io.sleep(.fromMilliseconds(3), .awake);
    try testing.expectEqual(1, handled.events);
    try testing.expectEqual(77, handled.last.user_data);
    try fixture.expect_no_stall();
}

/// The operations of the reactor of the tests of a full reactor.
const full_operations = 4;

/// Takes each slot of the reactor with a timer of the test that ends at the next tick, and no
/// record. So each of its events goes to the event handler.
fn fill(reactor: *fixtures.Reactor) !void {
    const timer = rotor.Operation.timer(0, 0, 0);
    const timers: [full_operations]rotor.Operation = @splat(timer);
    try testing.expectEqual(full_operations, reactor.submit(&timers, &.{}));
    try testing.expectEqual(0, reactor.submit(&.{timer}, &.{}));
}

fn sleep_on_full(io: Io) anyerror!void {
    const fibers: *fixtures.Fibers = @ptrCast(@alignCast(io.userdata.?));
    try fill(fibers.reactor);
    // The first try finds no slot. The next tick ends each timer of the test, and the second try
    // takes a slot.
    try io.sleep(.fromMilliseconds(1), .awake);
}

test "on a full reactor, a sleep returns when a slot is free before the last try" {
    var handled: Handled = .{};
    var fixture: Fixture = undefined;
    try fixture.init(.{ .event_handler = handled.handler(), .operations = full_operations });
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), sleep_on_full);
    try testing.expectEqual(2 * full_operations, handled.events);
    try fixture.expect_no_stall();
}

fn sleep_once(io: Io) Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(1), .awake);
}

fn cancel_sleeper(io: Io, sleeper: *Io.Future(Io.Cancelable!void)) Io.Cancelable!void {
    return sleeper.cancel(io);
}

test "a cancel ends the wait for a free slot" {
    var handled: Handled = .{};
    var fixture: Fixture = undefined;
    try fixture.init(.{ .event_handler = handled.handler(), .operations = full_operations });
    defer fixture.deinit();
    const io = fixture.io();
    try fill(&fixture.reactor);
    // The sleeper finds no slot and waits for one. Then the other fiber runs, before any tick,
    // and cancels it.
    var sleeper = try io.concurrent(sleep_once, .{io});
    var canceler = try io.concurrent(cancel_sleeper, .{ io, &sleeper });
    try testing.expectError(error.Canceled, canceler.await(io));
    // The main context's sleep waits for a slot too, and the tick ends each timer of the test.
    try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(full_operations, handled.events);
    try fixture.expect_no_stall();
}
