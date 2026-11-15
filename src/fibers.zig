//! `Fibers(Reactor)`: a `std.Io` on fibers over one reactor of rotor, on the thread that owns the
//! reactor (rotor's decision 34, "The decision, as proposed"). Camilo ruled the names of this file
//! on 2026-11-14, as the sketch of decision 34 writes them (record 7).
//!
//! The program makes the reactor, and hands `init` a pointer to it, its memory, and `rest`, the
//! `std.Io` that runs each call that the package does not run. From `init` until `deinit`, the
//! package is the one caller of `tick` (decision 34, questions 2 and 11).
//!
//! The package runs 17 calls of the table at step 1 of its build order: the 11 calls of std tasks
//! and cancel, the 3 futex calls, `now` for the `awake` and `boot` clocks, `sleep`, and
//! `netLookup`, a wrapper around the call of `rest`. Each other call goes to `rest`. Each call but
//! `futexWake` halts from another thread, and at step 1 `futexWake` halts there too (decision 34,
//! questions 8 and 15).
//!
//! The files: `run.zig` decides which context runs and ticks the reactor, `tasks.zig` holds the
//! std tasks of a future and the cancel state, `groups.zig` the calls of an `Io.Group`, `wait.zig`
//! the futexes and the time, `lookup.zig` the lookup, and `rest.zig` the forwarders.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const rotor = @import("rotor");
const constants = @import("constants.zig");
const switching = @import("switch.zig");
const fiber_module = @import("fiber.zig");
const lists_module = @import("lists.zig");
const memory_module = @import("memory.zig");
const reactor_check = @import("reactor_check.zig");
const run_module = @import("run.zig");
const tasks_module = @import("tasks.zig");
const groups_module = @import("groups.zig");
const wait_module = @import("wait.zig");
const lookup_module = @import("lookup.zig");
const rest_module = @import("rest.zig");

const Fiber = fiber_module.Fiber;
const Lists = lists_module.Lists;

/// Takes each event that a tick returns and no record of the package takes: an event of an
/// operation that names no record, and a message that another loop posts.
pub const EventHandler = struct {
    state: *anyopaque,
    handle: *const fn (state: *anyopaque, event: rotor.Event) void,
};

/// The alignment of the memory that `init` takes.
pub const memory_alignment = memory_module.memory_alignment;

/// A `std.Io` on fibers over a reactor of type `Reactor`: `rotor.Reactor(rotor.Loop)`, or the
/// reactor of a twin (decision 34, question 14). The build stops with one error that names each
/// declaration that `Reactor` lacks, and on a target that the switch does not support.
pub fn Fibers(comptime Reactor: type) type {
    comptime reactor_check.check(Reactor);
    if (!switching.supported) @compileError("tejedor: the context switch has no form for this " ++
        "target, so tejedor.supported is false (record 5)");
    return struct {
        reactor: *Reactor,
        rest: Io,
        event_handler: ?EventHandler,
        lists: Lists,
        layout: memory_module.Layout,
        stack_bytes: u32,
        /// The thread that called `init`, which owns the reactor.
        thread: usize,
        /// The switches to a fiber since the last tick.
        resumes: u32,
        /// True from the start of each tick until the event handler took its last event.
        in_callback: bool,
        /// The `now_ns` that the last tick of the package left. A tick of the program changes it.
        now_ns_last: u64,
        poller: rotor.Poller,
        events: [constants.events_per_tick]rotor.Event,

        const This = @This();
        const callbacks = run_module.Callbacks(This);

        pub const Options = struct {
            /// The fibers, at most `constants.fibers_max`.
            count: u16 = 256,
            /// The bytes of each stack, with its guard page, 256 KiB by default: a whole number of
            /// `constants.stack_granule_bytes`, from `constants.stack_bytes_min` to
            /// `constants.stack_bytes_max`.
            stack_bytes: u32 = 262_144,
            /// Takes each event that a tick returns and no record of the package takes. With
            /// null, such an event halts.
            event_handler: ?EventHandler = null,
        };

        pub const InitError = error{ SystemResources, PollersFull };

        /// The bytes of memory that `init` needs for `options`.
        pub fn memory_bytes(options: *const Options) usize {
            return memory_module.memory_bytes(options.count, options.stack_bytes);
        }

        /// The most operations that the package holds in flight: one for each fiber, and one for
        /// the main context. The program adds it to the `operations` of its reactor.
        pub fn operations(options: *const Options) u32 {
            memory_module.check(options.count, options.stack_bytes);
            return @as(u32, options.count) + 1;
        }

        /// Starts the value in place, on the thread that owns `reactor`. `memory` holds at least
        /// `memory_bytes(options)` bytes, and stays the package's until `deinit`. `rest` runs each
        /// call that the package does not run. From here until `deinit`, only the package ticks
        /// `reactor`. When the reactor read no clock yet, `init` ticks it once with a wait of 0.
        pub fn init(
            fibers: *This,
            reactor: *Reactor,
            memory: []align(memory_alignment) u8,
            rest: Io,
            options: *const Options,
        ) InitError!void {
            // `carve` halts when `memory` is shorter than `memory_bytes(options)`.
            const layout = memory_module.carve(memory, options.count, options.stack_bytes);
            fibers.* = .{
                .reactor = reactor,
                .rest = rest,
                .event_handler = options.event_handler,
                .lists = undefined,
                .layout = layout,
                .stack_bytes = options.stack_bytes,
                .thread = run_module.thread_id(),
                .resumes = 0,
                .in_callback = false,
                .now_ns_last = reactor.now_ns(),
                .poller = .init(This, "poller", callbacks.on_poll),
                .events = undefined,
            };
            const completion: rotor.Completion = .init(Fiber, "completion", callbacks.on_event);
            for (layout.fibers) |*fiber| fiber.* = .empty(fibers, completion);
            fibers.lists = .init(layout.fibers);
            try memory_module.protect(&layout, options.stack_bytes);
            errdefer memory_module.unprotect(&layout, options.stack_bytes);
            try reactor.add_poller(&fibers.poller);
            if (reactor.now_ns() == 0) run_module.first_tick(fibers);
        }

        /// Ends the value. It halts while a fiber is in use: each future and each `Io.Group` is
        /// awaited or canceled first. The program then owns the reactor's `tick` again.
        pub fn deinit(fibers: *This) void {
            if (fibers.thread != run_module.thread_id()) @panic(run_module.another_thread);
            if (fibers.in_callback) @panic(run_module.deinit_in_callback);
            // Each fiber is free, so the main context runs, and no list but the free list holds a
            // context.
            for (fibers.lists.fibers[1..]) |*fiber| assert(fiber.state == .free);
            fibers.reactor.remove_poller(&fibers.poller);
            memory_module.unprotect(&fibers.layout, fibers.stack_bytes);
            fibers.* = undefined;
        }

        /// The `std.Io` of the value. Each call of it comes from the reactor's thread.
        pub fn io(fibers: *This) Io {
            return .{ .userdata = fibers, .vtable = &vtable };
        }

        const vtable = table(This);
    };
}

/// The calls that the package runs itself, each named as the field of `Io.VTable` that it fills.
fn Own(comptime This: type) type {
    const tasks = tasks_module.Tasks(This);
    const groups = groups_module.Groups(This);
    const wait = wait_module.Wait(This);
    const lookup = lookup_module.Lookup(This);
    return struct {
        pub const async = tasks.async_task;
        pub const concurrent = tasks.concurrent;
        pub const await = tasks.await_task;
        pub const cancel = tasks.cancel;
        pub const groupAsync = groups.group_async;
        pub const groupConcurrent = groups.group_concurrent;
        pub const groupAwait = groups.group_await;
        pub const groupCancel = groups.group_cancel;
        pub const recancel = tasks.recancel;
        pub const swapCancelProtection = tasks.swap_cancel_protection;
        pub const checkCancel = tasks.check_cancel;
        pub const futexWait = wait.futex_wait_call;
        pub const futexWaitUncancelable = wait.futex_wait_uncancelable_call;
        pub const futexWake = wait.futex_wake_call;
        pub const now = wait.now;
        pub const sleep = wait.sleep_call;
        pub const netLookup = lookup.net_lookup;
    };
}

/// The calls of the package at step 1 of the build order (decision 34, "Which calls run where").
pub const own_calls = 17;

/// The fields of `Io.VTable` at Zig 0.16.0 (decision 34, "Upkeep").
pub const table_calls = 109;

/// Each call of `Io.VTable`: the package's own where `Own` names it, and the forwarder to `rest`
/// otherwise.
fn table(comptime This: type) Io.VTable {
    const own = Own(This);
    const rest = rest_module.Rest(This);
    // Each call of the package's own fills a field of the table. A Zig upgrade that renames a call
    // stops the build here, and does not drop the call.
    for (@typeInfo(own).@"struct".decls) |declaration| {
        if (!@hasField(Io.VTable, declaration.name)) {
            @compileError("tejedor: no field of std.Io.VTable is named " ++ declaration.name);
        }
    }
    var result: Io.VTable = undefined;
    for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        @field(result, field.name) = if (@hasDecl(own, field.name))
            &@field(own, field.name)
        else
            rest.forwarder(field.name);
    }
    return result;
}

/// The count of the calls that `Own` names, for the test of the table.
pub fn own_count(comptime This: type) usize {
    return @typeInfo(Own(This)).@"struct".decls.len;
}
