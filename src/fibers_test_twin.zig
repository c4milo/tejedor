//! The package's own twin of the loop, for its tests alone (rotor's decision 34, question 18). It
//! follows rotor's `examples/twin.zig` at v0.11.0: it declares the 28 names of the core's surface,
//! the 8 names of the port of decision 33, and a line with the 6 calls that the reactor makes on
//! it. `rotor.Reactor(Twin)` then gives the twin the records and the pollers, from the same code as
//! the host's reactor.
//!
//! The twin has no kernel. Its clock moves only in a tick: to the end of the wait, which the
//! nearest operation and the stored limit bound, and by at least 1 ns. So `now_ns` is above 0
//! after the first tick, and each tick changes it, as decision 34 asks of a twin ("What it asks of
//! a twin's behaviour"). A timer with no repeat ends at its deadline. A cancel ends an operation at
//! the next tick. Each other operation ends at the next tick with `unsupported`. The twin ignores
//! `timeout_ns`.
//!
//! The twin keeps a trace: the clock and the order of each event that it hands to the reactor.
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("rotor");

/// The operations that the twin holds in flight at most.
const operations_max = 16;

/// The events of the trace at most.
pub const trace_max = 256;

const canceled = -@as(i32, @intFromEnum(rotor.Code.canceled));
const unsupported = -@as(i32, @intFromEnum(rotor.Code.unsupported));

const no_group = "twin: the twin reserves no buffer group";

const Take = fn (context: *anyopaque, sender: rotor.LoopId, message: rotor.Message) void;
const PushError = error{ LoopNotFound, CallsFull, MailboxFull };

/// The heartbeat line of the twin. It stores nothing.
const Line = struct {
    pub fn enter(_: *Line, _: *const [:0]const u8) void {}
    pub fn leave(_: *Line, _: u64) void {}
    pub fn leave_polling(_: *Line, _: u32) void {}
    pub fn leave_tasks(_: *Line, _: u64) void {}
    pub fn leave_group_tasks(_: *Line, _: u64, _: u8) void {}
    pub fn name_poller(_: *Line, _: ?*const [:0]const u8) void {}
};

/// One operation in flight.
const Entry = struct {
    user_data: u64 = 0,
    due_ns: u64 = 0,
    result: i32 = 0,
    dispatched: bool = false,
    taken: bool = false,
    generation: u32 = 0,
    /// The order of the submit, which orders the events that are due at once.
    order: u64 = 0,
};

/// One event of the trace: the clock of the tick, and the order of the submit of its operation.
pub const Traced = struct { clock_ns: u64, order: u64, result: i32 };

pub const Twin = struct {
    clock_ns: u64,
    entries: [operations_max]Entry,
    submits: u64,
    outstanding_word: u32,
    limit: rotor.WaitLimit,
    line: Line,
    hook: ?struct { context: *anyopaque, take: *const Take },
    counts: Statistics,
    trace: [trace_max]Traced,
    trace_len: usize,
    owner: std.Thread.Id,

    pub const Options = struct {};
    pub const InitError = error{};
    pub const TickError = error{};
    pub const DrainError = TickError || error{StillInFlight};
    pub const PostError = error{ MailboxFull, LoopNotFound };
    pub const Statistics = struct { ticks: u64 = 0, events: u64 = 0 };

    pub fn memory_bytes(_: *const Options) usize {
        return 0;
    }

    pub fn init(twin: *Twin, memory: []align(rotor.memory_alignment) u8, options: *const Options) InitError!void {
        assert(memory.len >= memory_bytes(options));
        twin.* = .{
            .clock_ns = 0,
            .entries = @splat(.{}),
            .submits = 0,
            .outstanding_word = 0,
            .limit = .none,
            .line = .{},
            .hook = null,
            .counts = .{},
            .trace = undefined,
            .trace_len = 0,
            .owner = std.Thread.getCurrentId(),
        };
    }

    pub fn deinit(twin: *Twin) void {
        twin.assert_owner();
        assert(twin.in_flight() == 0);
        assert(twin.outstanding_word == 0);
        twin.* = undefined;
    }

    pub fn submit(twin: *Twin, operations: []const rotor.Operation, handles: []rotor.Handle) u32 {
        twin.assert_owner();
        assert(handles.len == 0 or handles.len == operations.len);
        for (operations, 0..) |*operation, taken| {
            const index = twin.free_index() orelse return @intCast(taken);
            const handle = twin.claim(index, operation);
            if (handles.len != 0) handles[taken] = handle;
        }
        return @intCast(operations.len);
    }

    pub fn cancel(twin: *Twin, handle: rotor.Handle) void {
        twin.assert_owner();
        assert(handle.index < operations_max);
        const entry = &twin.entries[handle.index];
        if (!entry.taken or entry.generation != handle.generation) return;
        entry.due_ns = twin.clock_ns;
        entry.result = canceled;
    }

    pub fn cancel_all(twin: *Twin) void {
        twin.assert_owner();
        for (&twin.entries) |*entry| {
            if (!entry.taken) continue;
            entry.due_ns = twin.clock_ns;
            entry.result = canceled;
        }
    }

    pub fn tick(twin: *Twin, events: []rotor.Event, wait_ns: u64) TickError!u32 {
        if (twin.outstanding_word != 0) try twin.take_kept_error();
        return twin.tick_backend(events, wait_ns);
    }

    pub fn drain(twin: *Twin, scratch: []rotor.Event) DrainError!void {
        for (0..rotor.constants.drain_rounds_max) |_| {
            if (twin.in_flight() == 0) return;
            _ = try twin.tick(scratch, rotor.constants.drain_wait_ns);
        }
        if (twin.in_flight() != 0) return error.StillInFlight;
    }

    pub fn assert_empty(twin: *const Twin) void {
        assert(twin.in_flight() == 0);
    }

    pub fn in_flight(twin: *const Twin) u32 {
        var count: u32 = 0;
        for (twin.entries) |entry| count += @intFromBool(entry.taken);
        return count;
    }

    pub fn now_ns(twin: *const Twin) u64 {
        return twin.clock_ns;
    }

    pub fn wait_limit(twin: *Twin) rotor.WaitLimit {
        twin.assert_owner();
        const until_ns = @min(twin.nearest_ns(), @intFromEnum(twin.limit));
        if (until_ns <= twin.clock_ns) return .now;
        return .at(until_ns);
    }

    pub fn wait_until(twin: *Twin, limit: rotor.WaitLimit) void {
        twin.assert_owner();
        twin.limit = limit;
    }

    pub fn heartbeat(twin: *Twin) *Line {
        twin.assert_owner();
        return &twin.line;
    }

    pub fn statistics(twin: *const Twin) *const Statistics {
        return &twin.counts;
    }

    pub fn post(twin: *Twin, target: rotor.LoopId, message: rotor.Message) PostError!void {
        twin.assert_owner();
        _ = .{ target, message };
        return error.LoopNotFound;
    }

    pub fn dropped_wakes(_: *const Twin) u64 {
        return 0;
    }

    pub fn wait_descriptor(_: *const Twin) ?rotor.Descriptor {
        return null;
    }

    pub fn register_buffers(_: *Twin, _: []const []u8) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn register_descriptors(_: *Twin, _: []const rotor.Descriptor) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn reserve_buffer_group(_: *Twin) error{BufferGroupsFull}!rotor.BufferGroup {
        return error.BufferGroupsFull;
    }
    pub fn provide_buffers(_: *Twin, _: rotor.BufferGroup, _: []align(rotor.buffers.group_alignment) u8, _: u16, _: u32) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn provide_datagram_buffers(_: *Twin, _: rotor.BufferGroup, _: []align(rotor.buffers.group_alignment) u8, _: u16, _: u32, _: rotor.datagram.GroupOptions) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn datagram(_: *const Twin, _: rotor.BufferGroup, _: rotor.Event) rotor.Delivery {
        @panic(no_group);
    }
    pub fn give_back_buffer(_: *Twin, _: rotor.BufferGroup, _: u16) void {
        @panic(no_group);
    }
    pub fn release_buffers(_: *Twin, _: rotor.BufferGroup) void {
        @panic(no_group);
    }
    pub fn provided_buffer(_: *const Twin, _: rotor.BufferGroup, _: u16) []u8 {
        @panic(no_group);
    }

    // The port of decision 33.

    pub fn tick_backend(twin: *Twin, events: []rotor.Event, wait_ns: u64) TickError!u32 {
        twin.assert_owner();
        assert(events.len != 0);
        twin.clock_ns += @max(1, twin.wait_bound(wait_ns));
        const written = twin.end_due(events);
        twin.counts.ticks += 1;
        twin.counts.events += written;
        return written;
    }
    pub fn take_kept_error(twin: *Twin) TickError!void {
        twin.assert_owner();
    }
    pub fn outstanding(twin: *Twin) *u32 {
        return &twin.outstanding_word;
    }
    pub fn stored_limit(twin: *Twin) *rotor.WaitLimit {
        return &twin.limit;
    }
    pub fn heartbeat_line(twin: *Twin) *Line {
        return &twin.line;
    }
    pub fn attach_reserved(twin: *Twin, context: *anyopaque, take: *const Take) void {
        twin.assert_owner();
        assert(twin.hook == null);
        twin.hook = .{ .context = context, .take = take };
    }
    pub fn push_reserved(twin: *Twin, target: rotor.LoopId, message: rotor.Message) PushError!*u32 {
        _ = .{ twin, target, message };
        return error.LoopNotFound;
    }
    pub fn assert_owner(twin: *const Twin) void {
        assert(twin.owner == std.Thread.getCurrentId());
    }

    fn wait_bound(twin: *const Twin, wait_ns: u64) u64 {
        const limit_ns = @min(twin.nearest_ns(), @intFromEnum(twin.limit));
        const until_ns = @min(limit_ns, twin.clock_ns +| wait_ns);
        return until_ns -| twin.clock_ns;
    }

    fn nearest_ns(twin: *const Twin) u64 {
        var nearest: u64 = std.math.maxInt(u64);
        for (twin.entries) |entry| {
            if (entry.taken) nearest = @min(nearest, entry.due_ns);
        }
        return nearest;
    }

    /// Ends each operation that is due, in the order of the submits, and writes its event.
    fn end_due(twin: *Twin, events: []rotor.Event) u32 {
        var written: u32 = 0;
        while (written < events.len) : (written += 1) {
            const entry = twin.first_due() orelse break;
            events[written] = .{
                .user_data = entry.user_data,
                .result = entry.result,
                .flags = .{ .dispatched = entry.dispatched },
            };
            entry.taken = false;
            assert(twin.trace_len < trace_max);
            twin.trace[twin.trace_len] = .{ .clock_ns = twin.clock_ns, .order = entry.order, .result = entry.result };
            twin.trace_len += 1;
        }
        return written;
    }

    /// The due operation of the first submit, or null.
    fn first_due(twin: *Twin) ?*Entry {
        var first: ?*Entry = null;
        for (&twin.entries) |*entry| {
            if (!entry.taken or entry.due_ns > twin.clock_ns) continue;
            if (first == null or entry.order < first.?.order) first = entry;
        }
        return first;
    }

    fn free_index(twin: *const Twin) ?u32 {
        for (twin.entries, 0..) |entry, index| {
            if (!entry.taken) return @intCast(index);
        }
        return null;
    }

    fn claim(twin: *Twin, index: u32, operation: *const rotor.Operation) rotor.Handle {
        const entry = &twin.entries[index];
        twin.submits += 1;
        entry.* = .{
            .user_data = operation.user_data,
            .due_ns = twin.clock_ns,
            .result = unsupported,
            .dispatched = operation.dispatched,
            .taken = true,
            .generation = entry.generation + 1,
            .order = twin.submits,
        };
        switch (operation.kind) {
            .timer => |timer| if (timer.repeat_ns == 0) {
                entry.due_ns = twin.clock_ns + timer.after_ns;
                entry.result = 0;
            },
            else => {},
        }
        return .{ .index = index, .generation = entry.generation };
    }

    /// The events that the twin handed over, in order.
    pub fn traced(twin: *const Twin) []const Traced {
        return twin.trace[0..twin.trace_len];
    }
};

comptime {
    // Each declaration of the twin compiles, also each one that no test calls.
    for (@typeInfo(Twin).@"struct".decls) |declaration| _ = &@field(Twin, declaration.name);
}
