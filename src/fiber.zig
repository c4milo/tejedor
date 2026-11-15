//! The record of one context: `Fiber` (rotor's decision 34, "How one call that blocks runs"). A
//! context is a fiber, or the main context. Index 0 is the main context, the thread's own stack,
//! and indices 1 to `count` are the fibers. Each record is in the caller's memory, which `init` of
//! `Fibers` takes.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const rotor = @import("rotor");
const switching = @import("switch.zig");

/// The index of a context among the records.
pub const Index = u16;

/// The index that names no context. It ends each list.
pub const index_none: Index = std.math.maxInt(Index);

/// The index of the main context.
pub const index_main: Index = 0;

/// Where a context is.
pub const State = enum(u8) {
    /// On the free list, with no std task. The main context is never free.
    free,
    /// On the ready list: it runs when the running context blocks or ends.
    ready,
    /// The one context that runs.
    running,
    /// It waits for what `wait` names.
    blocked,
    /// The function of a future's std task returned. The fiber holds the result until `await` or
    /// `cancel` takes it.
    finished,
};

/// What a blocked context waits for.
pub const Wait = enum(u8) {
    none,
    /// The final event of the operation that `handle` names.
    operation,
    /// A `futexWake` on `futex_address`, or the final event of the timer that `handle` names.
    futex,
    /// The end of the future that it awaits. No cancel ends this wait.
    future,
    /// The end of each member of a group.
    group,
    /// A cancel, and nothing else: a `sleep` with no timeout.
    cancel,
    /// The end of the next tick, on a full reactor (decision 34, "When the reactor is full").
    slot,
};

/// The record of one context. 88 bytes on aarch64 and 72 bytes on x86_64, aligned to 8: the saved
/// context of the switch is three words on aarch64 and one word on x86_64 (record 6).
pub const Fiber = struct {
    /// The registers of the context while it does not run.
    context: switching.Context,
    /// The record that each operation of this context names (decision 34, question 12).
    completion: rotor.Completion,
    /// The `Fibers` value that holds this record. The function of `completion` reads it.
    owner: *anyopaque,
    /// The operation in flight for this context, or `Handle.none`.
    handle: rotor.Handle,
    /// The address of the word that a futex wait waits on.
    futex_address: usize,
    /// The group of a member, or null for a future.
    group: ?*Io.Group,
    /// The function of the std task: `FutureStart` for a future, and `GroupStart` for a member.
    start: ?*const anyopaque,
    /// The result of the final event that ended the last wait, or the result of a wake.
    result: i32,
    /// The next context on the list that holds this one: the free, ready, futex or slot list.
    next: Index,
    /// The context before this one on the futex list. Only the futex list reads it, so a record
    /// takes a context off that list with no walk (non-negotiable 7).
    previous: Index,
    /// The context that awaits this future, or `index_none`.
    awaiter: Index,
    state: State,
    wait: Wait,
    flags: Flags,

    /// The cancel state of the std task, and whether it is a member. One byte.
    pub const Flags = packed struct(u8) {
        /// The std task is a member of a group, and has no future.
        member: bool = false,
        /// A cancel came for the std task.
        cancel_requested: bool = false,
        /// A cancel may end the wait in which the context blocks.
        cancelable: bool = false,
        /// A cancel ended the wait in which the context blocks.
        interrupted: bool = false,
        /// A cancel point returned `error.Canceled`. No later point returns it until `recancel`.
        acknowledged: bool = false,
        protection: Io.CancelProtection = .unblocked,
        reserved: u2 = 0,
    };

    /// A record of `owner` that holds no std task. `completion` is the record of the operations of
    /// the context.
    pub fn empty(owner: *anyopaque, completion: rotor.Completion) Fiber {
        return .{
            .context = undefined,
            .completion = completion,
            .owner = owner,
            .handle = .none,
            .futex_address = 0,
            .group = null,
            .start = null,
            .result = 0,
            .next = index_none,
            .previous = index_none,
            .awaiter = index_none,
            .state = .free,
            .wait = .none,
            .flags = .{},
        };
    }

    /// Clears the state of the last std task. The owner and the record stay.
    pub fn reset(fiber: *Fiber) void {
        assert(fiber.handle.is_none());
        fiber.* = .empty(fiber.owner, fiber.completion);
    }

    comptime {
        const size: usize = switch (@import("builtin").cpu.arch) {
            .x86_64 => 72,
            else => 88,
        };
        assert(@sizeOf(Fiber) == size);
        assert(@alignOf(Fiber) == 8);
    }
};

/// The result that a wait ends with when a cancel ended it: rotor's `canceled`.
pub const canceled_result: i32 = -@as(i32, @intFromEnum(rotor.Code.canceled));
