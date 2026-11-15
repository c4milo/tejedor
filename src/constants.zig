//! The named limits of tejedor (rotor's decision 34, "What it keeps"). Each limit of the package
//! has its name and its doc comment here, and no limit is written inline. Camilo ruled on
//! 2026-11-14 that step 1 adds these limits, with the values of decision 34 and of rotor's
//! decision 22 (record 7).
//!
//! The limits of the reactor are rotor's, in `rotor.constants`. The package names two of them:
//! `wait_ns_max`, the longest wait of a tick, and `timeout_ns_max`, the longest timer.
const std = @import("std");
const assert = std.debug.assert;
const switching = @import("switch.zig");

/// The most fibers that one `Fibers` value holds (decision 34, question 4). The index of a context
/// is a `u16`, and the main context takes index 0. So the limit stays below the largest `u16`,
/// which names no context.
pub const fibers_max: u16 = 4096;

/// A stack is a whole number of these bytes, and each stack starts on a multiple of them. It is a
/// multiple of each page size of the hosts of the package: 4 KiB, 16 KiB and 64 KiB. So the guard
/// page at the bottom of each stack has its own page (decision 34, question 5).
pub const stack_granule_bytes: u32 = 64 * 1024;

/// The smallest stack, with its guard page: two granules (decision 34, question 5). Each stack
/// holds the arguments and the result of its std task at its top, `closure_bytes`.
pub const stack_bytes_min: u32 = 2 * stack_granule_bytes;

/// The largest stack, with its guard page. It is the value of rotor's decision 22.
pub const stack_bytes_max: u32 = 64 * 1024 * 1024;

/// The most bytes of arguments that `async`, `concurrent` and the two calls of a group copy to a
/// fiber. A std task with more runs on the caller's stack under `async`, and `concurrent` refuses
/// it (decision 34, "When the reactor is full").
pub const context_bytes_max: u32 = 1024;

/// The most bytes of result that a std task returns through its fiber. A larger result follows
/// the rule of `context_bytes_max`.
pub const result_bytes_max: u32 = 512;

/// The alignment of the arguments and of the result at the top of a stack, and the most that
/// either may ask for. It is the alignment of a stack's end, which the switch requires.
pub const closure_alignment: u32 = switching.stack_end_alignment;

/// The bytes at the top of each stack that hold the arguments and the result of its std task.
pub const closure_bytes: u32 = context_bytes_max + result_bytes_max;

/// The most switches to a fiber between two ticks (decision 34, question 13). After this count,
/// the next context that blocks or ends switches to the main context, which ticks with a wait of
/// 0. It is the value of rotor's `tasks_per_tick_max`.
pub const resumes_between_ticks_max: u32 = 64;

/// The most times that a context submits one operation to a full reactor. Between two tries the
/// context blocks until the next tick returns, and that tick has a wait of 0 (decision 34, "When
/// the reactor is full"). The value is a prior with no measurement behind it.
pub const submit_tries_max: u32 = 8;

/// The most events that one tick of the package takes from the reactor. The reactor hands the
/// other events over in the next tick.
pub const events_per_tick: u32 = 64;

/// The results that the queue of `netLookup` holds. It is the room that std's
/// `HostName.connectMany` gives its own queue. std's rule is that a lookup does not block on a
/// queue of 16 or more (decision 34, "Why `netLookup` is a wrapper").
pub const lookup_results_max: u32 = 32;

/// The least room of a queue on which a lookup of std does not block (`std/Io/net/HostName.zig`,
/// line 153).
const lookup_room_min = 16;

comptime {
    assert(fibers_max < std.math.maxInt(u16));
    assert(stack_granule_bytes % (64 * 1024) == 0);
    assert(stack_bytes_min % stack_granule_bytes == 0);
    assert(stack_bytes_max % stack_granule_bytes == 0);
    assert(stack_bytes_min < stack_bytes_max);
    assert(closure_bytes % closure_alignment == 0);
    // The closure takes a small part of the smallest stack, below its guard page.
    assert(closure_bytes < stack_bytes_min / 4);
    assert(resumes_between_ticks_max >= 1);
    assert(submit_tries_max >= 1);
    assert(events_per_tick >= 1);
    assert(lookup_results_max >= lookup_room_min);
}
