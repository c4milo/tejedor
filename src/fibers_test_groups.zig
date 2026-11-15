//! The tests of an `Io.Group` (rotor's decision 34, "How cancel works"): `Group.async`,
//! `Group.concurrent`, `Group.await` and `Group.cancel`, each on the main context and on a fiber.
//! A cancel of a fiber in `Group.await` reaches each member, and the call returns after the last
//! member (decision 34, step 1).
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const fixtures = @import("fibers_test.zig");

const Fixture = fixtures.Fixture;
const millisecond_ns = fixtures.millisecond_ns;
const fiber_count = fixtures.fiber_count;

fn count_up(io: Io, counter: *u32) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(1), .awake);
    counter.* += 1;
}

/// Three members on fibers, and one on the caller's stack when no fiber is free.
fn await_members(io: Io) anyerror!void {
    var counter: u32 = 0;
    var group: Io.Group = .init;
    const free: u32 = if (fixtures.current_of(io) == 0) fiber_count else fiber_count - 1;
    for (0..free) |_| try group.concurrent(io, count_up, .{ io, &counter });
    // Each fiber is taken, so one more member runs on the caller's stack.
    try testing.expectError(error.ConcurrencyUnavailable, group.concurrent(io, count_up, .{ io, &counter }));
    group.async(io, count_up, .{ io, &counter });
    try testing.expectEqual(1, counter);
    try group.await(io);
    try testing.expectEqual(free + 1, counter);
    try testing.expect(group.token.raw == null);
    // Each fiber of a member is free again.
    for (0..free) |_| try group.concurrent(io, count_up, .{ io, &counter });
    try group.await(io);
}

test "a group awaits each member, and the fiber of each member is free when it returns" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), await_members);
    try fixture.expect_no_stall();
}

fn member(io: Io, ended: *u32) Io.Cancelable!void {
    defer ended.* += 1;
    try io.sleep(.fromSeconds(10), .awake);
}

fn cancel_members(io: Io) anyerror!void {
    var ended: u32 = 0;
    var group: Io.Group = .init;
    try group.concurrent(io, member, .{ io, &ended });
    try group.concurrent(io, member, .{ io, &ended });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const before = Io.Clock.awake.now(io);
    group.cancel(io);
    try testing.expectEqual(2, ended);
    // The sleeps of the members were ten seconds long, and the cancel ended them.
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds < 1000 * millisecond_ns);
    try testing.expect(group.token.raw == null);
}

test "a group cancel ends the wait of each member, and waits for each one" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), cancel_members);
    try fixture.expect_no_stall();
}

/// A member that the cancel ends last: it sleeps once more after the cancel, with no cancel point.
fn slow_member(io: Io, log: *fixtures.Log) Io.Cancelable!void {
    io.sleep(.fromSeconds(10), .awake) catch {
        log.append('m');
        const old = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old);
        io.sleep(.fromMilliseconds(2), .awake) catch unreachable;
        log.append('l');
        return error.Canceled;
    };
}

fn await_group(io: Io, log: *fixtures.Log) (Io.Cancelable || Io.ConcurrentError)!void {
    var group: Io.Group = .init;
    try group.concurrent(io, slow_member, .{ io, log });
    try group.concurrent(io, slow_member, .{ io, log });
    defer log.append('a');
    return group.await(io);
}

test "a cancel of a fiber in Group.await reaches each member, and returns after the last" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var log: fixtures.Log = .{};
    var future = try io.concurrent(await_group, .{ io, &log });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const before = Io.Clock.awake.now(io);
    try testing.expectError(error.Canceled, future.cancel(io));
    // Each member saw the cancel, and the await returned after both ended.
    try testing.expectEqualStrings("mmlla", log.text());
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds < 1000 * millisecond_ns);
    try fixture.expect_no_stall();
}

fn nothing() void {}

test "a group whose members each returned awaits with no wait" {
    var fixture: Fixture = undefined;
    try fixture.init(.{});
    defer fixture.deinit();
    const io = fixture.io();
    var group: Io.Group = .init;
    try group.concurrent(io, nothing, .{});
    // An await of another std task lets the member run first. Its fiber is then free, and the
    // group keeps its token until the await.
    var other = io.async(nothing, .{});
    other.await(io);
    try testing.expect(group.token.raw != null);
    try group.await(io);
    try testing.expect(group.token.raw == null);
    try fixture.expect_no_stall();
}
