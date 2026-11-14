//! The test of each floating-point register across a switch (rotor's decision 34, "Build order",
//! step 0).
//!
//! On aarch64 the clobber list of the switch names each vector register, `z0` to `z31`. A caller
//! that holds a copy of the switch then keeps no value in one of them across the switch. With one
//! name out of the list, the caller can keep a value in that register. The context that runs in
//! between can then change it. On x86_64 each caller calls the jump (record 6), and the calling
//! convention covers each vector register. There the test shows that the call keeps the values.
//! `bench/std_switch_x86_64_test.zig` holds the same test for a copy of std's switch of x86_64,
//! which proves the names `xmm0` to `xmm15` of its list.
//!
//! `switch_test.zig` holds a test that keeps one `f64` sum on each side of a switch. On aarch64
//! Linux that test passed with any one of 24 names out of the list. Both sides kept the sum in
//! the same register. So each side read the sum of the other, and the two sums were equal. The
//! test of this file keeps 32 values on each side at one time, and both sides run one function.
//! So a register that holds a value of the one side across the switch holds a value of the
//! other side too.
//!
//! The second test runs on x86_64 alone, for a target with AVX-512. `zig build test` builds for
//! the processor of the host, so the test runs only on a host whose processor has AVX-512. In CI
//! that is a runner of Linux on x86-64 whose processor has it. A runner whose processor has no
//! AVX-512 skips it, and a plain `zig build test` does not show whether the test ran.
//!
//! The second test keeps masks of AVX-512 and vectors of 512 bits across the switch. With a copy
//! of std's switch, the compiler kept such a mask in `k1` across the switch. No name of the
//! clobber type of Zig 0.16.0 covers `k0` to `k7` (record 3). The calling convention makes them
//! caller-saved, so the jump keeps them. The mask of the fiber is the inverse of the mask of the
//! main context in each lane. A side can keep its mask in a register across the switch. The other
//! side then writes its own mask there, and the lanes that the first side chooses fail. The third
//! test checks those masks on each target.
const std = @import("std");
const builtin = @import("builtin");
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
/// calls `switch_context` with a plain call, as the package does.
noinline fn switch_with_values(
    message: *const Switch,
    in: *const volatile [values_count]f64,
    out: *volatile [values_count]f64,
) void {
    var values: [values_count]f64 = undefined;
    inline for (0..values_count) |index| values[index] = in[index];
    switch_context(message);
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

/// True where the target of the build has AVX-512. Only there does the compiler keep a value in a
/// mask register, `k0` to `k7`.
const has_avx512 = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);

/// The pairs of vectors that one context compares. Each vector has 16 lanes of 32 bits, the width
/// of a `zmm` register.
const pairs_count = 4;
const Lanes = @Vector(16, u32);

/// The lanes that a mask chooses between before the switch: one where the left lane is less than
/// the right lane, and two where it is not.
const less_lane: Lanes = @splat(1);
const other_lane: Lanes = @splat(2);

/// The vectors of one side: the pairs that it compares, the lanes that each mask chose before the
/// switch and after it, and the sum of each pair, which it computes before the switch and writes
/// after it. After the switch a mask chooses the lane of the sum, or zero.
const LanesMail = struct {
    left: [pairs_count]Lanes,
    right: [pairs_count]Lanes,
    before: [pairs_count]Lanes,
    after: [pairs_count]Lanes,
    sums: [pairs_count]Lanes,
};

var fiber_lanes: LanesMail align(@alignOf(LanesMail)) = undefined;

/// Reads each pair of `mail` with a volatile read, compares it lane by lane, and adds it. It writes
/// the lanes that each mask chose to `mail.before`. Then it switches with `message`, and writes the
/// lanes that each mask chooses to `mail.after`, and each sum to `mail.sums`. The pairs are dead
/// after the comparison, and the choice after the switch differs from the one before it. So the
/// compiler cannot compare again, or reuse the first choice, after the switch. Each mask and each
/// sum lives across the switch, in a register or on the stack. Both sides run this function.
noinline fn switch_with_masks(message: *const Switch, mail: *volatile LanesMail) void {
    var masks: [pairs_count]@Vector(16, bool) = undefined;
    var sums: [pairs_count]Lanes = undefined;
    inline for (0..pairs_count) |index| {
        const left = mail.left[index];
        const right = mail.right[index];
        masks[index] = left < right;
        sums[index] = left +% right;
        mail.before[index] = @select(u32, masks[index], less_lane, other_lane);
    }
    switch_context(message);
    inline for (0..pairs_count) |index| {
        mail.after[index] = @select(u32, masks[index], sums[index], @as(Lanes, @splat(0)));
        mail.sums[index] = sums[index];
    }
}

fn masks_fiber(argument: usize) callconv(.withStackAlign(.c, stack_end_alignment)) noreturn {
    _ = argument;
    for (0..rounds) |_| switch_with_masks(&to_main, &fiber_lanes);
    unreachable;
}

/// Fills the pairs of `mail` with lanes from `seed`. A lane of the mask of pair `p` is true where
/// bit `p` of the lane's index is zero, so the four masks differ. With `inverse` the left and the
/// right lanes change places, and each mask is the inverse. The main context and the fiber then
/// differ in each lane of each mask, and in each sum.
fn fill_pairs(mail: *LanesMail, seed: u32, inverse: bool) void {
    for (&mail.left, &mail.right, 0..) |*left, *right, pair| {
        var left_lanes: [16]u32 = undefined;
        var right_lanes: [16]u32 = undefined;
        for (&left_lanes, &right_lanes, 0..) |*left_lane, *right_lane, lane| {
            const value: u32 = @intCast(pair * 16 + lane);
            const own = seed +% value *% 7;
            const flipped = seed +% (value ^ (@as(u32, 1) << @intCast(pair))) *% 7;
            left_lane.* = if (inverse) flipped else own;
            right_lane.* = if (inverse) own else flipped;
        }
        left.* = left_lanes;
        right.* = right_lanes;
    }
    mail.before = @splat(@splat(0));
    mail.after = @splat(@splat(0));
    mail.sums = @splat(@splat(0));
}

fn expect_chosen(mail: *const LanesMail) !void {
    for (mail.left, mail.right, mail.before, mail.after, mail.sums) |left, right, before, after, sum| {
        const chosen: [16]u32 = @select(u32, left < right, less_lane, other_lane);
        try testing.expectEqualSlices(u32, &chosen, &@as([16]u32, before));
        const expected_sum: [16]u32 = left +% right;
        try testing.expectEqualSlices(u32, &expected_sum, &@as([16]u32, sum));
        const zero: Lanes = @splat(0);
        const chosen_sum: [16]u32 = @select(u32, left < right, left +% right, zero);
        try testing.expectEqualSlices(u32, &chosen_sum, &@as([16]u32, after));
    }
}

/// The seeds of the lanes of the main context and of the fiber.
const main_seed = 1000;
const fiber_seed = 2000;

test "the main context and a fiber each keep masks and vectors of AVX-512 across a switch" {
    if (!supported or !has_avx512) return error.SkipZigTest;
    var mail: LanesMail = undefined;
    fill_pairs(&mail, main_seed, false);
    fill_pairs(&fiber_lanes, fiber_seed, true);
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
    fiber_context = initial_context(@intFromPtr(&stack) + stack_bytes, 0, masks_fiber);
    for (0..rounds) |round| {
        mail.after = @splat(@splat(0));
        mail.sums = @splat(@splat(0));
        switch_with_masks(&to_fiber, &mail);
        try expect_chosen(&mail);
        // From the second round, the fiber chose its lanes after the switch back to it.
        if (round > 0) try expect_chosen(&fiber_lanes);
    }
}

test "the two sides of the test of AVX-512 differ in each lane of each mask and each sum" {
    var mail: LanesMail = undefined;
    var fiber_mail: LanesMail = undefined;
    fill_pairs(&mail, main_seed, false);
    fill_pairs(&fiber_mail, fiber_seed, true);
    var masks: [pairs_count]u16 = undefined;
    for (&masks, 0..) |*mask, pair| {
        const left = mail.left[pair];
        const right = mail.right[pair];
        const fiber_left = fiber_mail.left[pair];
        const fiber_right = fiber_mail.right[pair];
        mask.* = @bitCast(left < right);
        try testing.expectEqual(~mask.*, @as(u16, @bitCast(fiber_left < fiber_right)));
        try testing.expect(@reduce(.And, left +% right != fiber_left +% fiber_right));
    }
    // The four masks of one side differ too.
    try testing.expectEqual([pairs_count]u16{ 0x5555, 0x3333, 0x0F0F, 0x00FF }, masks);
}
