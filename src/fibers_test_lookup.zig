//! The tests of `netLookup`, the wrapper around the call of `rest` (rotor's decision 34, "Why
//! `netLookup` is a wrapper", and step 1). A lookup through `std.Io.failing` returns `NetworkDown`,
//! and the caller's queue is closed. With a `rest` of the test that puts two addresses, the caller
//! gets both. A cancel ends the wait of a move to a full queue.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = Io.net;
const fixtures = @import("fibers_test.zig");

const Fixture = fixtures.Fixture;
const LookupResult = net.HostName.LookupResult;

const first_address: net.IpAddress = .{ .ip4 = .loopback(80) };
const second_address: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 80 } };

/// A `netLookup` of `rest` that puts two addresses and closes the queue, as `std.Io.Threaded`
/// does. No context waits on the queue of the package, so `failing` serves for its calls.
fn two_addresses(
    userdata: ?*anyopaque,
    host_name: net.HostName,
    resolved: *Io.Queue(LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    _ = .{ userdata, host_name, options };
    defer resolved.close(Io.failing);
    resolved.putAll(Io.failing, &.{
        .{ .address = first_address },
        .{ .address = second_address },
    }) catch unreachable;
}

/// `std.Io.failing`, with the lookup of `two_addresses`.
const two_addresses_table: Io.VTable = table: {
    var table = Io.failing.vtable.*;
    table.netLookup = two_addresses;
    break :table table;
};

fn look_up(io: Io, queue: *Io.Queue(LookupResult)) net.HostName.LookupError!void {
    const host_name = net.HostName.init("example.com") catch unreachable;
    return host_name.lookup(io, queue, .{ .port = 80 });
}

fn through_failing(io: Io) anyerror!void {
    var buffer: [4]LookupResult = undefined;
    var queue: Io.Queue(LookupResult) = .init(&buffer);
    try testing.expectError(error.NetworkDown, look_up(io, &queue));
    try testing.expectError(error.Closed, queue.getOne(io));
}

test "a lookup through failing returns NetworkDown, and the caller's queue is closed" {
    var fixture: Fixture = undefined;
    try fixture.init(.{ .rest = Io.failing });
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), through_failing);
    try fixture.expect_no_stall();
}

fn both_addresses(io: Io) anyerror!void {
    var buffer: [4]LookupResult = undefined;
    var queue: Io.Queue(LookupResult) = .init(&buffer);
    try look_up(io, &queue);
    const first = try queue.getOne(io);
    try testing.expect(first.address.eql(&first_address));
    const second = try queue.getOne(io);
    try testing.expect(second.address.eql(&second_address));
    try testing.expectError(error.Closed, queue.getOne(io));
}

test "with a rest that puts two addresses, the caller gets both" {
    var fixture: Fixture = undefined;
    var marker: u8 = 0;
    try fixture.init(.{ .rest = .{ .userdata = &marker, .vtable = &two_addresses_table } });
    defer fixture.deinit();
    try fixtures.on_both(fixture.io(), both_addresses);
    try fixture.expect_no_stall();
}

test "a cancel ends a lookup that waits for room in the caller's queue" {
    var fixture: Fixture = undefined;
    var marker: u8 = 0;
    try fixture.init(.{ .rest = .{ .userdata = &marker, .vtable = &two_addresses_table } });
    defer fixture.deinit();
    const io = fixture.io();
    // The queue has room for one result, so the move of the second waits.
    var buffer: [1]LookupResult = undefined;
    var queue: Io.Queue(LookupResult) = .init(&buffer);
    var future = try io.concurrent(look_up, .{ io, &queue });
    try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
    // The first result is in the queue, and the lookup closed it.
    const first = try queue.getOne(io);
    try testing.expect(first.address.eql(&first_address));
    try testing.expectError(error.Closed, queue.getOne(io));
    try fixture.expect_no_stall();
}
