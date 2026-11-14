//! The forms and the shapes that the probe of the context switch measures. `switch_probe.zig` is
//! the entry of the probe, and this file is a piece of it.
//!
//! A form is how a caller gets the switch:
//!
//! - `copy`: each caller holds a copy of the switch. It is the form of the package on aarch64.
//! - `call`: each caller calls a function that holds the switch. It is the form of the package on
//!   x86_64.
//! - `jump`: each caller calls the candidate of `jump_switch.zig`, on x86_64 alone (record 5).
//!
//! The probe gets the form of the package with a plain call of `switch_context`. It gets the other
//! form from `switch_other_form` on aarch64 (record 5), and from `std_switch_x86_64.zig` on x86_64.
//!
//! A shape is where the switch is:
//!
//! - `loop`: in the loop that the probe times, and in the loop of the fiber.
//! - `one_function`: in one function that both sides call. It is never inlined, and it returns
//!   after the switch.
//! - `two_functions`: in a function of each side, which is never inlined and returns after the
//!   switch. The two differ by one `nop`, so an optimized build cannot merge them into one.
//!
//! The shape matters for the prediction of a return. A processor predicts each return from a stack
//! of the return addresses of the calls that it saw. After a switch, a return can go to an address
//! that the other context pushed, and the processor then predicts it wrong. Record 5 gives the
//! count of such returns for each form and shape, and the numbers that test it.
const std = @import("std");
const builtin = @import("builtin");
const measure = @import("measure.zig");
const switching = @import("switch");
const jumping = @import("jump_switch.zig");
const std_switch = @import("std_switch_x86_64.zig");

pub const Form = enum {
    copy,
    call,
    jump,

    /// The words of the report for the form.
    pub fn text(form: Form) []const u8 {
        return switch (form) {
            .copy => "with a copy of the switch in the caller",
            .call => "with a call of the switch",
            .jump => "with a call of the jump candidate",
        };
    }
};

pub const Shape = enum {
    loop,
    one_function,
    two_functions,

    /// The words of the report for the shape.
    pub fn text(shape: Shape) []const u8 {
        return switch (shape) {
            .loop => "in the loop",
            .one_function => "in one function that both sides call",
            .two_functions => "in a function of each side",
        };
    }
};

/// The form of the package on this architecture (record 3).
pub const package_form: Form = switch (builtin.cpu.arch) {
    .x86_64 => .call,
    else => .copy,
};

/// The form of the package, the other form, and the candidate where it runs. The report gives the
/// form of the package first.
pub const forms = if (jumping.supported)
    [_]Form{ package_form, other_form, .jump }
else
    [_]Form{ package_form, other_form };

const other_form: Form = switch (package_form) {
    .copy => .call,
    .call => .copy,
    .jump => unreachable,
};

pub const shapes = [_]Shape{ .loop, .one_function, .two_functions };

/// The most rows of a report: each form in each shape.
pub const rows_max = @typeInfo(Form).@"enum".fields.len * shapes.len;

comptime {
    std.debug.assert(forms.len * shapes.len <= rows_max);
}

/// What one run of one form in one shape gives.
pub const Outcome = struct {
    form: Form,
    shape: Shape,
    pair: measure.PairSummary,
    /// The times that the fiber ran, and the switches that the main context made to it.
    returns: u64,
    switches: u64,

    /// False when the numbers describe something other than the switch.
    pub fn measured(outcome: *const Outcome) bool {
        if (outcome.returns != outcome.switches) return false;
        if (outcome.pair.first.median_ns < measure.sanity_floor_ns) return false;
        return outcome.pair.second.median_ns >= measure.sanity_floor_ns;
    }
};

/// The outcome of each form in each shape, in the order of the report.
pub const Outcomes = struct {
    rows: [rows_max]Outcome = undefined,
    count: usize = 0,

    pub fn slice(outcomes: *const Outcomes) []const Outcome {
        return outcomes.rows[0..outcomes.count];
    }

    pub fn measured(outcomes: *const Outcomes) bool {
        for (outcomes.slice()) |*outcome| {
            if (!outcome.measured()) return false;
        }
        return outcomes.count > 0;
    }
};

/// Runs each form in each shape with the plan, one after the other, in the order of `forms` and
/// `shapes`. The order is fixed, so a drift of the machine during a run can fall on one row more
/// than on another (`bench/README.md`).
pub fn run_each(run_plan: measure.Plan, values: *const [3][]f64) Outcomes {
    var outcomes: Outcomes = .{};
    inline for (forms) |form| {
        inline for (shapes) |shape| {
            outcomes.rows[outcomes.count] = Run(form, shape).run(run_plan, values);
            outcomes.count += 1;
        }
    }
    return outcomes;
}

/// The bytes of the fiber's stack. The fiber runs one function that keeps two words, so a small
/// stack is enough. A static array keeps the probe free of an allocator.
const stack_bytes = 64 * 1024;

var fiber_stack: [stack_bytes]u8 align(switching.stack_end_alignment) = undefined;

/// The side of a switch: the main context, or the fiber.
const Side = enum { main, fiber };

/// The types and the switch of one form.
fn Way(comptime form: Form) type {
    return switch (form) {
        .copy, .call => struct {
            const Context = switching.Context;
            const Switch = switching.Switch;
            const initial_context = switching.initial_context;

            inline fn switch_once(message: *const Switch) void {
                if (form == package_form) {
                    switching.switch_context(message);
                } else if (builtin.cpu.arch == .x86_64) {
                    std_switch.switch_copied(message);
                } else {
                    switching.switch_other_form(message);
                }
            }

            /// The address to resume at that a switch saved in `context`.
            fn resume_address(context: *const Context) usize {
                return switch (builtin.cpu.arch) {
                    .aarch64 => context.pc,
                    .x86_64 => context.rip,
                    else => @compileError("no fiber switch for this architecture"),
                };
            }
        },
        .jump => struct {
            const Context = jumping.Context;
            const Switch = jumping.Switch;
            const initial_context = jumping.initial_context;
            const resume_address = jumping.resume_address;

            inline fn switch_once(message: *const Switch) void {
                jumping.jump(message);
            }
        },
    };
}

/// The functions of the shapes `one_function` and `two_functions`, for one form in one shape.
/// Each is never inlined, and returns after its switch.
fn Functions(comptime form: Form, comptime shape: Shape) type {
    const Types = Way(form);
    return struct {
        /// The shape of these functions. The struct names it, so each shape has a type of its own,
        /// with functions and a count of its own.
        const of_shape = shape;

        /// The returns of a function of the shape after its switch, on both sides. Only a test
        /// build counts them, so the probe times no count.
        var returns: u64 = 0;

        /// The shape `one_function`: both sides call it. After the switch, the empty block of
        /// assembly keeps a call of the switch a call. So this function returns after the switch,
        /// in each form.
        noinline fn switch_and_return(message: *const Types.Switch) void {
            Types.switch_once(message);
            asm volatile ("" ::: .{ .memory = true });
            if (builtin.is_test) returns += 1;
        }

        /// The shape `two_functions`, on the main context. It is the same as `switch_and_return`.
        noinline fn switch_on_main(message: *const Types.Switch) void {
            Types.switch_once(message);
            asm volatile ("" ::: .{ .memory = true });
            if (builtin.is_test) returns += 1;
        }

        /// The shape `two_functions`, on the fiber. Its block of assembly holds one `nop`, so its
        /// code differs from the code of `switch_on_main`.
        noinline fn switch_on_fiber(message: *const Types.Switch) void {
            Types.switch_once(message);
            asm volatile ("nop" ::: .{ .memory = true });
            if (builtin.is_test) returns += 1;
        }
    };
}

/// The fiber and the two loops for one form in one shape.
fn Run(comptime form: Form, comptime shape: Shape) type {
    return struct {
        const Types = Way(form);

        /// The two contexts, and the two messages between them.
        const Switcher = struct {
            main_context: Types.Context = undefined,
            fiber_context: Types.Context = undefined,
            to_fiber: Types.Switch = undefined,
            to_main: Types.Switch = undefined,
            /// The times that the fiber ran. The probe checks that each switch reached it.
            returns: u64 = 0,
            /// The address to resume at of the fiber after the run, which a test reads. The jump
            /// candidate keeps it on the stack of the fiber, and the next run uses that stack.
            fiber_resumed: usize = 0,
            /// For a call, the return address of the call of the switch on each side, which a test
            /// reads. A side reads the other while the other waits at its switch. `run` reads the
            /// fiber after the run. The fiber reads the main context each time that it runs.
            fiber_caller: usize = 0,
            main_caller: usize = 0,
        };

        var switcher: Switcher align(@alignOf(Switcher)) = .{};

        const Shaped = Functions(form, shape);

        /// The function that holds the switch of each side, in a shape with functions.
        const on_main = if (shape == .two_functions)
            Shaped.switch_on_main
        else
            Shaped.switch_and_return;
        const on_fiber = if (shape == .two_functions)
            Shaped.switch_on_fiber
        else
            Shaped.switch_and_return;

        /// One switch on `side`, in the shape.
        inline fn step(message: *const Types.Switch, comptime side: Side) void {
            if (shape == .loop) {
                Types.switch_once(message);
            } else if (side == .main) {
                on_main(message);
            } else {
                on_fiber(message);
            }
        }

        /// The whole life of the fiber: it switches back each time that the main context switches
        /// to it. After the last sample the main context does not switch to it again. So it stays
        /// at its switch until the process ends, and the function never returns.
        fn fiber_main(
            argument: usize,
        ) callconv(.withStackAlign(.c, switching.stack_end_alignment)) noreturn {
            const state: *Switcher = @ptrFromInt(argument);
            while (true) {
                state.returns += 1;
                read_caller(form, &state.main_caller, &state.main_context);
                step(&state.to_main, .fiber);
            }
        }

        const Loops = struct {
            state: *Switcher,

            pub fn run_first(loops: *Loops, batch: u32) void {
                for (0..batch) |_| nothing(&loops.state.returns);
            }

            pub fn run_second(loops: *Loops, batch: u32) void {
                for (0..batch) |_| step(&loops.state.to_fiber, .main);
            }
        };

        /// Starts a new fiber at the end of `fiber_stack`, and times the two loops. A fiber that
        /// an earlier run started is never resumed again, so its stack is free.
        fn run(run_plan: measure.Plan, values: *const [3][]f64) Outcome {
            const state = &switcher;
            state.* = .{};
            Shaped.returns = 0;
            state.to_fiber = .{ .old = &state.main_context, .new = &state.fiber_context };
            state.to_main = .{ .old = &state.fiber_context, .new = &state.main_context };
            state.fiber_context = Types.initial_context(
                @intFromPtr(&fiber_stack) + stack_bytes,
                @intFromPtr(state),
                fiber_main,
            );
            var loops: Loops = .{ .state = state };
            const pair = measure.sample_pairs(Loops, &loops, run_plan, values);
            state.fiber_resumed = Types.resume_address(&state.fiber_context);
            read_caller(form, &state.fiber_caller, &state.fiber_context);
            return .{
                .form = form,
                .shape = shape,
                .pair = pair,
                .returns = state.returns,
                .switches = run_plan.operations(),
            };
        }
    };
}

/// The baseline: a call that does nothing, and that is never inlined. The volatile read keeps
/// the call in the loop.
noinline fn nothing(returns: *u64) void {
    const value: *volatile u64 = returns;
    _ = value.*;
}

/// The return address of the call of `switch_called` that saved `context`, which a test reads.
/// `switch_called` keeps a frame pointer, and the switch saves it. The word above that frame
/// pointer is the return address of the call. Debug and ReleaseSafe keep frame pointers.
fn caller_of(context: *const switching.Context) usize {
    const frame_pointer = switch (builtin.cpu.arch) {
        .aarch64 => context.fp,
        .x86_64 => context.rbp,
        else => @compileError("no fiber switch for this architecture"),
    };
    const frame: *const [2]usize = @ptrFromInt(frame_pointer);
    return frame[1];
}

/// In a test build, for a call, writes the return address of the call of the switch that saved
/// `context` into `caller`. In the probe it is no code, so the probe times no read.
inline fn read_caller(comptime form: Form, caller: *usize, context: *const Way(form).Context) void {
    if (builtin.is_test and form == .call) caller.* = caller_of(context);
}

const testing = std.testing;

/// The most bytes from the start of a function that holds a switch, or a call of it, to the
/// address that the switch saves.
const function_bytes_max = 4096;

/// The function that a call of the switch calls: `switch_context` on x86_64, and
/// `switch_other_form` on aarch64.
fn called_switch_start() usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => @intFromPtr(&switching.switch_context),
        else => @intFromPtr(&switching.switch_other_form),
    };
}

/// The start of the function of `starts` that holds `address`: the greatest start at or below it.
/// Functions do not overlap, so that is the function, when `address` is in one of them.
fn owner_of(address: usize, starts: []const usize) usize {
    var owner: usize = 0;
    for (starts) |start| {
        if (start <= address and start > owner) owner = start;
    }
    return owner;
}

/// `address` is in the function that starts at `start`, of the functions of `starts`.
fn expect_in(address: usize, start: usize, starts: []const usize) !void {
    const owner = owner_of(address, starts);
    try testing.expectEqual(start, owner);
    try testing.expect(address - owner < function_bytes_max);
}

/// A switch saved `resumed` on a side whose function starts at `side`. For a call, that address
/// is in the function of the call. For a copy, it is in the function of the side. For the jump
/// candidate it is the return address of the call of `jump_switch`, so it is in the function of
/// the side too.
fn expect_side(comptime form: Form, resumed: usize, side: usize, starts: []const usize) !void {
    const expected = switch (form) {
        .call => called_switch_start(),
        .copy, .jump => side,
    };
    try expect_in(resumed, expected, starts);
}

/// The start of the function that holds the switch of `side` in `Run(form, shape)`, or its call of
/// the switch. In the shape `loop` the main context switches in the code of
/// `measure.sample_pairs`, which has no address here.
fn side_start(comptime form: Form, comptime shape: Shape, comptime side: Side) ?usize {
    const R = Run(form, shape);
    if (shape == .loop) return if (side == .fiber) @intFromPtr(&R.fiber_main) else null;
    return if (side == .main) @intFromPtr(&R.on_main) else @intFromPtr(&R.on_fiber);
}

/// The start of each function that the probe names. These are the function that a call of the
/// switch calls, and the fiber and the functions of the sides of each row. `owner_of` gives an
/// address to the nearest start below it. So each function that can hold a switch is in the list,
/// and a switch in the wrong one of them fails the test.
fn probe_starts() [1 + 3 * forms.len * shapes.len]usize {
    var starts: [1 + 3 * forms.len * shapes.len]usize = @splat(0);
    starts[0] = called_switch_start();
    var index: usize = 1;
    inline for (forms) |form| {
        inline for (shapes) |shape| {
            const R = Run(form, shape);
            starts[index] = @intFromPtr(&R.fiber_main);
            starts[index + 1] = @intFromPtr(&R.on_main);
            starts[index + 2] = @intFromPtr(&R.on_fiber);
            index += 3;
        }
    }
    return starts;
}

/// After a run, the fiber of `Run(form, shape)` waits at its last switch, and the main context
/// holds the address of its own last switch. Each address shows the form and the function of its
/// side. For a call, the return address of the call of the switch shows the function of the side.
/// So a row that runs another form or another function than its label fails here. In the shape
/// `loop`, the main context switches in the code of `measure.zig`, which has no address here. So
/// the test checks the form alone there. A call saves the address in `switch_called` that the
/// fiber of the call in the loop saved too, and a copy saves another one. In the shape
/// `two_functions`, the two sides also have two functions, and the compiler merged none.
/// The jump candidate keeps the address of the main context on the stack of the test. Later calls
/// write over it, so the test reads the fiber alone for the candidate.
fn expect_form(comptime form: Form, comptime shape: Shape) !void {
    const R = Run(form, shape);
    const starts = probe_starts();
    const fiber_start = side_start(form, shape, .fiber).?;
    try expect_side(form, R.switcher.fiber_resumed, fiber_start, &starts);
    if (form == .call) try expect_in(R.switcher.fiber_caller, fiber_start, &starts);
    if (form == .jump) return;
    const main_resumed = R.Types.resume_address(&R.switcher.main_context);
    const main_start = side_start(form, shape, .main) orelse {
        const called_resumed = Run(.call, .loop).switcher.fiber_resumed;
        return testing.expectEqual(form == .call, main_resumed == called_resumed);
    };
    try expect_side(form, main_resumed, main_start, &starts);
    if (form == .call) try expect_in(R.switcher.main_caller, main_start, &starts);
    if (shape == .two_functions) try testing.expect(main_start != fiber_start);
}

/// Each row ran the switch the number of times of the plan.
fn expect_counts(outcomes: *const Outcomes) !void {
    for (outcomes.slice(), 0..) |outcome, index| {
        try testing.expectEqual(forms[index / shapes.len], outcome.form);
        try testing.expectEqual(shapes[index % shapes.len], outcome.shape);
        try testing.expectEqual(@as(u64, 6000), outcome.switches);
        try testing.expectEqual(@as(u64, 6000), outcome.returns);
        try testing.expect(outcome.measured());
    }
}

test "each form in each shape: the fiber runs one time for each switch, and both loops take time" {
    if (!switching.supported) return error.SkipZigTest;
    var storage: [3][4]f64 = undefined;
    const values: [3][]f64 = .{ &storage[0], &storage[1], &storage[2] };
    // A batch of 1,000 takes many steps of the clock, also for the loop of the empty function.
    const small: measure.Plan = .{ .warmup = 2, .samples = 4, .batch = 1000 };
    const outcomes = run_each(small, &values);
    try testing.expectEqual(forms.len * shapes.len, outcomes.count);
    try testing.expectEqual(package_form, outcomes.rows[0].form);
    // Each shape of the enum is measured.
    try testing.expectEqual(@typeInfo(Shape).@"enum".fields.len, shapes.len);
    try expect_counts(&outcomes);
    // In a shape with functions, the main context returned from its function after each of its
    // 6,000 switches. The fiber returned after each but its last, where it stays.
    inline for (forms) |form| {
        try testing.expectEqual(0, Functions(form, .loop).returns);
        try testing.expectEqual(2 * 6000 - 1, Functions(form, .one_function).returns);
        try testing.expectEqual(2 * 6000 - 1, Functions(form, .two_functions).returns);
        inline for (shapes) |shape| try expect_form(form, shape);
    }
}

test "the form of the package is a copy on aarch64 and a call on x86_64, as in record 3" {
    const expected: Form = switch (builtin.cpu.arch) {
        .x86_64 => .call,
        else => .copy,
    };
    try testing.expectEqual(expected, package_form);
}

test "the jump candidate is a form of the probe on x86_64 alone" {
    const has_jump = std.mem.indexOfScalar(Form, &forms, .jump) != null;
    try testing.expectEqual(jumping.supported, has_jump);
    try testing.expect(forms[0] != forms[1]);
}
