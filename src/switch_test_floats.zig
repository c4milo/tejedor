//! The test of each floating-point register across a switch (rotor's decision 34, "Build order",
//! step 0).
//!
//! The clobber list of the switch names each floating-point register: `z0` to `z31` on aarch64,
//! and `xmm0` to `xmm15` on x86_64. A caller that holds a copy of the body of `switch_context`
//! then keeps no value in one of them across the switch. With one name out of the list, the caller
//! can keep a value in that register. The context that runs in between can then change it.
//!
//! `switch_test.zig` holds a test that keeps one `f64` sum on each side of a switch. On aarch64
//! Linux that test passed with any one of 24 names out of the list. Both sides kept the sum in
//! the same register. So each side read the sum of the other, and the two sums were equal. The
//! test of this file keeps 32 values on each side at one time, and both sides run one function.
//! So a register that holds a value of the one side across the switch holds a value of the
//! other side too.
const std = @import("std");
const switching = @import("switch.zig");
const Context = switching.Context;
const Switch = switching.Switch;
const initial_context = switching.initial_context;
const stack_end_alignment = switching.stack_end_alignment;
const supported = switching.supported;
const switch_context = switching.switch_context;

const testing = std.testing;

/// The floating-point values that one context keeps across a switch. The count is the count of
/// the vector registers of aarch64, and two times the count of the `xmm` registers of x86_64.
const values_count = 32;

/// The bytes of the fiber's stack.
const stack_bytes = 64 * 1024;

/// The switches that the test makes to the fiber.
const rounds = 64;

var stack: [stack_bytes]u8 align(stack_end_alignment) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;
var fiber_in: [values_count]f64 = undefined;
var fiber_out: [values_count]f64 = undefined;

/// Reads each value of `in`, switches with `message`, and then writes each value to `out`. Each
/// read and each write goes through a volatile pointer, so each value lives across the switch,
/// in a register or on the stack. The main context and the fiber both run this one function. It
/// calls the switch in the form of the package (`switching.call_modifier`).
noinline fn switch_with_values(
    message: *const Switch,
    in: *const volatile [values_count]f64,
    out: *volatile [values_count]f64,
) void {
    var values: [values_count]f64 = undefined;
    inline for (0..values_count) |index| values[index] = in[index];
    @call(switching.call_modifier, switch_context, .{message});
    inline for (0..values_count) |index| out[index] = values[index];
}

fn values_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    for (0..rounds) |_| switch_with_values(&to_main, &fiber_in, &fiber_out);
    unreachable;
}

test "the main context and a fiber each keep 32 floating-point values across a switch" {
    if (!supported) return error.SkipZigTest;
    var in: [values_count]f64 = undefined;
    var out: [values_count]f64 = undefined;
    for (&in, &fiber_in, 0..) |*mine, *other, index| {
        mine.* = @floatFromInt(1000 + index);
        other.* = @floatFromInt(2000 + index);
    }
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(@intFromPtr(&stack) + stack_bytes, 0, values_fiber);
    for (0..rounds) |round| {
        @memset(&out, 0);
        switch_with_values(&to_fiber, &in, &out);
        try testing.expectEqualSlices(f64, &in, &out);
        // From the second round, the fiber wrote its values after the switch back to it.
        if (round > 0) try testing.expectEqualSlices(f64, &fiber_in, &fiber_out);
    }
}
