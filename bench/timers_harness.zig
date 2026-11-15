//! The parts of rotor's bench harness that `bench/std_io_timers.zig` uses, at v0.11.0: the clock,
//! the percentile of nearest rank, the rate, and the result line. rotor's package holds no
//! `bench/` (its `build.zig.zon`, `.paths`), so the package holds this copy (rotor's decision 34,
//! "The timer program", and record 7). Each function is rotor's, from `bench/harness/clock.zig`,
//! `bench/harness/percentile.zig` and `bench/harness/report.zig`. The result line prints the
//! fields of rotor's `Result.render_json_line`, in its order.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Timespec = if (builtin.os.tag == .linux) std.os.linux.timespec else std.c.timespec;

const ns_per_s: u64 = 1_000_000_000;

/// The monotonic clock of the host, in nanoseconds: `CLOCK_MONOTONIC` on Linux, and
/// `CLOCK_MONOTONIC_RAW` on macOS, as rotor's harness reads it.
pub fn now_ns() u64 {
    var value: Timespec = undefined;
    if (builtin.os.tag == .linux) {
        assert(std.os.linux.clock_gettime(.MONOTONIC, &value) == 0);
    } else {
        assert(std.c.clock_gettime(.MONOTONIC_RAW, &value) == 0);
    }
    assert(value.sec >= 0);
    assert(value.nsec >= 0);
    return @as(u64, @intCast(value.sec)) * ns_per_s + @as(u64, @intCast(value.nsec));
}

/// The parts of ten thousand of each percentile that a row reports.
pub const p50: u64 = 5_000;
pub const p99: u64 = 9_900;
pub const p999: u64 = 9_990;
pub const p9999: u64 = 9_999;

const per_ten_thousand: u64 = 10_000;

/// The value of nearest rank at `parts` of ten thousand, of a sorted sample. An empty sample is 0.
pub fn nearest_rank(sorted: []const u64, parts: u64) u64 {
    assert(parts <= per_ten_thousand);
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * parts + per_ten_thousand - 1) / per_ten_thousand;
    const index = @min(@max(rank, 1) - 1, sorted.len - 1);
    return sorted[index];
}

/// The operations of a second, for `operations` in `duration_ns`.
pub fn per_second(operations: u64, duration_ns: u64) u64 {
    assert(duration_ns >= 1);
    const scaled = @as(u128, operations) * ns_per_s;
    return std.math.cast(u64, scaled / duration_ns) orelse std.math.maxInt(u64);
}

/// One row of the timer workload.
pub const Result = struct {
    candidate: []const u8,
    version: []const u8,
    /// The timers armed at once, in the field `connections`, as rotor_timers' row has it.
    timers: u32,
    duration_ns: u64,
    operations: u64,
    p50_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    p9999_ns: u64,

    /// The line of rotor's `Result.render_json_line`, with the fields of this workload.
    pub fn render_json_line(result: *const Result, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{\"workload\":\"timer-churn\",\"candidate\":\"{s}\",\"version\":\"{s}\"", .{
            result.candidate, result.version,
        });
        try writer.print(",\"cores\":0,\"connections\":{d},\"payload_bytes\":0,\"load\":\"even\"", .{result.timers});
        try writer.print(",\"duration_ns\":{d},\"operations\":{d},\"operations_per_second\":{d}", .{
            result.duration_ns, result.operations, per_second(result.operations, result.duration_ns),
        });
        try writer.print(",\"p50_ns\":{d},\"p99_ns\":{d},\"p999_ns\":{d},\"p9999_ns\":{d}", .{
            result.p50_ns, result.p99_ns, result.p999_ns, result.p9999_ns,
        });
        try writer.writeAll(",\"overflow\":0,\"peak_rss_bytes\":0}\n");
    }
};

const testing = std.testing;

test "the nearest rank of a sample is one of its values" {
    try testing.expectEqual(@as(u64, 0), nearest_rank(&.{}, p50));
    try testing.expectEqual(@as(u64, 7), nearest_rank(&.{7}, p9999));
    try testing.expectEqual(@as(u64, 2), nearest_rank(&.{ 1, 2, 3, 4 }, p50));
    try testing.expectEqual(@as(u64, 4), nearest_rank(&.{ 1, 2, 3, 4 }, p99));
}

test "the rate counts the operations of one second" {
    try testing.expectEqual(@as(u64, 2), per_second(2, ns_per_s));
    try testing.expectEqual(@as(u64, 4), per_second(2, ns_per_s / 2));
}
