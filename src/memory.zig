//! The memory that `init` of `Fibers` takes, and the guard page of each stack (rotor's decision 34,
//! "Memory", and question 5).
//!
//! The program hands over one block. It holds the records first, one `Fiber` for the main context
//! and one for each fiber. The stacks follow, each `stack_bytes` long, and the first one starts on
//! the next multiple of `stack_granule_bytes`. `memory_bytes` counts one granule more for that
//! move. A static that a build aligns to a granule is not always on one: a Mach-O build placed such
//! a static at 16 KiB (rotor's decision 22). So the block needs the alignment of a record alone.
//!
//! The lowest page of each stack is its guard page. `protect` makes each guard page refuse each
//! access, so a stack that overflows faults there and ends the process (decision 34, "What it
//! cannot keep"). `unprotect` makes them readable and writable again, so the program can use the
//! block after `deinit`.
//!
//! The top of each stack holds the arguments and the result of its std task, `closure_bytes`. The
//! stack of the fiber starts below them.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const fiber_module = @import("fiber.zig");

const Fiber = fiber_module.Fiber;
const Index = fiber_module.Index;
const index_main = fiber_module.index_main;

/// The alignment of the block that `init` takes. The records need it, and the stacks move up to a
/// granule inside the block.
pub const memory_alignment = constants.closure_alignment;

comptime {
    assert(memory_alignment >= @alignOf(Fiber));
}

/// The parts of the block: the records, and the stacks.
pub const Layout = struct {
    /// Index 0 is the main context, and indices 1 to `count` are the fibers.
    fibers: []Fiber,
    /// The stack of fiber `index` is the part `index - 1` of `stack_bytes` each.
    stacks: []align(constants.stack_granule_bytes) u8,
};

/// Halts unless `count` and `stack_bytes` are in their limits.
pub fn check(count: u16, stack_bytes: u32) void {
    assert(count >= 1);
    assert(count <= constants.fibers_max);
    assert(stack_bytes >= constants.stack_bytes_min);
    assert(stack_bytes <= constants.stack_bytes_max);
    assert(stack_bytes % constants.stack_granule_bytes == 0);
}

/// The bytes of the records of `count` fibers and the main context.
fn records_bytes(count: u16) usize {
    return (@as(usize, count) + 1) * @sizeOf(Fiber);
}

/// The bytes of the block for `count` fibers of `stack_bytes`: the records, one granule for the
/// move of the stacks, then the stacks.
pub fn memory_bytes(count: u16, stack_bytes: u32) usize {
    check(count, stack_bytes);
    return records_bytes(count) + constants.stack_granule_bytes + @as(usize, count) * stack_bytes;
}

/// The records and the stacks in `memory`, which holds at least `memory_bytes` bytes.
pub fn carve(memory: []align(memory_alignment) u8, count: u16, stack_bytes: u32) Layout {
    check(count, stack_bytes);
    assert(memory.len >= memory_bytes(count, stack_bytes));
    const records_end = records_bytes(count);
    const base = @intFromPtr(memory.ptr);
    const stacks_start =
        std.mem.alignForward(usize, base + records_end, constants.stack_granule_bytes) - base;
    const stacks_bytes = @as(usize, count) * stack_bytes;
    assert(stacks_start + stacks_bytes <= memory.len);
    return .{
        .fibers = @ptrCast(@alignCast(memory[0..records_end])),
        .stacks = @alignCast(memory[stacks_start..][0..stacks_bytes]),
    };
}

/// The bytes of one page of the host. Each stack loses one page to its guard.
pub fn page_bytes() usize {
    const bytes = std.heap.pageSize();
    assert(constants.stack_granule_bytes % bytes == 0);
    return bytes;
}

/// The stack of fiber `index`, guard page included.
pub fn stack_of(layout: *const Layout, stack_bytes: u32, index: Index) []align(constants.stack_granule_bytes) u8 {
    assert(index != index_main);
    assert(index < layout.fibers.len);
    const start = (@as(usize, index) - 1) * stack_bytes;
    return @alignCast(layout.stacks[start..][0..stack_bytes]);
}

/// The bytes at the top of the stack of fiber `index` that hold the arguments of its std task.
pub fn context_bytes(layout: *const Layout, stack_bytes: u32, index: Index) []u8 {
    const stack = stack_of(layout, stack_bytes, index);
    return stack[stack_bytes - constants.context_bytes_max ..];
}

/// The bytes below the arguments that hold the result of the std task.
pub fn result_bytes(layout: *const Layout, stack_bytes: u32, index: Index) []u8 {
    const stack = stack_of(layout, stack_bytes, index);
    return stack[stack_bytes - constants.closure_bytes ..][0..constants.result_bytes_max];
}

/// The address one byte after the stack of fiber `index`: the end that its first stack pointer
/// starts from, below the arguments and the result.
pub fn stack_end(layout: *const Layout, stack_bytes: u32, index: Index) usize {
    const stack = stack_of(layout, stack_bytes, index);
    return @intFromPtr(stack.ptr) + stack_bytes - constants.closure_bytes;
}

/// Makes the guard page of each stack refuse each access. On an error of the kernel, each guard
/// page is readable and writable again, and the call returns `SystemResources`.
pub fn protect(layout: *const Layout, stack_bytes: u32) error{SystemResources}!void {
    const count = layout.fibers.len - 1;
    for (1..count + 1) |index| {
        const guard = guard_of(layout, stack_bytes, @intCast(index));
        set_protection(guard, .{}) catch |err| {
            for (1..index) |done| unprotect_one(layout, stack_bytes, @intCast(done));
            return err;
        };
    }
}

/// Makes the guard page of each stack readable and writable again.
pub fn unprotect(layout: *const Layout, stack_bytes: u32) void {
    const count = layout.fibers.len - 1;
    for (1..count + 1) |index| unprotect_one(layout, stack_bytes, @intCast(index));
}

fn unprotect_one(layout: *const Layout, stack_bytes: u32, index: Index) void {
    const guard = guard_of(layout, stack_bytes, index);
    // The kernel gave this access to the page before `protect`, so it refuses no return to it.
    set_protection(guard, .{ .READ = true, .WRITE = true }) catch
        @panic("tejedor: the kernel refused to make a guard page writable again");
}

/// The guard page of the stack of fiber `index`: its lowest page.
fn guard_of(layout: *const Layout, stack_bytes: u32, index: Index) []align(constants.stack_granule_bytes) u8 {
    return stack_of(layout, stack_bytes, index)[0..page_bytes()];
}

/// Sets the protection of `region`, a whole number of pages.
fn set_protection(region: []align(constants.stack_granule_bytes) u8, protection: std.posix.PROT) error{SystemResources}!void {
    switch (builtin.os.tag) {
        .linux => {
            const result = std.os.linux.mprotect(region.ptr, region.len, protection);
            if (std.os.linux.errno(result) != .SUCCESS) return error.SystemResources;
        },
        else => {
            if (std.c.mprotect(region.ptr, region.len, protection) != 0) return error.SystemResources;
        },
    }
}

const testing = std.testing;

test "the block holds the records, one granule, and the stacks" {
    const count = 3;
    const stack_bytes = constants.stack_bytes_min;
    const expected = (count + 1) * @sizeOf(Fiber) + constants.stack_granule_bytes + count * stack_bytes;
    try testing.expectEqual(expected, memory_bytes(count, stack_bytes));
}

test "each stack starts on a granule, and the last one ends in the block" {
    const count = 2;
    const stack_bytes = constants.stack_bytes_min;
    var block: [memory_bytes(count, stack_bytes) + memory_alignment]u8 align(memory_alignment) = undefined;
    // An offset of one alignment unit moves the records, and the stacks still fit.
    const memory: []align(memory_alignment) u8 = @alignCast(block[memory_alignment..]);
    const layout = carve(memory, count, stack_bytes);
    try testing.expectEqual(count + 1, layout.fibers.len);
    try testing.expectEqual(0, @intFromPtr(layout.stacks.ptr) % constants.stack_granule_bytes);
    try testing.expect(@intFromPtr(layout.stacks.ptr) >= @intFromPtr(layout.fibers.ptr + layout.fibers.len));
    const last = stack_of(&layout, stack_bytes, count);
    try testing.expect(@intFromPtr(last.ptr) + last.len <= @intFromPtr(memory.ptr) + memory.len);
}
