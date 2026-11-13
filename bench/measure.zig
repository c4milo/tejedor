//! The method that times a probe. It is the method of rotor's cost probes
//! (`bench/costs/measure.zig` at rotor's `b2bcf60`), with only the parts that a probe of this
//! package needs.
//!
//! A probe times its operations in batches. `Plan.warmup` batches run first, and the probe throws
//! their times away. Then it reads the clock before and after each of `Plan.samples` batches of
//! `Plan.batch` operations. A sample is the elapsed time divided by the batch. A row is the
//! median of the samples, with the p99 and the least sample beside it.
//!
//! The p99 is the p99 of batch means. One clock read costs as much as several of the operations
//! that a probe times here. On Apple silicon the clock also steps in units of 41 ns, which each
//! report of the probe on `mac` prints. So a probe cannot time one operation alone, and the mean
//! of a batch hides a slow single operation.
//!
//! `sample_pairs` times two loops back to back inside each sample. A drift of the clock rate or
//! of the load of the machine then moves both loops. The probe keeps the difference of each
//! sample.
//!
//! Nothing here allocates. The caller hands over the buffers of the samples.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;

/// The monotonic clock that each probe is timed with. It is the clock that `std.Io` reads for its
/// `.awake` clock: CLOCK_UPTIME_RAW on macOS, because CLOCK_MONOTONIC steps in whole microseconds
/// there, and CLOCK_MONOTONIC on each other system.
pub const clock_id: posix.clockid_t = switch (builtin.os.tag) {
    .macos => .UPTIME_RAW,
    else => .MONOTONIC,
};

/// The name of `clock_id`, for the report.
pub const clock_name = switch (builtin.os.tag) {
    .macos => "clock_gettime(CLOCK_UPTIME_RAW)",
    else => "clock_gettime(CLOCK_MONOTONIC)",
};

/// The clock reads that `clock_resolution_ns` makes while it looks for the least step.
const resolution_reads = 200_000;

/// The time that `settle` spins before the first probe, in nanoseconds. On macOS the scheduler
/// needs time to move a user-interactive thread to a performance core, and the core needs time to
/// reach its full clock rate. The length is rotor's, and rotor says that it is a guess that worked.
const settle_ns = 300 * std.time.ns_per_ms;

/// The most clock reads that `spin_until` makes. At 5 ns for one read, that is more than 20
/// seconds, and each caller waits for far less. The 5 ns is rotor's number for the fastest clock
/// that it saw, and this package did not measure it.
const spin_reads_max = 1 << 32;

/// A median under this many nanoseconds for one operation is no measurement. It is less than one
/// cycle of a 6 GHz core, so the optimizer deleted the work or folded the loop. A report makes it
/// a failure, and never a number.
pub const sanity_floor_ns = 0.15;

/// The 99 of "p99", as a part of 100.
const percentile_rank = 99;
const percentile_scale = 100;

/// Nanoseconds on `clock_id`.
pub fn now_ns() u64 {
    var time: posix.timespec = undefined;
    const returned = posix.system.clock_gettime(clock_id, &time);
    assert(posix.errno(returned) == .SUCCESS);
    assert(time.sec >= 0);
    const seconds: u64 = @intCast(time.sec);
    const nanoseconds: u64 = @intCast(time.nsec);
    return seconds * std.time.ns_per_s + nanoseconds;
}

/// The least step that the clock made in `resolution_reads` reads, in nanoseconds. The step
/// bounds each timed interval from below.
pub fn clock_resolution_ns() u64 {
    var least: u64 = std.math.maxInt(u64);
    var previous = now_ns();
    for (0..resolution_reads) |_| {
        const current = now_ns();
        assert(current >= previous);
        const step = current - previous;
        if (step != 0 and step < least) least = step;
        previous = current;
    }
    assert(least != std.math.maxInt(u64));
    return least;
}

/// Spins on the clock until `deadline_ns`. A sleep lets the core go idle, and a probe must not
/// start from an idle core.
pub fn spin_until(deadline_ns: u64) void {
    var reads: u64 = 0;
    while (now_ns() < deadline_ns) : (reads += 1) {
        assert(reads < spin_reads_max);
    }
}

/// What the probe did about the place of its thread. Each report prints it.
pub const Placement = enum {
    /// macOS took the quality-of-service class. It is a priority, and it names no core.
    qos_user_interactive,
    qos_refused,
    /// The probe asked for nothing.
    scheduler_default,

    pub fn text(placement: Placement) []const u8 {
        return switch (placement) {
            .qos_user_interactive => "not pinned (macOS on Apple silicon has no hard affinity);" ++
                " QoS class user-interactive requested",
            .qos_refused => "not pinned; the QoS class user-interactive was refused",
            .scheduler_default => "not pinned; the probe pins no thread on this system",
        };
    }
};

/// Asks the host for the best place that it offers without the name of a core.
pub fn place_current_thread() Placement {
    switch (builtin.os.tag) {
        .macos => {
            const returned = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
            return if (returned == 0) .qos_user_interactive else .qos_refused;
        },
        else => return .scheduler_default,
    }
}

/// Places the thread and spins for `settle_ns`. So the first probe does not start on a core that
/// is still slow, or on the wrong kind of core.
pub fn settle() Placement {
    const placement = place_current_thread();
    spin_until(now_ns() + settle_ns);
    return placement;
}

pub const Plan = struct {
    /// Timed batches that run first, and whose times are thrown away.
    warmup: u32,
    /// Timed batches whose times are kept.
    samples: u32,
    /// Operations in one timed batch.
    batch: u32,

    fn check(plan: Plan) void {
        assert(plan.samples >= 1);
        assert(plan.batch >= 1);
    }

    /// The operations that each loop of a plan runs, with the warm-up.
    pub fn operations(plan: Plan) u64 {
        plan.check();
        return (@as(u64, plan.warmup) + plan.samples) * plan.batch;
    }
};

/// Nanoseconds for one operation, over the samples of one loop.
pub const Summary = struct {
    median_ns: f64,
    p99_ns: f64,
    least_ns: f64,
};

/// Sorts `values` in place and summarizes them. The median of an even count is the mean of the
/// two middle values. The p99 is the nearest rank: the least value that has 99 percent of the
/// values at or under it.
pub fn summarize(values: []f64) Summary {
    assert(values.len >= 1);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    const median = if (values.len % 2 == 1)
        values[middle]
    else
        (values[middle - 1] + values[middle]) / 2;
    const rank = (values.len * percentile_rank + percentile_scale - 1) / percentile_scale;
    assert(rank >= 1);
    assert(rank <= values.len);
    return .{ .median_ns = median, .p99_ns = values[rank - 1], .least_ns = values[0] };
}

fn ns_per_operation(elapsed_ns: u64, batch: u32) f64 {
    assert(batch >= 1);
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(batch));
}

/// Two loops timed back to back, and the second less the first.
pub const PairSummary = struct {
    first: Summary,
    second: Summary,
    /// For each sample, the nanoseconds for one operation of the second loop, less those of the
    /// first. One sample can be negative. The median of a real difference is not.
    difference: Summary,
};

/// Times `run_first` and then `run_second` inside each sample, with `plan.batch` operations each.
/// `Context` declares both as `fn (*Context, batch: u32) void`. Each buffer of `values` holds at
/// least `plan.samples` values.
pub fn sample_pairs(
    comptime Context: type,
    context: *Context,
    plan: Plan,
    values: *const [3][]f64,
) PairSummary {
    plan.check();
    for (values) |buffer| assert(buffer.len >= plan.samples);
    for (0..plan.warmup + plan.samples) |index| {
        const start_ns = now_ns();
        context.run_first(plan.batch);
        const middle_ns = now_ns();
        context.run_second(plan.batch);
        const end_ns = now_ns();
        if (index < plan.warmup) continue;
        const kept = index - plan.warmup;
        values[0][kept] = ns_per_operation(middle_ns - start_ns, plan.batch);
        values[1][kept] = ns_per_operation(end_ns - middle_ns, plan.batch);
        values[2][kept] = values[1][kept] - values[0][kept];
    }
    return .{
        .first = summarize(values[0][0..plan.samples]),
        .second = summarize(values[1][0..plan.samples]),
        .difference = summarize(values[2][0..plan.samples]),
    };
}

const testing = std.testing;

test "summarize takes the median of an odd and of an even count, and the least value" {
    var odd = [_]f64{ 9, 1, 5 };
    try testing.expectEqual(@as(f64, 5), summarize(&odd).median_ns);
    var even = [_]f64{ 8, 2, 4, 6 };
    try testing.expectEqual(@as(f64, 5), summarize(&even).median_ns);
    try testing.expectEqual(@as(f64, 2), summarize(&even).least_ns);
}

test "summarize takes the nearest-rank p99" {
    var hundred: [100]f64 = undefined;
    for (&hundred, 0..) |*value, index| value.* = @floatFromInt(100 - index);
    // 99 of the 100 values are at or under 99, so the p99 is 99, and the greatest value is 100.
    try testing.expectEqual(@as(f64, 99), summarize(&hundred).p99_ns);
    var two_hundred: [200]f64 = undefined;
    for (&two_hundred, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    try testing.expectEqual(@as(f64, 198), summarize(&two_hundred).p99_ns);
    var one = [_]f64{7};
    try testing.expectEqual(@as(f64, 7), summarize(&one).p99_ns);
}

test "the clock moves forward, and its step is under a microsecond" {
    const first = now_ns();
    const second = now_ns();
    try testing.expect(second >= first);
    try testing.expect(clock_resolution_ns() < std.time.ns_per_us);
}

test "a plan counts the operations of its warm-up and of its samples" {
    const plan: Plan = .{ .warmup = 3, .samples = 8, .batch = 5 };
    try testing.expectEqual(@as(u64, (3 + 8) * 5), plan.operations());
}

const PairContext = struct {
    first_operations: u64 = 0,
    second_operations: u64 = 0,

    pub fn run_first(context: *PairContext, batch: u32) void {
        context.first_operations += batch;
    }

    pub fn run_second(context: *PairContext, batch: u32) void {
        context.second_operations += batch;
        // Long enough to take more time than the first loop by more than one step of the clock.
        spin_until(now_ns() + std.time.ns_per_ms);
    }
};

test "sample_pairs runs both loops in each sample, and gives the second less the first" {
    var context: PairContext = .{};
    var storage: [3][4]f64 = undefined;
    const values: [3][]f64 = .{ &storage[0], &storage[1], &storage[2] };
    const plan: Plan = .{ .warmup = 1, .samples = 4, .batch = 10 };
    const pair = sample_pairs(PairContext, &context, plan, &values);
    try testing.expectEqual(plan.operations(), context.first_operations);
    try testing.expectEqual(plan.operations(), context.second_operations);
    try testing.expect(pair.difference.median_ns > 0);
    try testing.expect(pair.second.median_ns > pair.first.median_ns);
    // Each kept sample of the second loop spun for a millisecond, over a batch of 10.
    try testing.expect(pair.second.least_ns >= std.time.ns_per_ms / 10);
}
