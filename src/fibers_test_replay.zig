//! The calls of std tasks over the package's own twin (rotor's decision 34, question 18, and step
//! 1). Two runs of one program give the same order of events, at the same times on the clock of
//! the twin. The program uses `async`, `concurrent`, `await`, `cancel`, the four calls of a group,
//! `sleep`, the futex calls and `now`.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const rotor = @import("rotor");
const constants = @import("constants.zig");
const fibers_module = @import("fibers.zig");
const twin_module = @import("fibers_test_twin.zig");
const fixtures = @import("fibers_test.zig");

const Reactor = rotor.Reactor(twin_module.Twin);
const Fibers = fibers_module.Fibers(Reactor);
const Log = fixtures.Log;
const millisecond_ns = fixtures.millisecond_ns;

const reactor_options: Reactor.Options = .{ .loop = .{} };
const fibers_options: Fibers.Options = .{ .count = fixtures.fiber_count, .stack_bytes = constants.stack_bytes_min };

var reactor_memory: [Reactor.memory_bytes(&reactor_options)]u8 align(rotor.memory_alignment) = undefined;
var fibers_memory: [Fibers.memory_bytes(&fibers_options)]u8 align(fibers_module.memory_alignment) = undefined;

/// What one run left: the marks of the program, and the trace of the twin.
const Run = struct {
    log: Log = .{},
    trace: [twin_module.trace_max]twin_module.Traced = undefined,
    trace_len: usize = 0,
    end_ns: u64 = 0,
};

fn nap(io: Io, log: *Log, mark: u8, delay_ms: u64) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
    log.append(mark);
}

fn sleep_long(io: Io, log: *Log) Io.Cancelable!void {
    io.sleep(.fromSeconds(10), .awake) catch |err| {
        log.append('x');
        return err;
    };
}

fn wake_after(io: Io, word: *u32, log: *Log) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(2), .awake);
    log.append('w');
    word.* = 1;
    io.futexWake(u32, word, 1);
}

fn program(io: Io, log: *Log) !void {
    const start = Io.Clock.awake.now(io);
    var first = io.async(nap, .{ io, log, 'a', 3 });
    var second = try io.concurrent(nap, .{ io, log, 'b', 1 });
    var group: Io.Group = .init;
    try group.concurrent(io, nap, .{ io, log, 'c', 2 });
    group.async(io, nap, .{ io, log, 'd', 4 });
    try group.await(io);
    try first.await(io);
    try second.await(io);
    var long = try io.concurrent(sleep_long, .{ io, log });
    try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectError(error.Canceled, long.cancel(io));
    var word: u32 = 0;
    var waker = try io.concurrent(wake_after, .{ io, &word, log });
    try io.futexWait(u32, &word, 0);
    try waker.await(io);
    var members: Io.Group = .init;
    try members.concurrent(io, sleep_long, .{ io, log });
    members.cancel(io);
    // On the twin's clock, the program took exactly the times of its sleeps.
    const elapsed = Io.Clock.awake.now(io).nanoseconds - start.nanoseconds;
    try testing.expect(elapsed >= 7 * millisecond_ns);
}

fn run_once(run: *Run) !void {
    var reactor: Reactor = undefined;
    try reactor.init(&reactor_memory, &reactor_options);
    defer reactor.deinit();
    var fibers: Fibers = undefined;
    try fibers.init(&reactor, &fibers_memory, Io.failing, &fibers_options);
    defer fibers.deinit();
    try program(fibers.io(), &run.log);
    const traced = reactor.loop.traced();
    @memcpy(run.trace[0..traced.len], traced);
    run.trace_len = traced.len;
    run.end_ns = reactor.now_ns();
}

test "the calls of std tasks run over the twin, and two runs give the same order of events" {
    var first: Run = .{};
    var second: Run = .{};
    try run_once(&first);
    try run_once(&second);
    try testing.expectEqualStrings("bcadxwx", first.log.text());
    try testing.expectEqualStrings(first.log.text(), second.log.text());
    try testing.expect(first.trace_len > 0);
    try testing.expectEqual(first.trace_len, second.trace_len);
    for (first.trace[0..first.trace_len], second.trace[0..second.trace_len]) |one, other| {
        try testing.expectEqual(one, other);
    }
    try testing.expectEqual(first.end_ns, second.end_ns);
}
