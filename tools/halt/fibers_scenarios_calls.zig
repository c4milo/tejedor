//! The halt scenarios of the calls of std tasks and of the options of `Fibers`, a piece of
//! `fibers_scenarios.zig`. Each comment says how the scenario returns, or waits until the watchdog
//! ends it, when its check is deleted.
const std = @import("std");
const Io = std.Io;
const rotor = @import("rotor");
const tejedor = @import("tejedor");
const scenario = @import("scenario.zig");
const main = @import("fibers_scenarios.zig");

const Fibers = main.Fibers;
const constants = tejedor.constants;

/// Each check of the options, with the other four kept, returns a size when it is deleted.
fn size_of(options: Fibers.Options) void {
    scenario.reached_violation();
    std.mem.doNotOptimizeAway(Fibers.memory_bytes(&options));
}

fn no_fiber() void {
    size_of(.{ .count = 0, .stack_bytes = constants.stack_bytes_min });
}

fn too_many_fibers() void {
    size_of(.{ .count = constants.fibers_max + 1, .stack_bytes = constants.stack_bytes_min });
}

fn a_stack_too_small() void {
    size_of(.{ .count = 1, .stack_bytes = constants.stack_bytes_min - constants.stack_granule_bytes });
}

fn a_stack_too_large() void {
    size_of(.{ .count = 1, .stack_bytes = constants.stack_bytes_max + constants.stack_granule_bytes });
}

fn a_stack_off_the_granule() void {
    size_of(.{ .count = 1, .stack_bytes = constants.stack_bytes_min + constants.closure_alignment });
}

/// With the check deleted, `recancel` clears a flag that is clear, and returns.
fn recancel_with_no_cancel() void {
    main.start();
    scenario.reached_violation();
    main.fibers.io().recancel();
}

fn nothing() void {}

/// A copy of a future, awaited after the future. With the check deleted, the second `await` waits
/// on a free fiber with no end, until the watchdog ends the process.
fn await_a_future_twice() void {
    main.start();
    const io = main.fibers.io();
    var future = io.async(nothing, .{});
    var copy = future;
    future.await(io);
    scenario.reached_violation();
    copy.await(io);
}

fn nap(io: Io) void {
    io.sleep(.fromMilliseconds(50), .awake) catch {};
}

fn await_copy(io: Io, future: *Io.Future(void)) void {
    future.await(io);
}

/// Two contexts await one future. With the check deleted, the main context takes the place of
/// the first one, the std task wakes it after its sleep, and the scenario returns.
fn await_a_future_from_two_contexts() void {
    main.start();
    const io = main.fibers.io();
    var sleeper = io.async(nap, .{io});
    var copy = sleeper;
    var first = io.async(await_copy, .{ io, &copy });
    // The main context sleeps, so the sleeper blocks in its timer, and `first` in its await.
    io.sleep(.fromMilliseconds(1), .awake) catch {};
    std.mem.doNotOptimizeAway(&first);
    scenario.reached_violation();
    sleeper.await(io);
}

var second_memory: [Fibers.memory_bytes(&main.fibers_options)]u8 align(tejedor.memory_alignment) = undefined;
var second: Fibers align(@alignOf(Fibers)) = undefined;

/// A group whose member ran on one value, and a second value on the same reactor. The await of
/// another std task lets the member run first, so the group has no member left, and keeps its
/// token.
fn group_of_the_first_value() Io.Group {
    main.start();
    second.init(&main.reactor, &second_memory, Io.failing, &main.fibers_options) catch
        @panic("halt scenario: the preparation failed");
    const io = main.fibers.io();
    var group: Io.Group = .init;
    group.concurrent(io, nothing, .{}) catch @panic("halt scenario: the preparation failed");
    var task = io.async(nothing, .{});
    task.await(io);
    return group;
}

/// With the check deleted, the second value finds no member left, closes the group, and returns.
fn await_a_group_on_another_value() void {
    var group = group_of_the_first_value();
    scenario.reached_violation();
    group.await(second.io()) catch {};
}

/// As above, with a cancel.
fn cancel_a_group_on_another_value() void {
    var group = group_of_the_first_value();
    scenario.reached_violation();
    group.cancel(second.io());
}

/// With the check deleted, `deinit` finds each fiber free, and returns.
fn deinit_from_another_thread() void {
    main.start();
    const thread = std.Thread.spawn(.{}, deinit_there, .{}) catch @panic("halt scenario: the preparation failed");
    thread.join();
}

fn deinit_there() void {
    scenario.reached_violation();
    main.fibers.deinit();
}

/// A record that ends the value inside the tick.
const Ender = struct {
    completion: rotor.Completion = .init(Ender, "completion", on_event),

    fn on_event(record: *Ender, event: rotor.Event) void {
        _ = .{ record, event };
        scenario.reached_violation();
        main.fibers.deinit();
    }
};

var ender: Ender align(@alignOf(Ender)) = .{};

/// With the check deleted, `deinit` ends the value inside its own tick. The tick then reads the
/// value that `deinit` ended, and the process dies without the text of the check, or the sleep
/// returns.
fn deinit_in_a_callback() void {
    main.start();
    const operation = rotor.Completion.mark(&ender.completion, rotor.Operation.timer(0, 0, 0));
    if (main.reactor.submit(&.{operation}, &.{}) != 1) @panic("halt scenario: the preparation failed");
    main.fibers.io().sleep(.fromMilliseconds(1), .awake) catch {};
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "fibers: options with no fiber", .run = no_fiber, .expected = scenario.assertion },
    .{ .name = "fibers: options with too many fibers", .run = too_many_fibers, .expected = scenario.assertion },
    .{ .name = "fibers: a stack below the smallest", .run = a_stack_too_small, .expected = scenario.assertion },
    .{ .name = "fibers: a stack above the largest", .run = a_stack_too_large, .expected = scenario.assertion },
    .{ .name = "fibers: a stack off the granule", .run = a_stack_off_the_granule, .expected = scenario.assertion },
    .{ .name = "fibers: recancel with no cancel", .run = recancel_with_no_cancel, .expected = scenario.assertion },
    .{ .name = "fibers: await a future twice", .run = await_a_future_twice, .expected = scenario.assertion },
    .{ .name = "fibers: await a future from two contexts", .run = await_a_future_from_two_contexts, .expected = scenario.assertion },
    .{ .name = "fibers: await a group on another value", .run = await_a_group_on_another_value, .expected = scenario.assertion },
    .{ .name = "fibers: cancel a group on another value", .run = cancel_a_group_on_another_value, .expected = scenario.assertion },
    .{ .name = "fibers: a deinit from another thread", .run = deinit_from_another_thread, .expected = "does not own its reactor" },
    .{ .name = "fibers: a deinit in a callback", .run = deinit_in_a_callback, .expected = "deinit of a Fibers value came from a callback" },
};
