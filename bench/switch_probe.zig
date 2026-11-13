//! The probe of the context switch (rotor's decision 34, "The fiber switch has no measured
//! cell"). It measures one switch from the main context to a fiber and one switch back, with the
//! `switch_context` of the package. A call that blocks costs one such pair beside the operation
//! that it waits for: a switch away from the fiber, and a switch back to it.
//!
//! Run:  zig build bench-switch                     # builds ReleaseSafe, and runs on this host
//!       zig build bench-switch -- --machine mac    # the report names the machine
//!
//! The probe is rotor's `bench/costs/probes/probes_fiber.zig` at rotor's `b2bcf60`, the row C26
//! that went with decision 22. Three things differ:
//!
//! - That probe held a copy of the switch, as an `inline` function. This probe calls the function
//!   of the package.
//! - That probe was one row of a table, where this one is a program.
//! - This probe measures two forms of the call. `switch_context` is an ordinary function, so the
//!   compiler decides for each caller if it calls the function or copies its body into the
//!   caller. The first form leaves that to the compiler. The second form never inlines the call.
//!   So the second form also holds the registers that the function saves and restores.
//!
//! For each form the probe starts one fiber on a stack of its own. After that, the main context
//! and the fiber switch to each other, and nothing else runs. So the number is the switch alone.
//! It holds no ready list, no tick and no operation, which the package adds.
//!
//! Each sample times two loops back to back (`measure.sample_pairs`). The first loop calls a
//! function that does nothing and is never inlined. The second loop switches to the fiber, which
//! switches back. The report gives both, and the second less the first.
//!
//! The compiler cannot remove the measured work. The fiber counts each time that it runs, and the
//! probe fails when that count differs from the count of the switches. The empty function reads
//! a volatile value, so its call stays. A median under one processor cycle also fails the probe.
//!
//! The report is Markdown on standard output: a table of the machine and the run, and a table of
//! the numbers. Exit status: 0 with numbers, 1 when the probe measured nothing, 2 for a wrong
//! argument.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const machine = @import("machine.zig");
const measure = @import("measure.zig");
const switching = @import("switch");
const Writer = std.Io.Writer;

/// The plan of rotor's probe: about 34 million switches out and back for each form.
const plan: measure.Plan = .{ .warmup = 64, .samples = 2000, .batch = 16384 };

/// The bytes of the fiber's stack. The fiber runs one function that keeps two words, so a small
/// stack is enough. A static array keeps the probe free of an allocator.
const stack_bytes = 64 * 1024;

/// The bytes that the report can hold.
const report_bytes_max = 4096;

/// Exit statuses.
const exit_failed = 1;
const exit_usage = 2;

/// Under these many nanoseconds the report prints two decimals, or one.
const two_decimals_under_ns = 10;
const one_decimal_under_ns = 100;

var fiber_stack: [stack_bytes]u8 align(switching.stack_end_alignment) = undefined;
var sample_values: [3][plan.samples]f64 = undefined;

/// The two contexts, and the two messages between them. A message names the context to save
/// into, and the context to resume.
const Switcher = struct {
    main_context: switching.Context = undefined,
    fiber_context: switching.Context = undefined,
    to_fiber: switching.Switch = undefined,
    to_main: switching.Switch = undefined,
    /// The times that the fiber ran. The probe checks that each switch to the fiber reached it.
    returns: u64 = 0,

    /// Starts a new fiber that runs `fiber`, at the end of `fiber_stack`. A fiber that an earlier
    /// `init` started is never resumed again, so its stack is free.
    fn init(switcher: *Switcher, comptime fiber: switching.Main) void {
        switcher.* = .{};
        switcher.to_fiber = .{ .old = &switcher.main_context, .new = &switcher.fiber_context };
        switcher.to_main = .{ .old = &switcher.fiber_context, .new = &switcher.main_context };
        switcher.fiber_context = switching.initial_context(
            @intFromPtr(&fiber_stack) + stack_bytes,
            @intFromPtr(switcher),
            fiber,
        );
    }
};

/// One fiber at a time: `Switcher.init` starts a new one.
var switcher_static: Switcher align(@alignOf(Switcher)) = .{};

/// The baseline: a call that does nothing, and that is never inlined. The volatile read keeps
/// the call in the loop.
noinline fn nothing(switcher: *Switcher) void {
    const returns: *volatile u64 = &switcher.returns;
    _ = returns.*;
}

/// What one run of one form gives.
const Outcome = struct {
    /// The form of the call of `switch_context` that the run used.
    modifier: std.builtin.CallModifier,
    pair: measure.PairSummary,
    /// The times that the fiber ran, and the switches that the main context made to it.
    returns: u64,
    switches: u64,

    /// False when the numbers describe something other than the switch.
    fn measured(outcome: *const Outcome) bool {
        if (outcome.returns != outcome.switches) return false;
        if (outcome.pair.first.median_ns < measure.sanity_floor_ns) return false;
        return outcome.pair.second.median_ns >= measure.sanity_floor_ns;
    }
};

/// The fiber and the two loops for one form of the call of `switch_context`. `.auto` is the call
/// as the package writes it. `.never_inline` keeps the function out of line on both sides.
fn Form(comptime modifier: std.builtin.CallModifier) type {
    return struct {
        /// The whole life of the fiber: it switches back to the main context each time that the
        /// main context switches to it. After the last sample the main context does not switch
        /// to it again. So the fiber stays at its switch until the process ends, and the function
        /// never returns.
        fn fiber_main(
            argument: usize,
        ) callconv(.withStackAlign(.c, switching.stack_end_alignment)) noreturn {
            const switcher: *Switcher = @ptrFromInt(argument);
            while (true) {
                switcher.returns += 1;
                @call(modifier, switching.switch_context, .{&switcher.to_main});
            }
        }

        const Loops = struct {
            switcher: *Switcher,

            pub fn run_first(loops: *Loops, batch: u32) void {
                for (0..batch) |_| nothing(loops.switcher);
            }

            pub fn run_second(loops: *Loops, batch: u32) void {
                for (0..batch) |_| {
                    @call(modifier, switching.switch_context, .{&loops.switcher.to_fiber});
                }
            }
        };

        fn run(run_plan: measure.Plan, values: *const [3][]f64) Outcome {
            const switcher = &switcher_static;
            switcher.init(fiber_main);
            var loops: Loops = .{ .switcher = switcher };
            const pair = measure.sample_pairs(Loops, &loops, run_plan, values);
            return .{
                .modifier = modifier,
                .pair = pair,
                .returns = switcher.returns,
                .switches = run_plan.operations(),
            };
        }
    };
}

/// The outcome of each form.
const Outcomes = struct {
    /// The compiler decided if it inlines `switch_context`.
    plain: Outcome,
    /// Each call of `switch_context` stayed out of line.
    out_of_line: Outcome,

    fn measured(outcomes: *const Outcomes) bool {
        return outcomes.plain.measured() and outcomes.out_of_line.measured();
    }
};

fn run_each_form(run_plan: measure.Plan, values: *const [3][]f64) Outcomes {
    const plain = Form(.auto).run(run_plan, values);
    const out_of_line = Form(.never_inline).run(run_plan, values);
    return .{ .plain = plain, .out_of_line = out_of_line };
}

/// What the report says about the run, beside the numbers.
const Facts = struct {
    /// The name of the machine, from `--machine`.
    machine_name: ?[]const u8,
    placement: measure.Placement,
    clock_resolution_ns: u64,
    loads_before: ?[machine.load_average_count]f64,
};

const UsageError = error{ UnknownArgument, MissingMachineName };

fn parse_arguments(arguments: []const []const u8) UsageError!?[]const u8 {
    var machine_name: ?[]const u8 = null;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        if (!std.mem.eql(u8, arguments[index], "--machine")) return error.UnknownArgument;
        index += 1;
        if (index == arguments.len) return error.MissingMachineName;
        machine_name = arguments[index];
    }
    return machine_name;
}

/// The most arguments that the probe reads: `--machine` and its name.
const arguments_max = 2;

pub fn main(init: std.process.Init.Minimal) void {
    var storage: [arguments_max][]const u8 = undefined;
    var count: usize = 0;
    var iterator = init.args.iterate();
    _ = iterator.skip();
    while (iterator.next()) |argument| {
        if (count == arguments_max) usage(error.UnknownArgument);
        storage[count] = argument;
        count += 1;
    }
    const machine_name = parse_arguments(storage[0..count]) catch |failure| usage(failure);

    const facts: Facts = .{
        .machine_name = machine_name,
        .loads_before = machine.load_averages(),
        .placement = measure.settle(),
        .clock_resolution_ns = measure.clock_resolution_ns(),
    };
    const values: [3][]f64 = .{ &sample_values[0], &sample_values[1], &sample_values[2] };
    const outcomes = run_each_form(plan, &values);

    var report_buffer: [report_bytes_max]u8 = undefined;
    var writer: Writer = .fixed(&report_buffer);
    print_report(&writer, &facts, plan, &outcomes) catch @panic("report_bytes_max is too small");
    write_all(posix.STDOUT_FILENO, writer.buffered());
    if (!outcomes.measured()) std.process.exit(exit_failed);
}

fn usage(failure: UsageError) noreturn {
    std.debug.print("error: {s}\nusage: switch_probe [--machine NAME]\n", .{@errorName(failure)});
    std.process.exit(exit_usage);
}

/// Writes each byte to the descriptor. The probe takes no `std.Io`, so it calls the system.
fn write_all(descriptor: posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const returned = posix.system.write(descriptor, bytes[written..].ptr, bytes.len - written);
        switch (posix.errno(returned)) {
            .SUCCESS => written += @intCast(returned),
            .INTR => {},
            else => @panic("the probe cannot write its report"),
        }
    }
}

fn print_report(
    writer: *Writer,
    facts: *const Facts,
    report_plan: measure.Plan,
    outcomes: *const Outcomes,
) Writer.Error!void {
    try writer.writeAll("# The probe of the context switch\n\n| | |\n|---|---|\n");
    try writer.print("| machine | {s} |\n", .{facts.machine_name orelse "no name was given"});
    try machine.print_rows(writer);
    try writer.print("| clock | {s}, with a least step of {d} ns |\n", .{
        measure.clock_name,
        facts.clock_resolution_ns,
    });
    try writer.print("| thread | {s} |\n", .{facts.placement.text()});
    try print_loads(writer, "load average before the run", facts.loads_before);
    try print_loads(writer, "load average after the run", machine.load_averages());
    try writer.writeAll("\n");
    try print_numbers(writer, report_plan, outcomes);
}

fn print_loads(
    writer: *Writer,
    label: []const u8,
    loads: ?[machine.load_average_count]f64,
) Writer.Error!void {
    const values = loads orelse return writer.print("| {s} | the system gave none |\n", .{label});
    try writer.print("| {s} | {d:.2}, {d:.2} and {d:.2}, over 1, 5 and 15 minutes |\n", .{
        label, values[0], values[1], values[2],
    });
}

fn print_numbers(
    writer: *Writer,
    report_plan: measure.Plan,
    outcomes: *const Outcomes,
) Writer.Error!void {
    try writer.writeAll("| what one sample times | median, ns | p99, ns | least, ns |\n" ++
        "|---|---:|---:|---:|\n");
    try print_form(writer, "as the compiler builds the call", &outcomes.plain);
    try print_form(writer, "with `switch_context` never inlined", &outcomes.out_of_line);
    try writer.print("\nEach sample is the time of a batch of {d} operations, divided by {d}." ++
        " For each form, the run kept\n{d} samples, after {d} batches whose times it threw" ++
        " away. The p99 is the p99 of batch means, and not\nof single operations.\n", .{
        report_plan.batch,
        report_plan.batch,
        report_plan.samples,
        report_plan.warmup,
    });
    if (!outcomes.measured()) {
        try writer.writeAll("\nFAILED: the probe measured nothing for a row above.\n");
    }
}

/// The three rows of one form. A form that measured nothing says why, where its numbers go.
fn print_form(writer: *Writer, form: []const u8, outcome: *const Outcome) Writer.Error!void {
    try writer.print("| one switch to a fiber and one switch back, {s} | ", .{form});
    if (outcome.returns != outcome.switches) {
        return writer.print("FAILED: the fiber ran {d} times for {d} switches | | |\n", .{
            outcome.returns,
            outcome.switches,
        });
    }
    if (!outcome.measured()) {
        try writer.writeAll("FAILED: a median below is under one processor cycle | | |\n| the" ++
            " same row, as it was measured | ");
    }
    try print_summary(writer, outcome.pair.second);
    try writer.writeAll("| one call of an empty function, beside those switches | ");
    try print_summary(writer, outcome.pair.first);
    try writer.writeAll("| those switches less that call, for each sample | ");
    try print_summary(writer, outcome.pair.difference);
}

fn print_summary(writer: *Writer, summary: measure.Summary) Writer.Error!void {
    try print_ns(writer, summary.median_ns);
    try writer.writeAll(" | ");
    try print_ns(writer, summary.p99_ns);
    try writer.writeAll(" | ");
    try print_ns(writer, summary.least_ns);
    try writer.writeAll(" |\n");
}

/// Nanoseconds: two decimals under 10, one under 100, and none above.
fn print_ns(writer: *Writer, nanoseconds: f64) Writer.Error!void {
    const magnitude = @abs(nanoseconds);
    if (magnitude < two_decimals_under_ns) return writer.print("{d:.2}", .{nanoseconds});
    if (magnitude < one_decimal_under_ns) return writer.print("{d:.1}", .{nanoseconds});
    return writer.print("{d:.0}", .{nanoseconds});
}

const testing = std.testing;

test "for each form, the fiber runs one time for each switch to it, and both loops take time" {
    if (!switching.supported) return error.SkipZigTest;
    var storage: [3][4]f64 = undefined;
    const values: [3][]f64 = .{ &storage[0], &storage[1], &storage[2] };
    // A batch of 1,000 takes many steps of the clock, also for the loop of the empty function.
    const small: measure.Plan = .{ .warmup = 2, .samples = 4, .batch = 1000 };
    const outcomes = run_each_form(small, &values);
    try testing.expectEqual(std.builtin.CallModifier.auto, outcomes.plain.modifier);
    try testing.expectEqual(std.builtin.CallModifier.never_inline, outcomes.out_of_line.modifier);
    for ([_]Outcome{ outcomes.plain, outcomes.out_of_line }) |outcome| {
        try testing.expectEqual(@as(u64, 6000), outcome.switches);
        try testing.expectEqual(@as(u64, 6000), outcome.returns);
        try testing.expect(outcome.measured());
    }
    // The fiber of the second form started on a new `Switcher`, so the count started at 0.
    try testing.expectEqual(@as(u64, 6000), switcher_static.returns);
}

fn summary_of(median_ns: f64) measure.Summary {
    return .{ .median_ns = median_ns, .p99_ns = median_ns * 2, .least_ns = median_ns / 2 };
}

fn outcome_of(first_ns: f64, second_ns: f64, returns: u64) Outcome {
    return .{
        .modifier = .auto,
        .pair = .{
            .first = summary_of(first_ns),
            .second = summary_of(second_ns),
            .difference = summary_of(second_ns - first_ns),
        },
        .returns = returns,
        .switches = 600,
    };
}

test "a run measured nothing when the fiber missed a switch, or a median is under a cycle" {
    try testing.expect(outcome_of(1.5, 5, 600).measured());
    try testing.expect(!outcome_of(1.5, 5, 599).measured());
    try testing.expect(!outcome_of(0.1, 5, 600).measured());
    try testing.expect(!outcome_of(1.5, 0.1, 600).measured());
    const good = outcome_of(1.5, 5, 600);
    const bad = outcome_of(1.5, 5, 599);
    try testing.expect((Outcomes{ .plain = good, .out_of_line = good }).measured());
    try testing.expect(!(Outcomes{ .plain = bad, .out_of_line = good }).measured());
    try testing.expect(!(Outcomes{ .plain = good, .out_of_line = bad }).measured());
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "the numbers print as a table of three rows for each form" {
    const small: measure.Plan = .{ .warmup = 2, .samples = 4, .batch = 100 };
    var buffer: [report_bytes_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    const outcomes: Outcomes = .{
        .plain = outcome_of(1.5, 12.25, 600),
        .out_of_line = outcome_of(2, 250, 600),
    };
    try print_numbers(&writer, small, &outcomes);
    const table = writer.buffered();
    try testing.expect(!contains(table, "FAILED"));
    try testing.expect(contains(table, "| one switch to a fiber and one switch back, as the" ++
        " compiler builds the call | 12.3 | 24.5 | 6.13 |\n| one call of an empty function," ++
        " beside those switches | 1.50 | 3.00 | 0.75 |\n| those switches less that call, for" ++
        " each sample | 10.8 | 21.5 | 5.38 |\n"));
    try testing.expect(contains(table, "with `switch_context` never inlined | 250 | 500 | 125 |"));
    try testing.expect(contains(table, "a batch of 100 operations"));
}

test "a form that measured nothing prints FAILED in its row, and under the table" {
    const small: measure.Plan = .{ .warmup = 2, .samples = 4, .batch = 100 };
    var buffer: [report_bytes_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    var outcomes: Outcomes = .{
        .plain = outcome_of(1.5, 12.25, 599),
        .out_of_line = outcome_of(2, 250, 600),
    };
    try print_numbers(&writer, small, &outcomes);
    try testing.expect(contains(
        writer.buffered(),
        "builds the call | FAILED: the fiber ran 599 times for 600 switches | | |\n",
    ));
    try testing.expect(contains(writer.buffered(), "\nFAILED: the probe measured nothing"));

    writer = .fixed(&buffer);
    outcomes.plain = outcome_of(1.5, 12.25, 600);
    outcomes.out_of_line = outcome_of(0.1, 250, 600);
    try print_numbers(&writer, small, &outcomes);
    try testing.expect(contains(
        writer.buffered(),
        "never inlined | FAILED: a median below is under one processor cycle | | |\n",
    ));
    try testing.expect(contains(writer.buffered(), "\nFAILED: the probe measured nothing"));
}

test "print_ns keeps two decimals under 10, one under 100, and none above" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try print_ns(&writer, 0.934);
    try writer.writeAll(" ");
    try print_ns(&writer, 47.26);
    try writer.writeAll(" ");
    try print_ns(&writer, 12959.4);
    try testing.expectEqualStrings("0.93 47.3 12959", writer.buffered());
}

test "parse_arguments takes the name of the machine, and refuses each other argument" {
    try testing.expectEqual(@as(?[]const u8, null), try parse_arguments(&.{}));
    try testing.expectEqualStrings("mac", (try parse_arguments(&.{ "--machine", "mac" })).?);
    try testing.expectError(error.MissingMachineName, parse_arguments(&.{"--machine"}));
    try testing.expectError(error.UnknownArgument, parse_arguments(&.{"--row"}));
}

test {
    _ = machine;
    _ = measure;
}
