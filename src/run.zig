//! Which context runs, and when the reactor ticks (rotor's decision 34, "How one call that blocks
//! runs" and "The ready list and the tick"). Each function takes the `Fibers(Reactor)` value as
//! `fibers`, of any reactor's type.
//!
//! A context that blocks switches to the first ready context. When no context is ready, or after
//! `resumes_between_ticks_max` switches to a fiber, it switches to the main context. Only the main
//! context ticks, so each callback runs on the thread's own stack. The main context runs the ready
//! contexts, and ticks, until its own wait ends.
//!
//! Each operation of a context names the record of that context. A tick calls the record with the
//! operation's final event, and the record puts the context at the end of the ready list. Each
//! other event that a tick returns goes to the event handler, in the order of the batch.
//!
//! From the start of each tick until the event handler took its last event, the package is in a
//! callback. A call that must block there halts, because its wait would need a tick inside a tick.
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("rotor");
const constants = @import("constants.zig");
const switching = @import("switch.zig");
const fiber_module = @import("fiber.zig");

const Fiber = fiber_module.Fiber;
const Index = fiber_module.Index;
const Wait = fiber_module.Wait;
const index_main = fiber_module.index_main;
const canceled_result = fiber_module.canceled_result;

/// Each address of this variable names the thread that reads it, because each thread has its own.
threadlocal var thread_marker: u8 = 0;

/// A number that names the thread that calls it, and no other thread while it runs.
pub fn thread_id() usize {
    return @intFromPtr(&thread_marker);
}

/// The message of the halt of a call from another thread (decision 34, questions 8 and 15).
pub const another_thread = "tejedor: a call of the io of a Fibers value came from a thread " ++
    "that does not own its reactor. Only the reactor's thread calls the io " ++
    "(rotor's decision 34, questions 8 and 15)";

/// The message of the halt of a call that must block in a callback.
pub const callback_blocks = "tejedor: a call that blocks came from a callback: a record, a " ++
    "poller, a rotor task or the event handler. A callback cannot wait, because its wait would " ++
    "need a tick inside a tick. A callback starts a fiber with concurrent for work that blocks " ++
    "(rotor's decision 34, \"Where a call comes from\")";

/// The message of the halt of a `deinit` in a callback, whose tick still runs.
pub const deinit_in_callback = "tejedor: deinit of a Fibers value came from a callback, inside " ++
    "a tick of the package. The main context ends the value, after each future and each " ++
    "Io.Group ended (rotor's decision 34, \"The shape a caller sees\")";

/// The message of the halt of a tick that the program made while the value lives.
pub const program_ticked = "tejedor: the reactor ticked outside the package. While a Fibers " ++
    "value lives, the package is the one caller of tick (rotor's decision 34, \"What the " ++
    "package holds\")";

/// The message of the halt of an event that no record and no event handler takes.
pub const no_event_handler = "tejedor: the reactor returned an event of an operation that " ++
    "names no record, or a message of another loop, and Options.event_handler is null " ++
    "(rotor's decision 34, \"Other libraries on the same reactor\")";

/// The message of the halt of a sleep or a futex wait on a reactor that stays full.
pub const reactor_full = "tejedor: the reactor stayed full for each try of a sleep or a futex " ++
    "wait. Add Fibers.operations(&options) to the operations of the reactor (rotor's " ++
    "decision 34, \"When the reactor is full\")";

/// A cancel point: `error.Canceled` once, for a cancel that the protection allows (decision 34,
/// "How cancel works").
pub fn cancel_point(fiber: *Fiber) error{Canceled}!void {
    assert(fiber.state == .running);
    const flags = &fiber.flags;
    if (!flags.cancel_requested or flags.protection == .blocked or flags.acknowledged) return;
    flags.acknowledged = true;
    return error.Canceled;
}

/// The result of the wait that just ended: `error.Canceled` when a cancel ended it.
pub fn end_wait(fiber: *Fiber) error{Canceled}!i32 {
    assert(fiber.state == .running);
    if (fiber.flags.interrupted and fiber.result == canceled_result) {
        assert(!fiber.flags.acknowledged);
        fiber.flags.acknowledged = true;
        return error.Canceled;
    }
    return fiber.result;
}

/// The value behind `userdata`, for a call from the thread that owns it. A call from
/// another thread halts.
pub fn from(comptime This: type, userdata: ?*anyopaque) *This {
    const fibers: *This = @ptrCast(@alignCast(userdata.?));
    if (fibers.thread != thread_id()) @panic(another_thread);
    return fibers;
}

/// The index of the record `fiber` among the records of `fibers`.
pub fn index_of(fibers: anytype, fiber: *const Fiber) Index {
    const offset = @intFromPtr(fiber) - @intFromPtr(fibers.lists.fibers.ptr);
    assert(offset % @sizeOf(Fiber) == 0);
    const index = offset / @sizeOf(Fiber);
    assert(index < fibers.lists.fibers.len);
    return @intCast(index);
}

/// Blocks the context that runs until a record, a wake or a cancel makes it ready.
/// `cancelable` says whether a cancel may end the wait. It does only while the protection
/// allows a cancel and no cancel point returned `error.Canceled` yet.
pub fn block(fibers: anytype, wait: Wait, cancelable: bool) void {
    if (fibers.in_callback) @panic(callback_blocks);
    const lists = &fibers.lists;
    const me = lists.current;
    const fiber = &lists.fibers[me];
    assert(fiber.state == .running);
    assert(wait != .none);
    fiber.state = .blocked;
    fiber.wait = wait;
    const flags = &fiber.flags;
    flags.cancelable = cancelable and flags.protection == .unblocked and !flags.acknowledged;
    flags.interrupted = false;
    if (me == index_main) run_main(fibers) else switch_away(fibers);
    assert(lists.current == me);
    assert(fiber.state == .running);
    fiber.wait = .none;
    flags.cancelable = false;
}

/// Hands the thread on for good: the fiber that runs ended its std task. No context
/// switches back to it.
pub fn leave(fibers: anytype) noreturn {
    switch_away(fibers);
    unreachable;
}

/// True when the next switch goes to the main context, so that it ticks.
fn must_tick(fibers: anytype) bool {
    return !fibers.lists.any_ready() or
        fibers.resumes >= constants.resumes_between_ticks_max;
}

/// The fiber that runs stops, because it blocks or ends. It switches to the first ready
/// context, or to the main context when that one must tick.
fn switch_away(fibers: anytype) void {
    assert(fibers.lists.current != index_main);
    if (must_tick(fibers)) return switch_to(fibers, index_main);
    const next = fibers.lists.pop_ready();
    if (next != index_main) fibers.resumes += 1;
    switch_to(fibers, next);
}

/// The main context waits: it runs the ready contexts, and ticks, until a context makes it
/// ready and the main context takes its turn. No bound: when each context waits and
/// nothing wakes one, the main context ticks with no end (decision 34, question 16).
fn run_main(fibers: anytype) void {
    const lists = &fibers.lists;
    while (lists.fibers[index_main].state != .running) {
        if (must_tick(fibers)) {
            tick(fibers);
            continue;
        }
        const next = lists.pop_ready();
        if (next == index_main) return;
        fibers.resumes += 1;
        switch_to(fibers, next);
    }
}

fn switch_to(fibers: anytype, next: Index) void {
    const lists = &fibers.lists;
    const previous = lists.current;
    assert(next != previous);
    lists.current = next;
    const message: switching.Switch = .{
        .old = &lists.fibers[previous].context,
        .new = &lists.fibers[next].context,
    };
    switching.switch_context(&message);
}

/// One tick of the reactor, on the main context. Its wait is 0 while a context is ready or
/// waits for a slot, and `wait_ns_max` otherwise.
fn tick(fibers: anytype) void {
    const lists = &fibers.lists;
    const ready = lists.any_ready() or lists.any_slot();
    tick_with(fibers, if (ready) 0 else rotor.constants.wait_ns_max);
}

/// The tick of `init` when the reactor read no clock yet: a wait of 0, so that `now_ns`
/// is set before the first operation (decision 34, "Where a call comes from").
pub fn first_tick(fibers: anytype) void {
    assert(fibers.reactor.now_ns() == 0);
    tick_with(fibers, 0);
    assert(fibers.reactor.now_ns() != 0);
}

/// One tick with a wait of `wait_ns`. Before a tick that can wait, the poller of the
/// package moves behind each other poller.
fn tick_with(fibers: anytype, wait_ns: u64) void {
    assert(fibers.lists.current == index_main);
    assert(!fibers.in_callback);
    const reactor = fibers.reactor;
    if (reactor.now_ns() != fibers.now_ns_last) @panic(program_ticked);
    const lists = &fibers.lists;
    if (wait_ns != 0) move_poller_last(fibers);
    fibers.in_callback = true;
    const count = reactor.tick(&fibers.events, wait_ns) catch |err|
        std.debug.panic("tejedor: the reactor's tick failed: {s}", .{@errorName(err)});
    fibers.now_ns_last = reactor.now_ns();
    for (fibers.events[0..count]) |event| hand_over(fibers, event);
    fibers.in_callback = false;
    fibers.resumes = 0;
    lists.release_slots();
}

/// The reactor calls its pollers in the order of their adds. So the package removes its
/// poller and adds it again, which puts it after each other poller.
fn move_poller_last(fibers: anytype) void {
    fibers.reactor.remove_poller(&fibers.poller);
    // The poller left one place free.
    fibers.reactor.add_poller(&fibers.poller) catch unreachable;
}

/// An event of no record of the package: the program's, or a message of another loop.
fn hand_over(fibers: anytype, event: rotor.Event) void {
    const handler = fibers.event_handler orelse @panic(no_event_handler);
    handler.handle(handler.state, event);
}

/// The work of the record of each context: one store of the result, and one push on the ready
/// list. A timer of a futex wait also takes the context off the futex list.
pub fn record_event(fibers: anytype, fiber: *Fiber, event: rotor.Event) void {
    // Each operation of a context makes one event, its final one.
    assert(event.is_final());
    assert(fiber.state == .blocked);
    assert(!fiber.handle.is_none());
    fiber.handle = .none;
    fiber.result = event.result;
    const index = index_of(fibers, fiber);
    if (fiber.wait == .futex) fibers.lists.unlink_futex(index);
    fibers.lists.make_ready(index);
}

/// The answer of the poller of the package: `.now` while a context is ready, so that a tick does
/// not wait then.
pub fn poll(fibers: anytype) rotor.WaitLimit {
    return if (fibers.lists.any_ready()) .now else .none;
}

/// Submits `operation` for the context that runs, with the record of that context. Returns
/// false when the reactor has no free slot.
pub fn try_submit(fibers: anytype, operation: rotor.Operation) bool {
    const fiber = fibers.lists.running();
    assert(fiber.handle.is_none());
    const marked = rotor.Completion.mark(&fiber.completion, operation);
    var handles = [1]rotor.Handle{.none};
    if (fibers.reactor.submit(&.{marked}, &handles) == 0) return false;
    assert(!handles[0].is_none());
    fiber.handle = handles[0];
    return true;
}

/// Blocks the context that runs until the next tick returns, on a full reactor. A cancel
/// ends the wait with `error.Canceled`.
pub fn wait_for_slot(fibers: anytype) error{Canceled}!void {
    fibers.lists.push_slot();
    block(fibers, .slot, true);
    _ = try end_wait(fibers.lists.running());
}

/// Submits `operation` for the context that runs, in at most `submit_tries_max` tries. A
/// full reactor blocks the context until the next tick between two tries.
pub fn submit(fibers: anytype, operation: rotor.Operation) error{ Canceled, ReactorFull }!void {
    var tries: u32 = 1;
    while (!try_submit(fibers, operation)) : (tries += 1) {
        if (tries == constants.submit_tries_max) return error.ReactorFull;
        try wait_for_slot(fibers);
    }
}

/// Ends the wait of context `index` for a cancel, when its wait allows one.
pub fn interrupt(fibers: anytype, index: Index) void {
    const lists = &fibers.lists;
    const fiber = &lists.fibers[index];
    if (fiber.state != .blocked or !fiber.flags.cancelable) return;
    fiber.flags.cancelable = false;
    fiber.flags.interrupted = true;
    switch (fiber.wait) {
        .operation => fibers.reactor.cancel(fiber.handle),
        .futex => {
            lists.unlink_futex(index);
            end_futex_wait(fibers, index, canceled_result);
        },
        .slot => {
            lists.unlink_slot(index);
            fiber.result = canceled_result;
            lists.make_ready(index);
        },
        .cancel, .group => {
            fiber.result = canceled_result;
            lists.make_ready(index);
        },
        .none, .future => unreachable,
    }
}

/// Ends a futex wait that the futex list no longer holds. With no timer, the context is
/// ready at once. With a timer, the context waits for the timer's final event, which the
/// cancel asks the reactor for. So no event of the package comes after its wait.
pub fn end_futex_wait(fibers: anytype, index: Index, result: i32) void {
    const fiber = &fibers.lists.fibers[index];
    assert(fiber.state == .blocked);
    assert(fiber.wait == .futex);
    fiber.result = result;
    if (fiber.handle.is_none()) return fibers.lists.make_ready(index);
    fiber.wait = .operation;
    fibers.reactor.cancel(fiber.handle);
}

/// The functions of the record and of the poller of one `Fibers(Reactor)` type, `This`. The reactor
/// calls each one with the address of a field of the value.
pub fn Callbacks(comptime This: type) type {
    return struct {
        pub fn on_event(fiber: *Fiber, event: rotor.Event) void {
            const fibers: *This = @ptrCast(@alignCast(fiber.owner));
            record_event(fibers, fiber, event);
        }

        pub fn on_poll(fibers: *This) rotor.WaitLimit {
            return poll(fibers);
        }
    };
}
