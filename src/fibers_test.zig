//! The fixture of the tests of `Fibers` on the reactor of the host, and the tests of the std tasks
//! of a future (rotor's decision 34, "Build order", step 1). The reactor is kqueue on macOS. On
//! Linux it is io_uring where the kernel gives a ring, and epoll where it refuses one, as under
//! Docker's default seccomp profile. The Linux gate runs these tests both ways.
//!
//! Each test ends with `expect_no_stall`: the reactor counted no stall (decision 34, step 1).
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const rotor = @import("rotor");
const constants = @import("constants.zig");
const fibers_module = @import("fibers.zig");
const fiber_module = @import("fiber.zig");

pub const Reactor = rotor.Reactor(rotor.Loop);
pub const Fibers = fibers_module.Fibers(Reactor);

/// Four fibers, so a test can take each of them.
pub const fiber_count = 4;

pub const fibers_options: Fibers.Options = .{
    .count = fiber_count,
    .stack_bytes = constants.stack_bytes_min,
};

/// The operations of a test of its own, beside the package's.
pub const test_operations = 8;

pub const reactor_options: Reactor.Options = .{ .loop = .{
    .operations = Fibers.operations(&fibers_options) + test_operations,
} };

pub const millisecond_ns = rotor.constants.ns_per_ms;

var reactor_memory: [Reactor.memory_bytes(&reactor_options)]u8 align(rotor.memory_alignment) = undefined;
var fibers_memory: [Fibers.memory_bytes(&fibers_options)]u8 align(fibers_module.memory_alignment) = undefined;

/// What a fixture differs by.
pub const Setup = struct {
    event_handler: ?fibers_module.EventHandler = null,
    /// The `rest` of the value, or null for the fixture's `std.Io.Threaded`.
    rest: ?Io = null,
    /// The operations of the reactor, or null for `reactor_options`. At most that count.
    operations: ?u32 = null,
};

/// A reactor of the host, a `std.Io.Threaded` for `rest`, and a `Fibers` value over both.
pub const Fixture = struct {
    reactor: Reactor,
    threaded: Io.Threaded,
    fibers: Fibers,

    pub fn init(fixture: *Fixture, setup: Setup) !void {
        var options = reactor_options;
        if (setup.operations) |operations| {
            std.debug.assert(operations <= reactor_options.loop.operations);
            options.loop.operations = operations;
        }
        fixture.reactor.init(&reactor_memory, &options) catch |err| switch (err) {
            // An emulator can refuse the reactor, as Rosetta does for x86-64 Linux. The Linux gate
            // says so for such a platform (tools/linux_test.sh), and a real kernel never refuses.
            error.Unsupported => return error.SkipZigTest,
            else => return err,
        };
        fixture.threaded = .init_single_threaded;
        var own_options = fibers_options;
        own_options.event_handler = setup.event_handler;
        const rest = setup.rest orelse fixture.threaded.io();
        try fixture.fibers.init(&fixture.reactor, &fibers_memory, rest, &own_options);
    }

    pub fn deinit(fixture: *Fixture) void {
        fixture.fibers.deinit();
        fixture.reactor.deinit();
    }

    pub fn io(fixture: *Fixture) Io {
        return fixture.fibers.io();
    }

    /// Fails when the reactor counted a stall, a turn of 10 ms or more.
    pub fn expect_no_stall(fixture: *Fixture) !void {
        try testing.expectEqual(0, fixture.reactor.statistics().stalls);
    }
};

/// The context that runs, as the `io` of a test sees it.
pub fn current_of(io: Io) fiber_module.Index {
    const fibers: *Fibers = @ptrCast(@alignCast(io.userdata.?));
    return fibers.lists.current;
}

/// Runs `body` once on the main context, and once on a fiber that the main context awaits.
pub fn on_both(io: Io, comptime body: fn (Io) anyerror!void) !void {
    try body(io);
    try testing.expectEqual(fiber_module.index_main, current_of(io));
    var future = try io.concurrent(on_fiber, .{ io, &body });
    try future.await(io);
}

fn on_fiber(io: Io, body: *const fn (Io) anyerror!void) anyerror!void {
    try testing.expect(current_of(io) != fiber_module.index_main);
    return body(io);
}

/// The marks of a test, in the order in which its contexts made them.
pub const Log = struct {
    marks: [log_marks_max]u8 = undefined,
    len: usize = 0,

    const log_marks_max = 64;

    pub fn append(log: *Log, mark: u8) void {
        std.debug.assert(log.len < log_marks_max);
        log.marks[log.len] = mark;
        log.len += 1;
    }

    pub fn text(log: *const Log) []const u8 {
        return log.marks[0..log.len];
    }
};

const Sum = struct { sum: u32, context: fiber_module.Index };

fn add(io: Io, a: u32, b: u32) Sum {
    return .{ .sum = a + b, .context = current_of(io) };
}

test "a std task runs on a fiber, and await returns its result and frees the fiber" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(add, .{ io, 2, 3 });
    try testing.expect(future.any_future != null);
    const result = future.await(io);
    try testing.expectEqual(5, result.sum);
    try testing.expectEqual(1, result.context);
    // The fiber is free again, so the next std task takes it too.
    var again = try io.concurrent(add, .{ io, 4, 5 });
    try testing.expectEqual(1, again.await(io).context);
    try fixture.expect_no_stall();
}

fn await_inner(io: Io) Sum {
    var inner = io.async(add, .{ io, 1, 2 });
    return inner.await(io);
}

test "a fiber awaits the future of another fiber" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var outer = try io.concurrent(await_inner, .{io});
    const result = outer.await(io);
    try testing.expectEqual(3, result.sum);
    try testing.expectEqual(2, result.context);
    try fixture.expect_no_stall();
}

fn hold(io: Io, gate: *u32) void {
    io.futexWaitUncancelable(u32, gate, 0);
}

test "async runs a std task on the caller's stack when no fiber is free, and concurrent refuses it" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var gate: u32 = 0;
    var held: [fiber_count]Io.Future(void) = undefined;
    for (&held) |*future| future.* = try io.concurrent(hold, .{ io, &gate });
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(add, .{ io, 1, 1 }));
    var on_caller = io.async(add, .{ io, 1, 1 });
    try testing.expect(on_caller.any_future == null);
    try testing.expectEqual(fiber_module.index_main, on_caller.await(io).context);
    gate = 1;
    io.futexWake(u32, &gate, std.math.maxInt(u32));
    for (&held) |*future| future.await(io);
    try fixture.expect_no_stall();
}

const Large = [constants.result_bytes_max + 1]u8;

fn large(io: Io) Large {
    var bytes: Large = @splat(0);
    bytes[0] = @intCast(current_of(io));
    return bytes;
}

test "a result larger than the top of a stack holds runs on the caller's stack" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(large, .{io});
    try testing.expect(future.any_future == null);
    try testing.expectEqual(fiber_module.index_main, future.await(io)[0]);
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(large, .{io}));
    try fixture.expect_no_stall();
}

fn sleep_then_add(io: Io, delay_ns: u64) Io.Cancelable!u32 {
    try io.sleep(.fromNanoseconds(@intCast(delay_ns)), .awake);
    return 7;
}

fn await_sleeper(io: Io) (Io.Cancelable || Io.ConcurrentError)!u32 {
    var sleeper = try io.concurrent(sleep_then_add, .{ io, 2 * millisecond_ns });
    // A cancel of this fiber reaches the next cancel point, after the await.
    const value = try sleeper.await(io);
    try io.checkCancel();
    return value;
}

test "await is no cancel point, and the cancel reaches the next one" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var outer = try io.concurrent(await_sleeper, .{io});
    // Let the outer fiber block in its await.
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    try testing.expectError(error.Canceled, outer.cancel(io));
    try fixture.expect_no_stall();
}

test "deinit makes each guard page writable again" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    try fixture.expect_no_stall();
    fixture.deinit();
    // The program owns the block again, guard pages included.
    @memset(&fibers_memory, 0);
    try testing.expectEqual(0, fibers_memory[fibers_memory.len - 1]);
}

test "the table holds 109 calls, and the package runs 17 of them" {
    try testing.expectEqual(fibers_module.table_calls, @typeInfo(Io.VTable).@"struct".fields.len);
    try testing.expectEqual(fibers_module.own_calls, fibers_module.own_count(Fibers));
}

var random_calls: u32 = 0;
var random_userdata: ?*anyopaque = null;

fn counting_random(userdata: ?*anyopaque, buffer: []u8) void {
    random_userdata = userdata;
    random_calls += 1;
    @memset(buffer, 0xA5);
}

test "a call that the package does not run goes to rest, with the userdata of rest" {
    var fixture: Fixture = undefined;
    var table = Io.failing.vtable.*;
    table.random = counting_random;
    var marker: u8 = 0;
    try fixture.init(.{ .rest = .{ .userdata = &marker, .vtable = &table } });
    defer fixture.deinit();
    const io = fixture.io();
    var bytes: [4]u8 = undefined;
    random_calls = 0;
    io.random(&bytes);
    try testing.expectEqual(1, random_calls);
    try testing.expectEqual(@as(?*anyopaque, &marker), random_userdata);
    try testing.expectEqualSlices(u8, &.{ 0xA5, 0xA5, 0xA5, 0xA5 }, &bytes);
    try fixture.expect_no_stall();
}

test {
    _ = @import("fibers_test_cancel.zig");
    _ = @import("fibers_test_groups.zig");
    _ = @import("fibers_test_wait.zig");
    _ = @import("fibers_test_lookup.zig");
    _ = @import("fibers_test_reactor.zig");
    _ = @import("fibers_test_replay.zig");
}
