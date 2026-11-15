//! The calls of an `Io.Group` (rotor's decision 34, "Which calls run where" and "How cancel
//! works"). Each function takes the `Fibers(Reactor)` value as `fibers`. `Groups(This)` holds the
//! calls of the table for one `Fibers(Reactor)` type, `This`.
//!
//! A member takes a free fiber, as the std task of a future does, and its fiber is free again when
//! its function returns. The group's `state` holds the count of the members that have not
//! returned, and the context that awaits them. Its `token` is the `Fibers` value, so a group that
//! another value awaits halts.
//!
//! `Group.await` waits for each member. A cancel of the context that awaits goes on to each member,
//! and the call still waits for the last member before it returns `error.Canceled`. A member
//! writes the group, so the caller must not leave before that (`std/Io.zig`, lines 1272 to 1275).
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Alignment = std.mem.Alignment;
const constants = @import("constants.zig");
const fiber_module = @import("fiber.zig");
const run = @import("run.zig");
const tasks = @import("tasks.zig");

const Index = fiber_module.Index;
const index_none = fiber_module.index_none;
const cancel_point = run.cancel_point;
const end_wait = run.end_wait;
const GroupStart = tasks.GroupStart;

/// What the package keeps in `Io.Group.state`: the members that have not returned, and the context
/// that awaits them. One word.
const GroupState = packed struct(usize) {
    members: u32,
    awaiter: Index,
    awaited: bool,
    reserved: u15 = 0,
};

fn group_state(group: *Io.Group) *GroupState {
    return @ptrCast(&group.state);
}

/// The most waits of one `Group.await`: one that a cancel ends, then one with no cancel point.
const awaits_max = 2;

fn spawn_member(fibers: anytype, context: []const u8, context_alignment: Alignment, start: *const GroupStart) ?Index {
    return tasks.spawn(fibers, &.{
        .context = context,
        .context_alignment = context_alignment,
        .result_len = 0,
        .result_alignment = .@"1",
        .function = start,
        .member = true,
    });
}

fn join(fibers: anytype, group: *Io.Group, index: Index) void {
    const state = group_state(group);
    assert(state.members < constants.fibers_max);
    fibers.lists.fibers[index].group = group;
    state.members += 1;
    group.token.store(fibers, .release);
}

/// Waits for each member. A cancel of the context that awaits goes on to each member.
fn await_members(fibers: anytype, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    assert(token == @as(*anyopaque, fibers));
    const fiber = fibers.lists.running();
    var canceled = false;
    cancel_point(fiber) catch {
        canceled = true;
        cancel_members(fibers, group);
    };
    var awaits: u32 = 0;
    while (group_state(group).members != 0) : (awaits += 1) {
        assert(awaits < awaits_max);
        wait_members(fibers, group, !canceled);
        _ = end_wait(fiber) catch {
            canceled = true;
            cancel_members(fibers, group);
        };
    }
    close(group);
    if (canceled) return error.Canceled;
}

/// Asks each member to cancel, and waits for each one. It is no cancel point.
fn cancel_group(fibers: anytype, group: *Io.Group, token: *anyopaque) void {
    assert(token == @as(*anyopaque, fibers));
    cancel_members(fibers, group);
    var awaits: u32 = 0;
    while (group_state(group).members != 0) : (awaits += 1) {
        assert(awaits < awaits_max);
        wait_members(fibers, group, false);
    }
    close(group);
}

fn wait_members(fibers: anytype, group: *Io.Group, cancelable: bool) void {
    const state = group_state(group);
    assert(!state.awaited);
    state.awaiter = fibers.lists.current;
    state.awaited = true;
    run.block(fibers, .group, cancelable);
    state.awaited = false;
}

fn cancel_members(fibers: anytype, group: *Io.Group) void {
    const records = fibers.lists.fibers;
    for (records[1..], 1..) |*fiber, index| {
        if (fiber.flags.member and fiber.group == group) tasks.request_cancel(fibers, @intCast(index));
    }
}

/// A member's fiber goes back on the free list as its function returns, as `Io.Group` promises.
/// The last member makes the context that awaits ready.
pub fn end_member(fibers: anytype, index: Index) void {
    const lists = &fibers.lists;
    const group = lists.fibers[index].group.?;
    const state = group_state(group);
    assert(state.members >= 1);
    state.members -= 1;
    if (state.members == 0 and state.awaited) {
        assert(state.awaiter != index_none);
        const awaiter = &lists.fibers[state.awaiter];
        if (awaiter.state == .blocked and awaiter.wait == .group) lists.make_ready(state.awaiter);
    }
    lists.push_free(index);
}

fn close(group: *Io.Group) void {
    assert(group_state(group).members == 0);
    group.token.store(null, .release);
    group.state = 0;
}

pub fn Groups(comptime This: type) type {
    return struct {
        pub fn group_async(
            userdata: ?*anyopaque,
            group: *Io.Group,
            context: []const u8,
            context_alignment: Alignment,
            start: *const GroupStart,
        ) void {
            const fibers = run.from(This, userdata);
            const index = spawn_member(fibers, context, context_alignment, start) orelse {
                start(context.ptr);
                return;
            };
            join(fibers, group, index);
        }

        pub fn group_concurrent(
            userdata: ?*anyopaque,
            group: *Io.Group,
            context: []const u8,
            context_alignment: Alignment,
            start: *const GroupStart,
        ) Io.ConcurrentError!void {
            const fibers = run.from(This, userdata);
            const index = spawn_member(fibers, context, context_alignment, start) orelse
                return error.ConcurrencyUnavailable;
            join(fibers, group, index);
        }

        pub fn group_await(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
            return await_members(run.from(This, userdata), group, token);
        }

        pub fn group_cancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
            cancel_group(run.from(This, userdata), group, token);
        }
    };
}
