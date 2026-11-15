//! The halt scenarios of `initial_context` in `src/switch.zig`, which a mistake of the caller
//! reaches with the end of a stack (CLAUDE.md, "Tests are proved by mutation"). The build takes
//! `src/switch.zig` as a module of its own, `switch`, because the module `tejedor` exports no name
//! of that file.
const std = @import("std");
const switching = @import("switch");
const scenario = @import("scenario.zig");

fn never(argument: usize) callconv(.withStackAlign(.c, switching.stack_end_alignment)) noreturn {
    _ = argument;
    @panic("halt scenario: a fiber of no switch ran");
}

/// The bytes of the stack of the scenario. The first context of each architecture writes at most
/// seven words below the end of a stack.
const stack_bytes = 256;

var stack: [stack_bytes]u8 align(switching.stack_end_alignment) = undefined;

/// An end 8 bytes past a multiple of 16. With the check deleted, the first context writes its
/// words inside `stack`, and returns.
fn an_end_not_aligned() void {
    const end = @intFromPtr(&stack) + stack_bytes - @sizeOf(usize);
    scenario.reached_violation();
    std.mem.doNotOptimizeAway(switching.initial_context(end, 0, never));
}

/// An end of 0. With the check deleted, the subtraction below the end overflows, and the process
/// halts with the text of an overflow, which is not the text of the check.
fn an_end_of_zero() void {
    scenario.reached_violation();
    std.mem.doNotOptimizeAway(switching.initial_context(0, 0, never));
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "switch: a stack end that is not aligned", .run = an_end_not_aligned, .expected = scenario.assertion },
    .{ .name = "switch: a stack end of 0", .run = an_end_of_zero, .expected = scenario.assertion },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
