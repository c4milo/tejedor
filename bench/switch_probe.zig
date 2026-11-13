//! The probe of the context switch (rotor's decision 34, "The fiber switch has no measured
//! cell"). It measures one switch from the main context to a fiber and one switch back, with the
//! switch of the package. A call that blocks costs one such pair beside the operation that it waits
//! for: a switch away from the fiber, and a switch back to it.
//!
//! Run:  zig build bench-switch                     # builds ReleaseSafe, and runs on this host
//!       zig build bench-switch -- --machine mac    # the report names the machine
//!
//! The probe is rotor's `bench/costs/probes/probes_fiber.zig` at rotor's `b2bcf60`, the row C26
//! that went with decision 22. These things differ:
//!
//! - That probe held a copy of the switch, as an `inline` function. This probe calls the switch of
//!   the package.
//! - That probe was one row of a table, where this one is a program.
//! - This probe measures each form of the switch in three shapes (`switch_probe_forms.zig`). The
//!   forms are a copy of the switch in the caller, and a call of a function that holds it. On
//!   x86_64 a third form is the jump candidate of `jump_switch.zig` (record 5). The shapes put the
//!   switch in the loop, in one function that both sides call, or in a function of each side. The
//!   report gives the form of the package first.
//!
//! For each form in each shape, the probe starts one fiber on a stack of its own. After that, the
//! main context and the fiber switch to each other, and nothing else runs. So the number is the
//! switch alone. It holds no ready list, no tick and no operation, which the package adds.
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
//! the numbers (`switch_probe_report.zig`). Exit status: 0 with numbers, 1 when the probe measured
//! nothing, 2 for a wrong argument.
const std = @import("std");
const posix = std.posix;
const machine = @import("machine.zig");
const measure = @import("measure.zig");
const probe_forms = @import("switch_probe_forms.zig");
const probe_report = @import("switch_probe_report.zig");
const Writer = std.Io.Writer;

/// The plan of rotor's probe: about 34 million switches out and back for each row.
const plan: measure.Plan = .{ .warmup = 64, .samples = 2000, .batch = 16384 };

/// The bytes that the report can hold. The report of nine rows, three forms in three shapes, with
/// the longest words of each row, does not fit in 4,096 bytes.
const report_bytes_max = 8192;

/// Exit statuses.
const exit_failed = 1;
const exit_usage = 2;

var sample_values: [3][plan.samples]f64 = undefined;

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
    const outcomes = probe_forms.run_each(plan, &values);

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
    outcomes: *const probe_forms.Outcomes,
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
    try probe_report.print_numbers(writer, report_plan, outcomes);
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

const testing = std.testing;

test "parse_arguments takes the name of the machine, and refuses each other argument" {
    try testing.expectEqual(@as(?[]const u8, null), try parse_arguments(&.{}));
    try testing.expectEqualStrings("mac", (try parse_arguments(&.{ "--machine", "mac" })).?);
    try testing.expectError(error.MissingMachineName, parse_arguments(&.{"--machine"}));
    try testing.expectError(error.UnknownArgument, parse_arguments(&.{"--row"}));
}

test "the report of each row of a run fits in report_bytes_max" {
    var buffer: [report_bytes_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    const facts: Facts = .{
        .machine_name = "a machine name of some length, as a person can give it",
        .placement = .qos_user_interactive,
        .clock_resolution_ns = 41,
        .loads_before = .{ 99.99, 99.99, 99.99 },
    };
    // A median under one processor cycle gives the longest row: a line of FAILED, then the
    // numbers.
    const summary: measure.Summary = .{ .median_ns = 0.1, .p99_ns = 12345.6, .least_ns = 0.05 };
    var outcomes: probe_forms.Outcomes = .{};
    for (&outcomes.rows) |*row| row.* = .{
        .form = .copy,
        .shape = .two_functions,
        .pair = .{ .first = summary, .second = summary, .difference = summary },
        .returns = 1,
        .switches = 1,
    };
    outcomes.count = outcomes.rows.len;
    try print_report(&writer, &facts, plan, &outcomes);
    try testing.expect(writer.buffered().len < report_bytes_max);
}

test {
    _ = machine;
    _ = measure;
    _ = probe_forms;
    _ = probe_report;
    _ = @import("jump_switch.zig");
}
