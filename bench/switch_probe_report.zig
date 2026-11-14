//! The table of numbers in the report of the probe of the context switch. `switch_probe.zig` is
//! the entry of the probe, and this file is a piece of it.
//!
//! The table has three rows for each form in each shape: the switches, the empty function beside
//! them, and the first less the second. A row that measured nothing says why, where its numbers go.
const std = @import("std");
const measure = @import("measure.zig");
const probe_forms = @import("switch_probe_forms.zig");
const Form = probe_forms.Form;
const Outcome = probe_forms.Outcome;
const Outcomes = probe_forms.Outcomes;
const Writer = std.Io.Writer;

/// Under these many nanoseconds the report prints two decimals, or one.
const two_decimals_under_ns = 10;
const one_decimal_under_ns = 100;

/// The words of the report for the place of a form beside the form of the package.
fn role_text(form: Form) []const u8 {
    if (form == probe_forms.package_form) return "the form of the package";
    return "a form to compare with";
}

pub fn print_numbers(
    writer: *Writer,
    report_plan: measure.Plan,
    outcomes: *const Outcomes,
) Writer.Error!void {
    try writer.writeAll("| what one sample times | median, ns | p99, ns | least, ns |\n" ++
        "|---|---:|---:|---:|\n");
    for (outcomes.slice()) |*outcome| try print_row(writer, outcome);
    try writer.print("\nEach sample is the time of a batch of {d} operations, divided by {d}." ++
        " For each row, the run kept\n{d} samples, after {d} batches whose times it threw" ++
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

/// The three rows of one form in one shape.
fn print_row(writer: *Writer, outcome: *const Outcome) Writer.Error!void {
    try writer.print("| one switch to a fiber and one switch back, {s}, {s} ({s}) | ", .{
        outcome.form.text(),
        outcome.shape.text(),
        role_text(outcome.form),
    });
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

/// The bytes of the reports that the tests print.
const test_report_bytes = 4096;

fn summary_of(median_ns: f64) measure.Summary {
    return .{ .median_ns = median_ns, .p99_ns = median_ns * 2, .least_ns = median_ns / 2 };
}

fn outcome_of(first_ns: f64, second_ns: f64, returns: u64) Outcome {
    return .{
        .form = .copy,
        .shape = .loop,
        .pair = .{
            .first = summary_of(first_ns),
            .second = summary_of(second_ns),
            .difference = summary_of(second_ns - first_ns),
        },
        .returns = returns,
        .switches = 600,
    };
}

fn outcomes_of(rows: []const Outcome) Outcomes {
    var outcomes: Outcomes = .{};
    for (rows) |row| {
        outcomes.rows[outcomes.count] = row;
        outcomes.count += 1;
    }
    return outcomes;
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "a run measured nothing when the fiber missed a switch, or a median is under a cycle" {
    try testing.expect(outcome_of(1.5, 5, 600).measured());
    try testing.expect(!outcome_of(1.5, 5, 599).measured());
    try testing.expect(!outcome_of(0.1, 5, 600).measured());
    try testing.expect(!outcome_of(1.5, 0.1, 600).measured());
    const good = outcome_of(1.5, 5, 600);
    const bad = outcome_of(1.5, 5, 599);
    try testing.expect(outcomes_of(&.{ good, good }).measured());
    try testing.expect(!outcomes_of(&.{ bad, good }).measured());
    try testing.expect(!outcomes_of(&.{ good, bad }).measured());
    try testing.expect(!outcomes_of(&.{}).measured());
}

test "the numbers print as a table of three rows for each form in each shape" {
    const small: measure.Plan = .{ .warmup = 2, .samples = 4, .batch = 100 };
    var buffer: [test_report_bytes]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    var copy = outcome_of(1.5, 12.25, 600);
    copy.form = .copy;
    var call = outcome_of(2, 250, 600);
    call.form = .call;
    call.shape = .two_functions;
    var jump = outcome_of(2, 30, 600);
    jump.form = .jump;
    const outcomes = outcomes_of(&.{ copy, call, jump });
    try print_numbers(&writer, small, &outcomes);
    const table = writer.buffered();
    try testing.expect(!contains(table, "FAILED"));
    try testing.expect(contains(table, "| one switch to a fiber and one switch back, with a" ++
        " copy of std's switch in the caller, in the loop (" ++ comptime role_text(.copy) ++
        ") | 12.3 | 24.5 | 6.13 |\n| one call of an empty function, beside those switches |" ++
        " 1.50 | 3.00 | 0.75 |\n| those switches less that call, for each sample | 10.8 | 21.5 |" ++
        " 5.38 |\n"));
    try testing.expect(contains(table, "with a call of std's switch, in a function of each" ++
        " side (" ++ comptime role_text(.call) ++ ") | 250 | 500 | 125 |"));
    try testing.expect(contains(table, "with a call of the jump, in the loop (" ++
        comptime role_text(.jump) ++ ") | 30.0 | 60.0 | 15.0 |"));
    try testing.expect(contains(table, "a batch of 100 operations"));
}

test "the form of the package and each form to compare with name their roles" {
    try testing.expectEqualStrings("the form of the package", role_text(probe_forms.package_form));
    for (probe_forms.forms[1..]) |form| {
        try testing.expectEqualStrings("a form to compare with", role_text(form));
    }
}

test "a row that measured nothing prints FAILED in its row, and under the table" {
    const small: measure.Plan = .{ .warmup = 2, .samples = 4, .batch = 100 };
    var buffer: [test_report_bytes]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    var outcomes = outcomes_of(&.{ outcome_of(1.5, 12.25, 599), outcome_of(2, 250, 600) });
    try print_numbers(&writer, small, &outcomes);
    try testing.expect(contains(
        writer.buffered(),
        "in the loop (" ++ comptime role_text(.copy) ++ ") | FAILED: the fiber ran 599 times" ++
            " for 600 switches | | |\n",
    ));
    try testing.expect(contains(writer.buffered(), "\nFAILED: the probe measured nothing"));

    writer = .fixed(&buffer);
    outcomes.rows[0] = outcome_of(1.5, 12.25, 600);
    outcomes.rows[1] = outcome_of(0.1, 250, 600);
    try print_numbers(&writer, small, &outcomes);
    try testing.expect(contains(
        writer.buffered(),
        "| FAILED: a median below is under one processor cycle | | |\n",
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
