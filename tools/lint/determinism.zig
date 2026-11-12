//! determinism: the package reads no clock and no random source (rotor's decision 34, "What it
//! keeps"). What the package decides is a function of what the program calls and what the reactor
//! hands over. So a twin under the reactor can replay it.
//!
//! Over each `.zig` file under `src/`, the rule flags three shapes of a chain:
//!   1. a chain that starts with one of `forbidden_prefixes` at a dot boundary. The rule flags
//!      `std.time` whole, its unit constants included: a duration that the package uses is a
//!      named limit in `constants.zig`;
//!   2. a chain that starts with one of `forbidden_raw_prefixes`, with no boundary;
//!   3. a chain that holds the name of a call of `host_reads` as one segment, such as
//!      `std.posix.system.clock_gettime` or `linux.getrandom`.
//!
//! The rule also reads a chain through each top-level `const` of the file whose value is a chain
//! or `@import("std")`. So `const time = std.time;` hides no read.
//!
//! No list holds `std.Io.Clock`, and rotor's list holds it. The table of a `std.Io` has a call
//! `now` that takes a `std.Io.Clock`, so the package must name the type. For the `awake` and
//! `boot` clocks, `now` reads the reactor's `now_ns`. Each other clock, `random` and
//! `randomSecure` go to `rest`, the `std.Io` that the program hands over (decision 34, "What it
//! cannot keep"). The rule cannot see a read through `rest`, and the design allows it.
//!
//! The lists are the whole guard. The `comptime` check below stops the build for a name that Zig
//! removed, so no entry stays that guards nothing. It cannot find a clock that Zig has and the
//! lists lack. So a person reads the lists against the standard library at each Zig upgrade. The
//! last such read was against Zig 0.16.0, on 2026-11-12.
//!
//! What the rule cannot see:
//!
//! - a clock that a function receives as a parameter;
//! - an alias of a name of `forbidden_prefixes` inside a function, or inside a container below the
//!   top level;
//! - an alias whose value is not a plain chain, such as `@field(std, "time")`;
//! - `@import("std").time`, written in place of `std.time`;
//! - a name of `forbidden_prefixes` that another file exports;
//! - a read of the processor's own counter in assembly.
//!
//! The rule is pepegrillo's `forbidden_references`. This file holds tejedor's configuration of it,
//! and the fixtures that pin the configuration.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const forbidden_references = lint.rules.forbidden_references;

/// A namespace of the standard library that reads the clock or draws random numbers.
const forbidden_prefixes = [_][]const u8{
    "std.time",
    "std.Random",
};

/// `std.posix` holds no clock call in Zig 0.16.0. This entry matches its two clock types,
/// `clock_t` and `clockid_t`, which are a step towards a read. It also matches the call, if Zig
/// puts it back.
const forbidden_raw_prefixes = [_][]const u8{"std.posix.clock"};

/// Each call of the standard library that reads a clock or a random source of the host, at the
/// place where Zig 0.16.0 declares it.
const host_reads = [_][]const u8{
    "std.c.clock_gettime",
    "std.os.linux.clock_gettime",
    "std.c.gettimeofday",
    "std.os.linux.gettimeofday",
    "std.c.mach_absolute_time",
    "std.c.mach_continuous_time",
    "std.c.arc4random_buf",
    "std.c.getentropy",
    "std.c.getrandom",
    "std.os.linux.getrandom",
};

/// The separator between the segments of a chain.
const segment_separator = '.';

/// The name of each call of `host_reads`: its last segment. The rule flags a chain that holds one
/// of them, so a read through `std.posix.system` or through an alias is a finding too.
const host_read_names = names: {
    var last_segments: [host_reads.len][]const u8 = undefined;
    for (host_reads, &last_segments) |chain, *last_segment| {
        const cut = std.mem.lastIndexOfScalar(u8, chain, segment_separator).?;
        last_segment.* = chain[cut + 1 ..];
    }
    const result = last_segments;
    break :names result;
};

comptime {
    // Each whole name must still name a declaration of the standard library, and the partial name
    // must still match one. A Zig upgrade that removes one stops this build.
    lint.assert_all_resolve(std, "std", &forbidden_prefixes);
    lint.assert_all_resolve(std, "std", &host_reads);
    lint.assert_all_match(std, "std", &forbidden_raw_prefixes);
}

const reason = "the package reads no clock and no random source";

pub const config: forbidden_references.Config = .{
    .name = "determinism",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .prefixes = &forbidden_prefixes,
    .raw_prefixes = &forbidden_raw_prefixes,
    .segment_names = &host_read_names,
    .resolve_file_aliases = true,
    .reason = reason,
};

const Rule = forbidden_references.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape from the header.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/tejedor.zig", source);
    try harness.expect_messages(findings, expected);
}

test "determinism passes a now that names std.Io.Clock and reads the reactor's time" {
    try expect_findings(
        \\const std = @import("std");
        \\const Io = std.Io;
        \\pub fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        \\    const state: *State = @ptrCast(@alignCast(userdata.?));
        \\    return switch (clock) {
        \\        .awake, .boot => .{ .nanoseconds = state.reactor.now_ns() },
        \\        else => state.rest.vtable.now(state.rest.userdata, clock),
        \\    };
        \\}
        \\pub fn deadline(clock: std.Io.Clock, timeout_ns: u64) std.Io.Clock.Timestamp {
        \\    return .{ .raw = .{ .nanoseconds = timeout_ns }, .clock = clock };
        \\}
    , &.{});
}

test "determinism flags the clock namespace, the random namespace and a clock type" {
    try expect_findings(
        \\const std = @import("std");
        \\pub fn sample(counters: *Counters) bool {
        \\    counters.now_ns = std.time.nanoTimestamp();
        \\    counters.second_ns = std.time.ns_per_s;
        \\    var generator = std.Random.DefaultPrng.init(0);
        \\    const clock: std.posix.clockid_t = .MONOTONIC;
        \\    const ticks: std.posix.clock_t = 0;
        \\    _ = .{ clock, ticks };
        \\    return generator.random().int(u8) == 0;
        \\}
    , &.{
        "reference to std.time.nanoTimestamp: " ++ reason,
        "reference to std.time.ns_per_s: " ++ reason,
        "reference to std.Random.DefaultPrng.init: " ++ reason,
        "reference to std.posix.clockid_t: " ++ reason,
        "reference to std.posix.clock_t: " ++ reason,
    });
}

test "determinism flags each call that reads the host, at the place where Zig declares it" {
    try expect_findings(
        \\const std = @import("std");
        \\pub fn read(now: *std.c.timespec, day: *std.c.timeval, bytes: []u8) void {
        \\    _ = std.c.clock_gettime(.MONOTONIC, now);
        \\    _ = std.os.linux.clock_gettime(.MONOTONIC, now);
        \\    _ = std.c.gettimeofday(day, null);
        \\    _ = std.os.linux.gettimeofday(day, null);
        \\    _ = std.c.mach_absolute_time();
        \\    _ = std.c.mach_continuous_time();
        \\    std.c.arc4random_buf(bytes.ptr, bytes.len);
        \\    _ = std.c.getentropy(bytes.ptr, bytes.len);
        \\    _ = std.c.getrandom(bytes.ptr, bytes.len, 0);
        \\    _ = std.os.linux.getrandom(bytes.ptr, bytes.len, 0);
        \\}
    , &.{
        "reference to std.c.clock_gettime: " ++ reason,
        "reference to std.os.linux.clock_gettime: " ++ reason,
        "reference to std.c.gettimeofday: " ++ reason,
        "reference to std.os.linux.gettimeofday: " ++ reason,
        "reference to std.c.mach_absolute_time: " ++ reason,
        "reference to std.c.mach_continuous_time: " ++ reason,
        "reference to std.c.arc4random_buf: " ++ reason,
        "reference to std.c.getentropy: " ++ reason,
        "reference to std.c.getrandom: " ++ reason,
        "reference to std.os.linux.getrandom: " ++ reason,
    });
}

test "determinism flags a host read through std.posix.system and through an alias" {
    try expect_findings(
        \\const std = @import("std");
        \\const zig_std = @import("std");
        \\const posix = std.posix;
        \\const read_clock = std.c.clock_gettime;
        \\pub fn read(now: *posix.timespec, bytes: []u8) void {
        \\    const linux = std.os.linux;
        \\    _ = std.posix.system.clock_gettime(.MONOTONIC, now);
        \\    _ = posix.system.getrandom(bytes.ptr, bytes.len, 0);
        \\    _ = linux.clock_gettime(.MONOTONIC, now);
        \\    _ = zig_std.time.nanoTimestamp();
        \\}
    , &.{
        "reference to std.c.clock_gettime: " ++ reason,
        "reference to std.posix.system.clock_gettime: " ++ reason,
        "reference to posix.system.getrandom: " ++ reason,
        "reference to linux.clock_gettime: " ++ reason,
        "reference to std.time.nanoTimestamp through zig_std: " ++ reason,
    });
}

test "determinism reports an alias of the clock or of the random numbers where it is declared" {
    try expect_findings(
        \\const std = @import("std");
        \\const time = std.time;
        \\const Random = std.Random;
    , &.{
        "reference to std.time: " ++ reason,
        "reference to std.Random: " ++ reason,
    });
}

test "the host reads are the ten calls of the list, and each name is a last segment" {
    // The calls are written out here and not read from `host_reads`. So this test fails when a
    // call leaves that list.
    const expected = [_][2][]const u8{
        .{ "std.c.clock_gettime", "clock_gettime" },
        .{ "std.os.linux.clock_gettime", "clock_gettime" },
        .{ "std.c.gettimeofday", "gettimeofday" },
        .{ "std.os.linux.gettimeofday", "gettimeofday" },
        .{ "std.c.mach_absolute_time", "mach_absolute_time" },
        .{ "std.c.mach_continuous_time", "mach_continuous_time" },
        .{ "std.c.arc4random_buf", "arc4random_buf" },
        .{ "std.c.getentropy", "getentropy" },
        .{ "std.c.getrandom", "getrandom" },
        .{ "std.os.linux.getrandom", "getrandom" },
    };
    try testing.expectEqual(expected.len, host_reads.len);
    try testing.expectEqual(expected.len, host_read_names.len);
    // The loop reads each list by index, so a list of another length fails the lines above when
    // the test runs, and the test still compiles.
    for (expected, 0..) |pair, index| {
        try testing.expectEqualStrings(pair[0], host_reads[index]);
        try testing.expectEqualStrings(pair[1], host_read_names[index]);
    }
}

test "determinism reads src/ alone, its test files included" {
    try testing.expect(config.scope.applies("src/tejedor.zig"));
    try testing.expect(config.scope.applies("src/tejedor_test.zig"));
    try testing.expect(!config.scope.applies("bench/probe.zig"));
    try testing.expect(!config.scope.applies("tools/lint/main.zig"));
    try testing.expect(!config.scope.applies("build.zig"));
}
