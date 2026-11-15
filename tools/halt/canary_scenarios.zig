//! The canary of the halt check: three scenarios that do not halt as a scenario must. One breaks
//! nothing and returns. One dies before it reaches the marker. One dies with another text than
//! the text that it names. The check must report each one, so `build/halt.zig` runs it with
//! `--expect-failures 3`. This file is rotor's
//! `tools/halt/canary_scenarios.zig`, with the text that each scenario names.
const std = @import("std");
const scenario = @import("scenario.zig");

fn breaks_nothing() void {
    scenario.reached_violation();
}

fn dies_before_the_marker() void {
    @panic("canary: a death before the marker");
}

fn dies_with_another_text() void {
    scenario.reached_violation();
    @panic("canary: a death with another text");
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "canary: a scenario that breaks nothing", .run = breaks_nothing, .expected = "" },
    .{ .name = "canary: a scenario that dies before the marker", .run = dies_before_the_marker, .expected = "" },
    .{ .name = "canary: a scenario that dies with another text", .run = dies_with_another_text, .expected = "a text that no panic prints" },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
