//! The lists of the contexts of one `Fibers` value: the free list, the ready list, the futex list
//! and the slot list (rotor's decision 34, "The ready list and the tick"). Each list links the
//! records through `Fiber.next`, and a context is on one list at most. So `count + 1` bounds each
//! list, and each walk of a list asserts that bound.
//!
//! - The free list holds each fiber with no std task. The first std task takes fiber 1.
//! - The ready list holds each context that can run, in the order in which each became ready.
//! - The futex list holds each context in a futex wait, in the order of the waits.
//! - The slot list holds each context that waits for a free slot of a full reactor. After each
//!   tick, each of them goes to the end of the ready list, in order.
//!
//! The lists compare indices alone, and order nothing by an address (non-negotiable 6).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const fiber_module = @import("fiber.zig");

const Fiber = fiber_module.Fiber;
const Index = fiber_module.Index;
const index_none = fiber_module.index_none;
const index_main = fiber_module.index_main;

/// The most steps of one walk of a list: each fiber and the main context.
const steps_max: usize = @as(usize, constants.fibers_max) + 1;

pub const Lists = struct {
    /// Index 0 is the main context, and indices 1 to `count` are the fibers.
    fibers: []Fiber,
    /// The context that runs.
    current: Index,
    ready_head: Index,
    ready_tail: Index,
    free_head: Index,
    futex_head: Index,
    futex_tail: Index,
    slot_head: Index,
    slot_tail: Index,

    /// The lists of `fibers`, whose records are each empty. The main context runs, and each fiber
    /// is free.
    pub fn init(fibers: []Fiber) Lists {
        // The main context, and at least one fiber.
        assert(fibers.len > 1);
        assert(fibers.len <= steps_max);
        var lists: Lists = .{
            .fibers = fibers,
            .current = index_main,
            .ready_head = index_none,
            .ready_tail = index_none,
            .free_head = index_none,
            .futex_head = index_none,
            .futex_tail = index_none,
            .slot_head = index_none,
            .slot_tail = index_none,
        };
        fibers[index_main].state = .running;
        // The free list runs from the lowest index up, so the first std task takes fiber 1.
        var index: Index = @intCast(fibers.len - 1);
        while (index >= 1) : (index -= 1) lists.push_free(index);
        return lists;
    }

    /// The record of the context that runs.
    pub fn running(lists: *const Lists) *Fiber {
        return &lists.fibers[lists.current];
    }

    /// Clears the record of fiber `index`, and puts it first on the free list.
    pub fn push_free(lists: *Lists, index: Index) void {
        assert(index != index_main);
        const fiber = &lists.fibers[index];
        fiber.reset();
        fiber.next = lists.free_head;
        lists.free_head = index;
    }

    /// Takes the first fiber off the free list, or returns null when each fiber holds a std task.
    pub fn take_free(lists: *Lists) ?Index {
        const index = lists.free_head;
        if (index == index_none) return null;
        const fiber = &lists.fibers[index];
        assert(fiber.state == .free);
        lists.free_head = fiber.next;
        fiber.next = index_none;
        return index;
    }

    /// Puts context `index` at the end of the ready list. A new std task is free before it is
    /// ready, and each other context is blocked.
    pub fn make_ready(lists: *Lists, index: Index) void {
        const fiber = &lists.fibers[index];
        assert(fiber.state == .blocked or (fiber.state == .free and index != index_main));
        assert(fiber.next == index_none);
        fiber.state = .ready;
        if (lists.ready_tail == index_none) {
            lists.ready_head = index;
        } else {
            lists.fibers[lists.ready_tail].next = index;
        }
        lists.ready_tail = index;
    }

    /// True when a context is ready.
    pub fn any_ready(lists: *const Lists) bool {
        return lists.ready_head != index_none;
    }

    /// Takes the first context off the ready list, and marks it as the context that runs next.
    pub fn pop_ready(lists: *Lists) Index {
        const index = lists.ready_head;
        assert(index != index_none);
        const fiber = &lists.fibers[index];
        assert(fiber.state == .ready);
        lists.ready_head = fiber.next;
        if (lists.ready_head == index_none) lists.ready_tail = index_none;
        fiber.next = index_none;
        fiber.state = .running;
        return index;
    }

    /// Puts the running context at the end of the futex list, for a wait on `address`.
    pub fn push_futex(lists: *Lists, address: usize) void {
        const index = lists.current;
        const fiber = &lists.fibers[index];
        assert(fiber.next == index_none);
        assert(fiber.previous == index_none);
        fiber.futex_address = address;
        fiber.previous = lists.futex_tail;
        if (lists.futex_tail == index_none) {
            lists.futex_head = index;
        } else {
            lists.fibers[lists.futex_tail].next = index;
        }
        lists.futex_tail = index;
    }

    /// Takes context `index` off the futex list, which holds it. It reads no other context than
    /// its two neighbours, so a record can call it.
    pub fn unlink_futex(lists: *Lists, index: Index) void {
        const fiber = &lists.fibers[index];
        assert(fiber.previous != index_none or lists.futex_head == index);
        assert(fiber.next != index_none or lists.futex_tail == index);
        if (fiber.previous == index_none) {
            lists.futex_head = fiber.next;
        } else {
            lists.fibers[fiber.previous].next = fiber.next;
        }
        if (fiber.next == index_none) {
            lists.futex_tail = fiber.previous;
        } else {
            lists.fibers[fiber.next].previous = fiber.previous;
        }
        fiber.next = index_none;
        fiber.previous = index_none;
    }

    /// The first context on the futex list from `start` on that waits on `address`, or
    /// `index_none`. `start` is the head of the list, or a context on it.
    pub fn next_futex(lists: *const Lists, start: Index, address: usize) Index {
        var index = start;
        var steps: usize = 0;
        while (index != index_none) : (steps += 1) {
            assert(steps < steps_max);
            const fiber = &lists.fibers[index];
            if (fiber.futex_address == address) return index;
            index = fiber.next;
        }
        return index_none;
    }

    /// Puts the running context at the end of the slot list.
    pub fn push_slot(lists: *Lists) void {
        const index = lists.current;
        assert(lists.fibers[index].next == index_none);
        if (lists.slot_tail == index_none) {
            lists.slot_head = index;
        } else {
            lists.fibers[lists.slot_tail].next = index;
        }
        lists.slot_tail = index;
    }

    /// True when a context waits for a free slot.
    pub fn any_slot(lists: *const Lists) bool {
        return lists.slot_head != index_none;
    }

    /// Takes context `index` off the slot list, which holds it.
    pub fn unlink_slot(lists: *Lists, index: Index) void {
        var previous: Index = index_none;
        var link = lists.slot_head;
        var steps: usize = 0;
        while (link != index) : (steps += 1) {
            assert(steps < steps_max);
            assert(link != index_none);
            previous = link;
            link = lists.fibers[link].next;
        }
        const after = lists.fibers[index].next;
        if (previous == index_none) {
            lists.slot_head = after;
        } else {
            lists.fibers[previous].next = after;
        }
        if (lists.slot_tail == index) lists.slot_tail = previous;
        lists.fibers[index].next = index_none;
    }

    /// Moves each context of the slot list to the end of the ready list, in order: a tick ended, so
    /// each one submits again.
    pub fn release_slots(lists: *Lists) void {
        var steps: usize = 0;
        while (lists.slot_head != index_none) : (steps += 1) {
            assert(steps < steps_max);
            const index = lists.slot_head;
            const fiber = &lists.fibers[index];
            assert(fiber.state == .blocked);
            assert(fiber.wait == .slot);
            lists.slot_head = fiber.next;
            fiber.next = index_none;
            lists.make_ready(index);
        }
        lists.slot_tail = index_none;
    }
};

const testing = std.testing;

/// The records of a test: a main context and four fibers.
const test_records = 5;

/// The records of a main context and four fibers, with no owner that a test reads.
fn records(storage: *[test_records]Fiber, owner: *u8) []Fiber {
    for (storage) |*fiber| fiber.* = .empty(owner, undefined);
    return storage;
}

test "the free list hands out the fibers from the lowest index up" {
    var owner: u8 = 0;
    var storage: [test_records]Fiber = undefined;
    var lists: Lists = .init(records(&storage, &owner));
    try testing.expectEqual(1, lists.take_free().?);
    try testing.expectEqual(2, lists.take_free().?);
    lists.push_free(1);
    try testing.expectEqual(1, lists.take_free().?);
    try testing.expectEqual(3, lists.take_free().?);
    try testing.expectEqual(4, lists.take_free().?);
    try testing.expectEqual(null, lists.take_free());
}

test "the ready list is first in, first out" {
    var owner: u8 = 0;
    var storage: [test_records]Fiber = undefined;
    var lists: Lists = .init(records(&storage, &owner));
    for ([_]Index{ 3, 1, 2 }) |index| {
        _ = lists.take_free();
        storage[index].state = .free;
    }
    lists.make_ready(3);
    lists.make_ready(1);
    lists.make_ready(2);
    try testing.expectEqual(3, lists.pop_ready());
    try testing.expectEqual(1, lists.pop_ready());
    try testing.expectEqual(2, lists.pop_ready());
    try testing.expect(!lists.any_ready());
    try testing.expectEqual(.running, storage[2].state);
}

test "the slot list keeps its order, and a release makes each context ready in that order" {
    var owner: u8 = 0;
    var storage: [test_records]Fiber = undefined;
    var lists: Lists = .init(records(&storage, &owner));
    for ([_]Index{ 2, 4, 1, 3 }) |index| {
        storage[index].state = .blocked;
        storage[index].wait = .slot;
        storage[index].next = index_none;
        lists.current = index;
        lists.push_slot();
    }
    lists.unlink_slot(4);
    lists.unlink_slot(3);
    try testing.expectEqual(1, lists.slot_tail);
    lists.release_slots();
    try testing.expect(!lists.any_slot());
    try testing.expectEqual(2, lists.pop_ready());
    try testing.expectEqual(1, lists.pop_ready());
    try testing.expect(!lists.any_ready());
}

test "the futex list keeps the order of the waits, and finds a waiter by its word" {
    var owner: u8 = 0;
    var storage: [test_records]Fiber = undefined;
    var lists: Lists = .init(records(&storage, &owner));
    const words = [_]usize{ 0, 8, 16, 8, 8 };
    for ([_]Index{ 3, 1, 4, 2 }) |index| {
        storage[index].next = index_none;
        lists.current = index;
        lists.push_futex(words[index]);
    }
    // The order of the waits is 3, 1, 4, 2, and 3, 1 and 4 wait on the word at 8.
    try testing.expectEqual(3, lists.next_futex(lists.futex_head, 8));
    try testing.expectEqual(1, lists.next_futex(storage[3].next, 8));
    try testing.expectEqual(4, lists.next_futex(storage[1].next, 8));
    lists.unlink_futex(4);
    try testing.expectEqual(index_none, lists.next_futex(storage[1].next, 8));
    try testing.expectEqual(2, lists.next_futex(lists.futex_head, 16));
    try testing.expectEqual(index_none, lists.next_futex(lists.futex_head, 24));
    // The head and the tail leave the list as each other context does.
    lists.unlink_futex(3);
    lists.unlink_futex(2);
    try testing.expectEqual(1, lists.futex_head);
    try testing.expectEqual(1, lists.futex_tail);
    lists.unlink_futex(1);
    try testing.expectEqual(index_none, lists.futex_head);
    try testing.expectEqual(index_none, lists.futex_tail);
}
