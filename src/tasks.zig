//! The std tasks of a future, and the cancel state of a context (rotor's decision 34, "Which calls
//! run where" and "How cancel works"). Each function takes the `Fibers(Reactor)` value as
//! `fibers`. `Tasks(This)` holds the calls of the table for one `Fibers(Reactor)` type, `This`, and
//! the entry of its fibers.
//!
//! A std task takes a free fiber. Its arguments and its result live at the top of the fiber's
//! stack, so a std task needs no memory of its own. With no fiber free, or with arguments or a
//! result larger than the top of a stack holds, `async` runs the function on the caller's stack,
//! which std allows, and `concurrent` returns `error.ConcurrencyUnavailable`.
//!
//! A fiber of a future stays in use after its function returns, until `await` or `cancel` takes
//! the result. A cancel marks the std task, and ends the wait in which it blocks when that wait
//! is a cancel point. The next cancel point returns `error.Canceled` once, and no later one
//! returns it until `recancel`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Alignment = std.mem.Alignment;
const constants = @import("constants.zig");
const switching = @import("switch.zig");
const fiber_module = @import("fiber.zig");
const memory = @import("memory.zig");
const run = @import("run.zig");
const groups = @import("groups.zig");

const Index = fiber_module.Index;
const index_none = fiber_module.index_none;
const index_main = fiber_module.index_main;
const cancel_point = run.cancel_point;

/// The function of the std task of a future.
pub const FutureStart = fn (context: *const anyopaque, result: *anyopaque) void;

/// The function of the std task of a member of a group.
pub const GroupStart = fn (context: *const anyopaque) void;

/// What a new std task takes.
pub const Start = struct {
    context: []const u8,
    context_alignment: Alignment,
    result_len: usize,
    result_alignment: Alignment,
    /// `FutureStart` or `GroupStart`.
    function: *const anyopaque,
    member: bool,
};

/// True when the arguments and the result of a std task fit the top of a stack.
fn fits(start: *const Start) bool {
    return start.context.len <= constants.context_bytes_max and
        start.result_len <= constants.result_bytes_max and
        start.context_alignment.toByteUnits() <= constants.closure_alignment and
        start.result_alignment.toByteUnits() <= constants.closure_alignment;
}

/// Starts a std task on a free fiber, and makes the fiber ready. Returns null when no fiber is
/// free, or when the std task does not fit the top of a stack.
pub fn spawn(fibers: anytype, start: *const Start) ?Index {
    if (!fits(start)) return null;
    const lists = &fibers.lists;
    const index = lists.take_free() orelse return null;
    const fiber = &lists.fibers[index];
    const arguments = memory.context_bytes(&fibers.layout, fibers.stack_bytes, index);
    @memcpy(arguments[0..start.context.len], start.context);
    fiber.start = start.function;
    fiber.flags.member = start.member;
    const stack_end = memory.stack_end(&fibers.layout, fibers.stack_bytes, index);
    const main = Tasks(@TypeOf(fibers.*)).fiber_main;
    fiber.context = switching.initial_context(stack_end, @intFromPtr(fibers), main);
    lists.make_ready(index);
    return index;
}

/// The whole life of a fiber of `fibers`: it runs the std task, notes that the task returned, and
/// hands the thread on for good.
fn run_fiber(fibers: anytype) noreturn {
    const index = fibers.lists.current;
    const fiber = &fibers.lists.fibers[index];
    const arguments = memory.context_bytes(&fibers.layout, fibers.stack_bytes, index).ptr;
    if (fiber.flags.member) {
        const start: *const GroupStart = @ptrCast(@alignCast(fiber.start.?));
        start(arguments);
        groups.end_member(fibers, index);
    } else {
        const start: *const FutureStart = @ptrCast(@alignCast(fiber.start.?));
        start(arguments, memory.result_bytes(&fibers.layout, fibers.stack_bytes, index).ptr);
        end_future(fibers, index);
    }
    run.leave(fibers);
}

fn end_future(fibers: anytype, index: Index) void {
    const fiber = &fibers.lists.fibers[index];
    assert(fiber.state == .running);
    fiber.state = .finished;
    if (fiber.awaiter != index_none) fibers.lists.make_ready(fiber.awaiter);
}

/// A future is the address of the record of its fiber.
fn future_of(fibers: anytype, index: Index) *Io.AnyFuture {
    return @ptrCast(&fibers.lists.fibers[index]);
}

/// The fiber of `future`, which `await` or `cancel` takes. A future that `await` or `cancel` freed
/// is free, and no context awaits a future twice.
fn awaited_index(fibers: anytype, future: *Io.AnyFuture) Index {
    const index = run.index_of(fibers, @ptrCast(@alignCast(future)));
    assert(index != index_main);
    const fiber = &fibers.lists.fibers[index];
    assert(fiber.state != .free);
    assert(fiber.awaiter == index_none);
    return index;
}

/// Blocks until the std task of fiber `index` returns, copies its result, and frees the fiber.
fn take_result(fibers: anytype, index: Index, result: []u8, result_alignment: Alignment) void {
    assert(result_alignment.toByteUnits() <= constants.closure_alignment);
    assert(result.len <= constants.result_bytes_max);
    const fiber = &fibers.lists.fibers[index];
    assert(!fiber.flags.member);
    if (fiber.state != .finished) {
        fiber.awaiter = fibers.lists.current;
        run.block(fibers, .future, false);
    }
    assert(fiber.state == .finished);
    const bytes = memory.result_bytes(&fibers.layout, fibers.stack_bytes, index);
    @memcpy(result, bytes[0..result.len]);
    fibers.lists.push_free(index);
}

/// Marks the std task of fiber `index`, and ends its wait when a cancel may end it.
pub fn request_cancel(fibers: anytype, index: Index) void {
    assert(index != index_main);
    fibers.lists.fibers[index].flags.cancel_requested = true;
    run.interrupt(fibers, index);
}

pub fn Tasks(comptime This: type) type {
    return struct {
        /// The entry of each fiber of a `This` value. Its argument is the address of the value.
        pub fn fiber_main(argument: usize) callconv(.withStackAlign(.c, switching.stack_end_alignment)) noreturn {
            const fibers: *This = @ptrFromInt(argument);
            run_fiber(fibers);
        }

        pub fn async_task(
            userdata: ?*anyopaque,
            result: []u8,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            start: *const FutureStart,
        ) ?*Io.AnyFuture {
            const fibers = run.from(This, userdata);
            const index = spawn(fibers, &.{
                .context = context,
                .context_alignment = context_alignment,
                .result_len = result.len,
                .result_alignment = result_alignment,
                .function = start,
                .member = false,
            }) orelse {
                start(context.ptr, result.ptr);
                return null;
            };
            return future_of(fibers, index);
        }

        pub fn concurrent(
            userdata: ?*anyopaque,
            result_len: usize,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            start: *const FutureStart,
        ) Io.ConcurrentError!*Io.AnyFuture {
            const fibers = run.from(This, userdata);
            const index = spawn(fibers, &.{
                .context = context,
                .context_alignment = context_alignment,
                .result_len = result_len,
                .result_alignment = result_alignment,
                .function = start,
                .member = false,
            }) orelse return error.ConcurrencyUnavailable;
            return future_of(fibers, index);
        }

        /// Blocks until the std task returns, copies its result, and frees its fiber. It is no
        /// cancel point. One context awaits a future at most.
        pub fn await_task(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
            const fibers = run.from(This, userdata);
            take_result(fibers, awaited_index(fibers, future), result, result_alignment);
        }

        /// Asks the std task to cancel, then blocks as `await` does.
        pub fn cancel(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
            const fibers = run.from(This, userdata);
            const index = awaited_index(fibers, future);
            request_cancel(fibers, index);
            take_result(fibers, index, result, result_alignment);
        }

        /// Makes the next cancel point return `error.Canceled` again. Only a cancel point that
        /// returned it allows this call.
        pub fn recancel(userdata: ?*anyopaque) void {
            const fiber = run.from(This, userdata).lists.running();
            // Only a cancel that came is acknowledged, so this also says that one came.
            assert(fiber.flags.acknowledged);
            fiber.flags.acknowledged = false;
        }

        pub fn swap_cancel_protection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
            const fiber = run.from(This, userdata).lists.running();
            const old = fiber.flags.protection;
            fiber.flags.protection = new;
            return old;
        }

        pub fn check_cancel(userdata: ?*anyopaque) Io.Cancelable!void {
            return cancel_point(run.from(This, userdata).lists.running());
        }
    };
}
