//! std_io_timers: the timer workload of rotor's bench on `std.Io`, with the package as one more
//! candidate (rotor's decision 34, "The timer program", and record 7). It is rotor's
//! `bench/alternatives/std_io_timers.zig` at v0.11.0, with one more branch in `main`: the package
//! makes the reactor and a `Fibers` value, and calls `churn` on the main context. `churn` does not
//! change. rotor's package holds no `bench/`, so the package holds this copy.
//!
//! Run:  std_io_timers [--timers N] [--period-us U] [--seconds S] [--backend tejedor|threaded]
//!
//! It keeps `timers` timers armed for `period_us`, arms each again as it fires, and reports the
//! fires of a second and how far past its deadline each fire was. The percentiles are lateness, and
//! not latency. `std.Io` has no timer, so N timers are N std tasks, each with a sleep in a loop.
//!
//! - `threaded`: `std.Io.Threaded`, with one thread for each timer.
//! - `tejedor`: the package, with one fiber for each timer, of the default stack of 256 KiB, over
//!   `rotor.Reactor(rotor.Loop)`. `churn` runs on the main context, which is no fiber, so the run
//!   takes one fiber for each timer and none for itself.
//!
//! One fact bends the row of the package. A timer of the reactor runs from the stamp of the last
//! tick, so a sleep can end early. The program reads such a wake as a lateness of 0 (`lateness_of`).
//! The row then favours the package against `std.Io.Threaded` (decision 34, "The timer program").
//!
//! It prints the one result line of rotor's harness (`bench/timers_harness.zig`).
const std = @import("std");
const rotor = @import("rotor");
const tejedor = @import("tejedor");
const harness = @import("timers_harness.zig");

const Io = std.Io;
const now_ns = harness.now_ns;

/// The pinned Zig, which is the version of the candidate `std.Io.Threaded`.
const zig_version = "0.16.0";

/// The version of the package's candidate: no release exists.
const tejedor_version = "0.0.0";

/// Timers armed at once, at most. The limit of rotor_timers. The package's candidate takes at most
/// `tejedor.constants.fibers_max`.
const timers_max = 16384;

/// Lateness samples kept: the first fires of a run, as each candidate of this workload keeps.
const samples_max = 1 << 17;

const ns_per_us: u64 = 1000;
const ns_per_s: u64 = 1_000_000_000;

/// Memory `std.Io.Threaded` takes for the tasks it holds, as in rotor's program.
const backing_bytes = 4 * 1024 * 1024;

var backing: [backing_bytes]u8 = undefined;

var lateness_ns: [samples_max]u64 = undefined;

/// Fires, and the slot that each fire takes. It is atomic for `threaded`, whose fires happen on
/// threads of their own.
var fired: std.atomic.Value(u64) align(@alignOf(std.atomic.Value(u64))) = .init(0);

const Backend = enum { tejedor, threaded };

const Options = struct {
    timers: u32 = 1024,
    period_us: u64 = 1000,
    seconds: u64 = 3,
    backend: Backend = .threaded,
};

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    switch (options.backend) {
        .threaded => {
            var arena = std.heap.FixedBufferAllocator.init(&backing);
            var threaded: std.Io.Threaded = .init(arena.threadSafeAllocator(), .{});
            defer threaded.deinit();
            try churn(init, threaded.io(), options);
        },
        .tejedor => try churn_on_fibers(init, options),
    }
}

const Reactor = rotor.Reactor(rotor.Loop);
const Fibers = tejedor.Fibers(Reactor);

/// The branch of the package: a reactor of the host with an operation for each context, and a
/// `Fibers` value with a fiber for each timer. `rest` is `std.Io.failing`, because `churn` makes no
/// call that goes to `rest`.
fn churn_on_fibers(init: std.process.Init, options: Options) !void {
    const pages = std.heap.page_allocator;
    const fibers_options: Fibers.Options = .{ .count = @intCast(options.timers) };
    const reactor_options: Reactor.Options = .{ .loop = .{ .operations = Fibers.operations(&fibers_options) } };
    const reactor_memory = try pages.alignedAlloc(u8, .fromByteUnits(rotor.memory_alignment), Reactor.memory_bytes(&reactor_options));
    defer pages.free(reactor_memory);
    const fibers_memory = try pages.alignedAlloc(u8, .fromByteUnits(tejedor.memory_alignment), Fibers.memory_bytes(&fibers_options));
    defer pages.free(fibers_memory);
    var reactor: Reactor = undefined;
    try reactor.init(reactor_memory, &reactor_options);
    defer reactor.deinit();
    var fibers: Fibers = undefined;
    try fibers.init(&reactor, fibers_memory, Io.failing, &fibers_options);
    defer fibers.deinit();
    try churn(init, fibers.io(), options);
}

/// Starts one std task for each timer, waits for each of them to reach the deadline, and reports.
fn churn(init: std.process.Init, io: Io, options: Options) !void {
    const period_ns = options.period_us * ns_per_us;
    const started_ns = now_ns();
    const deadline_ns = started_ns + options.seconds * ns_per_s;

    var group: Io.Group = .init;
    defer group.cancel(io);
    var started: u32 = 0;
    while (started < options.timers) : (started += 1) {
        group.concurrent(io, one_timer, .{ io, period_ns, deadline_ns }) catch {
            return error.ConcurrencyRefused;
        };
    }
    try group.await(io);

    const span_ns = now_ns() - started_ns;
    try report(init, options, span_ns);
}

/// One timer: sleep a period, record how late the wake was, and sleep again until the deadline.
fn one_timer(io: Io, period_ns: u64, deadline_ns: u64) Io.Cancelable!void {
    while (true) {
        const due_ns = now_ns() + period_ns;
        try io.sleep(.fromNanoseconds(period_ns), .awake);
        const at_ns = now_ns();
        record(due_ns, at_ns);
        if (at_ns >= deadline_ns) return;
    }
}

/// Counts one fire and keeps its lateness, while slots are left.
fn record(due_ns: u64, at_ns: u64) void {
    const slot = fired.fetchAdd(1, .monotonic);
    if (slot >= samples_max) return;
    lateness_ns[slot] = lateness_of(due_ns, at_ns);
}

/// How late a fire was. A wake before the deadline reads as zero, as each candidate reads it.
fn lateness_of(due_ns: u64, at_ns: u64) u64 {
    return if (at_ns > due_ns) at_ns - due_ns else 0;
}

fn candidate_name(backend: Backend) []const u8 {
    return switch (backend) {
        .threaded => "std.Io.Threaded",
        .tejedor => "tejedor",
    };
}

fn candidate_version(backend: Backend) []const u8 {
    return switch (backend) {
        .threaded => zig_version,
        .tejedor => tejedor_version,
    };
}

/// The bytes of one result line, with room to spare.
const output_buffer_bytes = 1024;

fn report(init: std.process.Init, options: Options, span_ns: u64) !void {
    const count = fired.load(.monotonic);
    const samples = lateness_ns[0..@intCast(@min(count, samples_max))];
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const result: harness.Result = .{
        .candidate = candidate_name(options.backend),
        .version = candidate_version(options.backend),
        .timers = options.timers,
        .duration_ns = @max(span_ns, 1),
        .operations = count,
        .p50_ns = harness.nearest_rank(samples, harness.p50),
        .p99_ns = harness.nearest_rank(samples, harness.p99),
        .p999_ns = harness.nearest_rank(samples, harness.p999),
        .p9999_ns = harness.nearest_rank(samples, harness.p9999),
    };
    var buffer: [output_buffer_bytes]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try result.render_json_line(&out.interface);
    try out.interface.flush();
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    try check(options);
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--timers")) {
        options.timers = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--period-us")) {
        options.period_us = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--backend")) {
        options.backend = std.meta.stringToEnum(Backend, value) orelse return error.UnknownArgument;
    } else {
        return error.UnknownArgument;
    }
}

/// What a run refuses: nothing to measure, too many timers, and more timers than the package has
/// fibers for its candidate.
fn check(options: Options) !void {
    if (options.timers == 0) return error.EmptyConfiguration;
    if (options.period_us == 0) return error.EmptyConfiguration;
    if (options.seconds == 0) return error.EmptyConfiguration;
    if (options.timers > timers_max) return error.TooManyTimers;
    if (options.backend == .tejedor and options.timers > tejedor.constants.fibers_max) return error.TooManyTimers;
}

const testing = std.testing;

test "a run with nothing to measure is refused, and so is one over the timer limit" {
    try check(.{ .timers = 1, .period_us = 1000, .seconds = 3 });
    try check(.{ .timers = timers_max, .period_us = 1, .seconds = 1 });
    try check(.{ .timers = tejedor.constants.fibers_max, .backend = .tejedor });
    try testing.expectError(error.EmptyConfiguration, check(.{ .timers = 0 }));
    try testing.expectError(error.EmptyConfiguration, check(.{ .period_us = 0 }));
    try testing.expectError(error.EmptyConfiguration, check(.{ .seconds = 0 }));
    try testing.expectError(error.TooManyTimers, check(.{ .timers = timers_max + 1 }));
    try testing.expectError(error.TooManyTimers, check(.{ .timers = tejedor.constants.fibers_max + 1, .backend = .tejedor }));
}

test "a fire before its deadline reads as zero and not as a negative" {
    try testing.expectEqual(@as(u64, 0), lateness_of(1000, 1000));
    try testing.expectEqual(@as(u64, 0), lateness_of(1000, 900));
    try testing.expectEqual(@as(u64, 500), lateness_of(1000, 1500));
}
