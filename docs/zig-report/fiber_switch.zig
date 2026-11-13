const std = @import("std");
const builtin = @import("builtin");
const fiber = std.Io.fiber;

var stack: [64 * 1024]u8 align(16) = undefined;
var main_context: fiber.Context = undefined;
var fiber_context: fiber.Context = undefined;
var to_fiber: fiber.Switch = undefined;
var to_main: fiber.Switch = undefined;
var mail: usize = 0; // the address of the data that a fiber reads

/// Starts a fiber at `entry`, which takes its data from `mail` and never returns.
fn start(entry: *const fn () callconv(.c) noreturn, data: usize) void {
    mail = data;
    const end = @intFromPtr(&stack) + stack.len;
    fiber_context = switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = end, .fp = 0, .pc = @intFromPtr(entry) },
        .x86_64 => .{ .rsp = end - 8, .rbp = 0, .rip = @intFromPtr(entry) },
        else => @compileError("aarch64 and x86_64 only"),
    };
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
}

// message: x1 or rsi holds 0 when the function with the switch starts.
fn switch_function(s: *const fiber.Switch) callconv(.c) void {
    _ = fiber.contextSwitch(s);
}
fn clear_then_switch() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("mov x1, xzr\n b %[f]"
            :
            : [f] "X" (&switch_function),
        ),
        .x86_64 => asm volatile ("xorl %%esi, %%esi\n jmp %[f:P]"
            :
            : [f] "X" (&switch_function),
        ),
        else => unreachable,
    }
}
fn switch_cleared(s: *const fiber.Switch) void {
    const call: *const fn (*const fiber.Switch) callconv(.c) void = @ptrCast(&clear_then_switch);
    call(s);
}
fn message_fiber() callconv(.c) noreturn {
    while (true) switch_cleared(&to_main);
}
fn message() bool {
    start(&message_fiber, 0);
    switch_cleared(&to_fiber);
    return true;
}

// counting: a loop counter on each side.
fn counting_fiber() callconv(.c) noreturn {
    const count: *usize = @ptrFromInt(mail);
    for (0..100_000) |_| {
        count.* += 1;
        _ = fiber.contextSwitch(&to_main);
    }
    unreachable;
}
fn counting() bool {
    var count: usize = 0;
    start(&counting_fiber, @intFromPtr(&count));
    for (1..100_001) |round| {
        _ = fiber.contextSwitch(&to_fiber);
        if (count != round) return false;
    }
    return true;
}

// float: an f64 sum on each side.
fn float_fiber() callconv(.c) noreturn {
    const half: *f64 = @ptrFromInt(mail);
    var sum: f64 = 0;
    for (0..64) |round| {
        sum += @as(f64, @floatFromInt(3 * round + 7)) / 2;
        half.* = sum;
        _ = fiber.contextSwitch(&to_main);
    }
    unreachable;
}
fn float() bool {
    var half: f64 = 0;
    start(&float_fiber, @intFromPtr(&half));
    var sum: f64 = 0;
    for (0..64) |round| {
        _ = fiber.contextSwitch(&to_fiber);
        sum += @as(f64, @floatFromInt(3 * round + 7)) / 2;
        if (sum != half) return false;
    }
    return true;
}

// flags: a comparison before the switch, used again after it. The fiber compares the other way.
const Flags = struct {
    left: u64,
    right: u64,
    low: u64 = 111,
    high: u64 = 999,
    before: u64 = 0,
    after: u64 = 0,
    fiber_before: u64 = 0,
    fiber_after: u64 = 0,
};
fn flags_fiber() callconv(.c) noreturn {
    const f: *volatile Flags = @ptrFromInt(mail);
    for (0..64) |_| {
        const left = f.right;
        const right = f.left;
        const low_before = f.low;
        const high_before = f.high;
        const less = left < right;
        f.fiber_before = if (less) low_before else high_before;
        _ = fiber.contextSwitch(&to_main);
        const low = f.low;
        const high = f.high;
        f.fiber_after = if (less) low else high;
    }
    unreachable;
}
noinline fn flags_round(f: *volatile Flags) void {
    const left = f.left;
    const right = f.right;
    const low_before = f.low;
    const high_before = f.high;
    const less = left < right;
    f.before = if (less) low_before else high_before;
    _ = fiber.contextSwitch(&to_fiber);
    const low = f.low;
    const high = f.high;
    f.after = if (less) low else high;
}
fn flags() bool {
    var storage: Flags = .{ .left = 1, .right = 2 };
    const f: *volatile Flags = &storage;
    start(&flags_fiber, @intFromPtr(f));
    for (0..64) |round| {
        f.left = 1 + round % 2;
        f.right = 2 - round % 2;
        flags_round(f);
        if (f.after != @as(u64, if (round % 2 == 0) 111 else 999)) return false;
    }
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(std.heap.page_allocator);
    const name = if (args.len == 2) args[1] else "";
    const ok = if (std.mem.eql(u8, name, "message"))
        message()
    else if (std.mem.eql(u8, name, "counting"))
        counting()
    else if (std.mem.eql(u8, name, "float"))
        float()
    else if (std.mem.eql(u8, name, "flags"))
        flags()
    else
        std.process.exit(2);
    std.debug.print("{s}: {s}\n", .{ name, if (ok) "PASS" else "FAIL" });
    if (!ok) std.process.exit(1);
}
