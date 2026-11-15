//! The halt scenarios of `Fibers`, on the reactor of the host: one for each assertion that a
//! mistake of the caller can reach (rotor's decision 34, "Build order", step 1). The eight cases of
//! decision 34 are here, and `fibers_scenarios_calls.zig` holds the scenarios of the calls of std
//! tasks and of the options. Each comment says how the scenario returns when its check is deleted,
//! so the check of the halt sees the mutation.
const std = @import("std");
const Io = std.Io;
const rotor = @import("rotor");
const tejedor = @import("tejedor");
const scenario = @import("scenario.zig");
const calls = @import("fibers_scenarios_calls.zig");

pub const Reactor = rotor.Reactor(rotor.Loop);
pub const Fibers = tejedor.Fibers(Reactor);

pub const fiber_count = 2;

pub const fibers_options: Fibers.Options = .{
    .count = fiber_count,
    .stack_bytes = tejedor.constants.stack_bytes_min,
};

/// The operations of the reactor of the scenarios of a full reactor.
const full_operations = 4;

const reactor_options: Reactor.Options = .{ .loop = .{
    .operations = Fibers.operations(&fibers_options) + full_operations,
} };

var reactor_memory: [Reactor.memory_bytes(&reactor_options)]u8 align(rotor.memory_alignment) = undefined;
pub var reactor: Reactor align(@alignOf(Reactor)) = undefined;
pub var fibers_memory: [Fibers.memory_bytes(&fibers_options)]u8 align(tejedor.memory_alignment) = undefined;
pub var fibers: Fibers align(@alignOf(Fibers)) = undefined;

/// The halt of a scenario that fails before it reaches the statement that breaks the rule.
const preparation_failed = "halt scenario: the preparation failed";

/// A reactor with `operations`, and a `Fibers` value over it, with `rest` of `std.Io.failing`.
pub fn start_with(operations: u32, options: *const Fibers.Options) void {
    var own = reactor_options;
    own.loop.operations = operations;
    reactor.init(&reactor_memory, &own) catch @panic(preparation_failed);
    fibers.init(&reactor, &fibers_memory, Io.failing, options) catch @panic(preparation_failed);
}

pub fn start() void {
    start_with(reactor_options.loop.operations, &fibers_options);
}

/// With the check deleted, `checkCancel` reads the main context and returns.
fn call_from_another_thread() void {
    start();
    const thread = std.Thread.spawn(.{}, check_cancel_there, .{}) catch @panic(preparation_failed);
    thread.join();
}

fn check_cancel_there() void {
    const io = fibers.io();
    scenario.reached_violation();
    io.checkCancel() catch {};
}

/// A record whose function calls `what` in the tick.
const Blocker = struct {
    completion: rotor.Completion = .init(Blocker, "completion", on_event),
    what: *const fn (io: Io) void,

    fn on_event(record: *Blocker, event: rotor.Event) void {
        _ = event;
        scenario.reached_violation();
        record.what(fibers.io());
    }
};

var blocker: Blocker align(@alignOf(Blocker)) = .{ .what = wait_on_futex };

/// A futex wait in a callback blocks, and its block halts. With the check of the block deleted,
/// the wait switches to the main context, which ticks inside its own tick: the tick halts on that,
/// with another text.
fn wait_on_futex(io: Io) void {
    var word: u32 = 0;
    io.futexWaitUncancelable(u32, &word, 0);
}

/// A sleep with no time in a callback halts, as each sleep there does. With the check of `sleep`
/// deleted, the sleep returns at once, and so does the callback.
fn sleep_no_time(io: Io) void {
    io.sleep(.fromNanoseconds(0), .awake) catch {};
}

fn block_in_a_callback(what: *const fn (io: Io) void) void {
    start();
    blocker.what = what;
    const operation = rotor.Completion.mark(&blocker.completion, rotor.Operation.timer(0, 0, 0));
    if (reactor.submit(&.{operation}, &.{}) != 1) @panic(preparation_failed);
    // The main context's sleep ticks, and the tick calls the record.
    fibers.io().sleep(.fromMilliseconds(1), .awake) catch {};
}

fn futex_wait_in_a_callback() void {
    block_in_a_callback(wait_on_futex);
}

fn sleep_in_a_callback() void {
    block_in_a_callback(sleep_no_time);
}

/// With the check deleted, the package's tick goes on, and the sleep returns.
fn tick_by_the_program() void {
    start();
    var events: [4]rotor.Event = undefined;
    _ = reactor.tick(&events, rotor.constants.ns_per_ms) catch @panic(preparation_failed);
    scenario.reached_violation();
    fibers.io().sleep(.fromMilliseconds(1), .awake) catch {};
}

/// With the check deleted, the event goes nowhere, and the sleep returns.
fn event_with_no_handler() void {
    start();
    if (reactor.submit(&.{rotor.Operation.timer(7, 0, 0)}, &.{}) != 1) @panic(preparation_failed);
    scenario.reached_violation();
    fibers.io().sleep(.fromMilliseconds(1), .awake) catch {};
}

/// With the check deleted, the stacks still fit: `memory_bytes` counts a whole granule for the
/// move of the stacks, and the move takes less. So `init` returns.
fn memory_one_byte_short() void {
    reactor.init(&reactor_memory, &reactor_options) catch @panic(preparation_failed);
    scenario.reached_violation();
    const short: []align(tejedor.memory_alignment) u8 = fibers_memory[0 .. fibers_memory.len - 1];
    fibers.init(&reactor, short, Io.failing, &fibers_options) catch {};
}

fn nothing() void {}

/// The std task returned, and no `await` took its result. So the fiber is in use, and on no list.
/// With the check deleted, `deinit` returns.
fn deinit_with_a_fiber_in_use() void {
    start();
    const io = fibers.io();
    var future = io.async(nothing, .{});
    std.mem.doNotOptimizeAway(&future);
    io.sleep(.fromMilliseconds(1), .awake) catch {};
    scenario.reached_violation();
    fibers.deinit();
}

/// The event handler of the scenarios of a full reactor. It drops each event.
fn drop(state: *anyopaque, event: rotor.Event) void {
    _ = .{ state, event };
}

var drop_state: u8 = 0;

/// The timers of the test take each slot for 50 ms. Each try of the package ticks with a wait of 0,
/// so the tries end long before. With the check deleted, the tries go on until a timer ends, and
/// the call returns.
fn fill_for_50_ms() void {
    var options = fibers_options;
    options.event_handler = .{ .state = &drop_state, .handle = drop };
    start_with(full_operations, &options);
    const timers: [full_operations]rotor.Operation = @splat(rotor.Operation.timer(0, 50 * rotor.constants.ns_per_ms, 0));
    if (reactor.submit(&timers, &.{}) != full_operations) @panic(preparation_failed);
}

fn sleep_on_a_full_reactor() void {
    fill_for_50_ms();
    scenario.reached_violation();
    fibers.io().sleep(.fromMilliseconds(1), .awake) catch {};
}

fn futex_wait_on_a_full_reactor() void {
    fill_for_50_ms();
    scenario.reached_violation();
    var word: u32 = 0;
    fibers.io().futexWaitTimeout(u32, &word, 0, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch {};
}

/// The bytes of the frame that overflows: the stack, less its top and 3 KiB. Its lowest byte is in
/// the first 3 KiB of the stack, which is in the guard page on each host.
const overflow_bytes = tejedor.constants.stack_bytes_min - tejedor.constants.closure_bytes - 3 * 1024;

noinline fn overflow() void {
    var bytes: [overflow_bytes]u8 = undefined;
    std.mem.doNotOptimizeAway(&bytes);
    bytes[0] = 1;
    std.mem.doNotOptimizeAway(&bytes);
}

fn overflow_on_a_fiber() void {
    scenario.reached_violation();
    overflow();
}

/// With no guard page, the frame takes the lowest page of the stack, which can be written, and the
/// std task returns.
fn a_fiber_overflows_its_stack() void {
    start();
    const io = fibers.io();
    var future = io.concurrent(overflow_on_a_fiber, .{}) catch @panic(preparation_failed);
    future.await(io);
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "fibers: a call from another thread", .run = call_from_another_thread, .expected = "does not own its reactor" },
    .{ .name = "fibers: a futex wait in a callback", .run = futex_wait_in_a_callback, .expected = "a call that blocks came from a callback" },
    .{ .name = "fibers: a sleep of no time in a callback", .run = sleep_in_a_callback, .expected = "a call that blocks came from a callback" },
    .{ .name = "fibers: a tick by the program", .run = tick_by_the_program, .expected = "ticked outside the package" },
    .{ .name = "fibers: an event with no record and no event handler", .run = event_with_no_handler, .expected = "Options.event_handler is null" },
    .{ .name = "fibers: memory one byte short", .run = memory_one_byte_short, .expected = scenario.assertion },
    .{ .name = "fibers: a deinit while a fiber is in use", .run = deinit_with_a_fiber_in_use, .expected = scenario.assertion },
    .{ .name = "fibers: a sleep on a reactor that stays full", .run = sleep_on_a_full_reactor, .expected = "stayed full" },
    .{ .name = "fibers: a futex wait on a reactor that stays full", .run = futex_wait_on_a_full_reactor, .expected = "stayed full" },
    .{ .name = "fibers: a fiber that overflows its stack", .run = a_fiber_overflows_its_stack, .expected = "" },
} ++ calls.scenarios;

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
