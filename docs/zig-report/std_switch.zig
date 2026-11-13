//! Values that the caller of `std.Io.fiber.contextSwitch` keeps across the switch.
//!
//!     zig build-exe std_switch.zig -O ReleaseSafe
//!     ./std_switch <list> <case>
//!
//! The program starts one fiber on a static stack, and the main context and the fiber switch to
//! each other. Each case checks one kind of value that lives across a switch. The program prints
//! PASS or FAIL, and exits with 0 or 1. A fault ends it with a signal.
//!
//! <list> chooses the switch:
//!
//! - `std`: `std.Io.fiber.contextSwitch` itself.
//! - `copy`: a copy of std's function in this file, with std's clobber list. It is a control: it
//!   must act as `std` acts.
//! - `fixed`: the copy with the corrected list. On aarch64 the list names `lr` and `nzcv`, names
//!   `x18` where the OS does not reserve it, and does not name `x1`. On x86_64 the list names
//!   `xmm0` to `xmm15`, and does not name `rsi`.
//! - `fixed-x1`, `fixed-lr`, `fixed-x18`, `fixed-nzcv`, `fixed-xmm`: the corrected list with
//!   one correction undone.
//! - `fixed-st`: the corrected list, with `st0` to `st7` added (x86_64).
//!
//! <case> is one of: message, counting, values, float, flags, f80.
const std = @import("std");
const builtin = @import("builtin");
const fiber = std.Io.fiber;
const Context = fiber.Context;
const Switch = fiber.Switch;
const Clobbers = std.builtin.assembly.Clobbers;

const List = enum { std, copy, fixed, @"fixed-x1", @"fixed-lr", @"fixed-x18", @"fixed-nzcv", @"fixed-xmm", @"fixed-st" };
const Case = enum { message, counting, values, float, flags, f80 };

// The clobber list of std's `contextSwitch` in Zig 0.16.0, `std/Io/fiber.zig`, as data.
const std_names = switch (builtin.cpu.arch) {
    .aarch64 => [_][]const u8{
        "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",  "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
        "x16", "x17", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x30", "z0",  "z1",  "z2",
        "z3",  "z4",  "z5",  "z6",  "z7",  "z8",  "z9",  "z10", "z11", "z12", "z13", "z14", "z15", "z16", "z17", "z18",
        "z19", "z20", "z21", "z22", "z23", "z24", "z25", "z26", "z27", "z28", "z29", "z30", "z31", "p0",  "p1",  "p2",
        "p3",  "p4",  "p5",  "p6",  "p7",  "p8",  "p9",  "p10", "p11", "p12", "p13", "p14", "p15", "fpcr", "fpsr", "ffr",
        "memory",
    },
    .x86_64 => [_][]const u8{
        "rax",   "rcx",   "rdx",   "rbx",   "rsi",   "rdi",   "r8",    "r9",    "r10",   "r11",   "r12",   "r13",
        "r14",   "r15",   "mm0",   "mm1",   "mm2",   "mm3",   "mm4",   "mm5",   "mm6",   "mm7",   "zmm0",  "zmm1",
        "zmm2",  "zmm3",  "zmm4",  "zmm5",  "zmm6",  "zmm7",  "zmm8",  "zmm9",  "zmm10", "zmm11", "zmm12", "zmm13",
        "zmm14", "zmm15", "zmm16", "zmm17", "zmm18", "zmm19", "zmm20", "zmm21", "zmm22", "zmm23", "zmm24", "zmm25",
        "zmm26", "zmm27", "zmm28", "zmm29", "zmm30", "zmm31", "fpsr",  "fpcr",  "mxcsr", "rflags", "dirflag", "memory",
    },
    else => @compileError("aarch64 and x86_64 only"),
};

const xmm_names = [_][]const u8{
    "xmm0", "xmm1", "xmm2",  "xmm3",  "xmm4",  "xmm5",  "xmm6",  "xmm7",
    "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15",
};
const st_names = [_][]const u8{ "st0", "st1", "st2", "st3", "st4", "st5", "st6", "st7" };

fn set(clobbers: *Clobbers, comptime names: []const []const u8, value: bool) void {
    inline for (names) |name| @field(clobbers, name) = value;
}

/// The clobber list of each `List` but `std`.
fn clobbers_of(comptime list: List) Clobbers {
    var clobbers: Clobbers = .{};
    set(&clobbers, &std_names, true);
    if (list == .copy) return clobbers;
    const darwin = builtin.target.os.tag.isDarwin();
    switch (builtin.cpu.arch) {
        .aarch64 => {
            clobbers.x1 = list == .@"fixed-x1";
            clobbers.lr = list != .@"fixed-lr";
            clobbers.nzcv = list != .@"fixed-nzcv";
            clobbers.x18 = !darwin and list != .@"fixed-x18";
        },
        .x86_64 => {
            clobbers.rsi = list == .@"fixed-x1";
            set(&clobbers, &xmm_names, list != .@"fixed-xmm");
            set(&clobbers, &st_names, list == .@"fixed-st");
        },
        else => unreachable,
    }
    return clobbers;
}

/// std's `contextSwitch`, instruction for instruction, with the clobber list as a parameter.
inline fn context_switch(comptime clobbers: Clobbers, s: *const Switch) *const Switch {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ adr x5, 0f
            \\ ldp x4, fp, [x2]
            \\ str x5, [x0, #16]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const Switch),
            : [message_to_send] "{x1}" (s),
            : clobbers),
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const Switch),
            : [message_to_send] "{rsi}" (s),
            : clobbers),
        else => unreachable,
    };
}

/// One switch with the chosen list.
inline fn switch_with(comptime list: List, s: *const Switch) void {
    if (list == .std) {
        _ = fiber.contextSwitch(s);
    } else {
        _ = context_switch(comptime clobbers_of(list), s);
    }
}

var stack: [64 * 1024]u8 align(16) = undefined;
var main_context: Context align(@alignOf(Context)) = undefined;
var fiber_context: Context align(@alignOf(Context)) = undefined;
var to_fiber: Switch align(@alignOf(Switch)) = undefined;
var to_main: Switch align(@alignOf(Switch)) = undefined;
/// The argument of the fiber. A global, so the fiber needs no entry of its own.
var argument: usize = 0;

/// Makes `fiber_context` a new fiber that starts at `entry`. `entry` takes its argument from
/// `argument`, and it never returns.
fn start_fiber(entry: *const fn () callconv(.c) noreturn, value: usize) void {
    argument = value;
    const end = @intFromPtr(&stack) + stack.len;
    fiber_context = switch (builtin.cpu.arch) {
        .aarch64 => .{ .sp = end, .fp = 0, .pc = @intFromPtr(entry) },
        .x86_64 => context: {
            // A return address of zero, as after a call.
            const slot: *usize = @ptrFromInt(end - 8);
            slot.* = 0;
            break :context .{ .rsp = end - 8, .rbp = 0, .rip = @intFromPtr(entry) };
        },
        else => unreachable,
    };
    to_fiber = .{ .old = &main_context, .new = &fiber_context };
    to_main = .{ .old = &fiber_context, .new = &main_context };
}

var failed = false;

fn check(comptime T: type, what: []const u8, expected: T, found: T) void {
    if (expected == found) return;
    if (!failed) std.debug.print("FAIL: {s}: expected {d}, found {d}\n", .{ what, expected, found });
    failed = true;
}

const rounds = 64;
const switches_in_a_row = 100_000;

fn Cases(comptime list: List) type {
    return struct {
        // message: the switch must load its message from its argument. The trampoline clears
        // the message register, x1 or rsi, and jumps to `switch_function`, which holds the
        // switch. If the build does not load the register, the switch reads address 0.
        fn switch_function(s: *const Switch) callconv(.c) void {
            switch_with(list, s);
        }
        fn trampoline() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .aarch64 => asm volatile (
                    \\ mov x1, xzr
                    \\ b %[target]
                    :
                    : [target] "X" (&switch_function),
                ),
                .x86_64 => asm volatile (
                    \\ xorl %%esi, %%esi
                    \\ jmp %[target:P]
                    :
                    : [target] "X" (&switch_function),
                ),
                else => unreachable,
            }
        }
        fn switch_cleared(s: *const Switch) void {
            const call: *const fn (*const Switch) callconv(.c) void = @ptrCast(&trampoline);
            call(s);
        }
        fn message_fiber() callconv(.c) noreturn {
            const count: *usize = @ptrFromInt(argument);
            count.* += 1;
            switch_cleared(&to_main);
            count.* += 1;
            switch_cleared(&to_main);
            unreachable;
        }
        fn message() void {
            var count: usize = 0;
            start_fiber(&message_fiber, @intFromPtr(&count));
            switch_cleared(&to_fiber);
            check(usize, "count after the first switch", 1, count);
            switch_cleared(&to_fiber);
            check(usize, "count after the second switch", 2, count);
        }

        // counting: a counter on each side, across many switches in a row.
        fn counting_fiber() callconv(.c) noreturn {
            const count: *usize = @ptrFromInt(argument);
            for (0..switches_in_a_row) |_| {
                count.* += 1;
                switch_with(list, &to_main);
            }
            unreachable;
        }
        fn counting() void {
            var count: usize = 0;
            start_fiber(&counting_fiber, @intFromPtr(&count));
            var sum: usize = 0;
            for (1..switches_in_a_row + 1) |round| {
                switch_with(list, &to_fiber);
                check(usize, "count", round, count);
                sum += count;
            }
            check(usize, "sum", switches_in_a_row * (switches_in_a_row + 1) / 2, sum);
        }

        // values: integer locals on each side, and a value passed each way.
        const Mail = struct { to_fiber: usize = 0, to_main: usize = 0 };
        fn values_fiber() callconv(.c) noreturn {
            const mail: *Mail = @ptrFromInt(argument);
            var sum: usize = 0;
            for (0..rounds) |round| {
                sum += mail.to_fiber;
                mail.to_main = sum + round;
                switch_with(list, &to_main);
            }
            unreachable;
        }
        fn values() void {
            var mail: Mail = .{};
            start_fiber(&values_fiber, @intFromPtr(&mail));
            var sum: usize = 0;
            for (0..rounds) |round| {
                const value = 3 * round + 7;
                mail.to_fiber = value;
                switch_with(list, &to_fiber);
                sum += value;
                check(usize, "value from the fiber", sum + round, mail.to_main);
            }
        }

        // float and f80: a floating-point sum on each side. Half of an integer is exact.
        fn Halves(comptime F: type) type {
            return struct {
                const HalfMail = struct { to_fiber: usize = 0, half_to_main: F = 0 };
                fn fiber_main() callconv(.c) noreturn {
                    const mail: *HalfMail = @ptrFromInt(argument);
                    var half_sum: F = 0;
                    for (0..rounds) |_| {
                        half_sum += @as(F, @floatFromInt(mail.to_fiber)) / 2;
                        mail.half_to_main = half_sum;
                        switch_with(list, &to_main);
                    }
                    unreachable;
                }
                fn run() void {
                    var mail: HalfMail = .{};
                    start_fiber(&fiber_main, @intFromPtr(&mail));
                    var half_sum: F = 0;
                    for (0..rounds) |round| {
                        const value = 3 * round + 7;
                        mail.to_fiber = value;
                        switch_with(list, &to_fiber);
                        half_sum += @as(F, @floatFromInt(value)) / 2;
                        check(F, "sum", half_sum, mail.half_to_main);
                    }
                }
            };
        }

        // flags: a comparison before the switch decides the same way after it. Each side
        // compares the other way, so the flags of one side are wrong for the other.
        const FlagsMail = struct {
            left: u64 = 0,
            right: u64 = 0,
            before: u64 = 0,
            after: u64 = 0,
            fiber_left: u64 = 0,
            fiber_right: u64 = 0,
            fiber_before: u64 = 0,
            fiber_after: u64 = 0,
            low: u64 = 111,
            high: u64 = 999,
        };
        fn flags_fiber() callconv(.c) noreturn {
            const mail: *volatile FlagsMail = @ptrFromInt(argument);
            for (0..rounds) |_| {
                const left = mail.fiber_left;
                const right = mail.fiber_right;
                const low_before = mail.low;
                const high_before = mail.high;
                const less = left < right;
                mail.fiber_before = if (less) low_before else high_before;
                switch_with(list, &to_main);
                const low = mail.low;
                const high = mail.high;
                mail.fiber_after = if (less) low else high;
            }
            unreachable;
        }
        noinline fn flags_round(mail: *volatile FlagsMail) void {
            const left = mail.left;
            const right = mail.right;
            const low_before = mail.low;
            const high_before = mail.high;
            const less = left < right;
            mail.before = if (less) low_before else high_before;
            switch_with(list, &to_fiber);
            const low = mail.low;
            const high = mail.high;
            mail.after = if (less) low else high;
        }
        fn flags() void {
            var storage: FlagsMail = .{};
            const mail: *volatile FlagsMail = &storage;
            start_fiber(&flags_fiber, @intFromPtr(mail));
            for (0..rounds) |round| {
                mail.left = 1 + round % 2;
                mail.right = 2 - round % 2;
                mail.fiber_left = mail.right;
                mail.fiber_right = mail.left;
                flags_round(mail);
                const expected: u64 = if (round % 2 == 0) 111 else 999;
                check(u64, "choice before the switch", expected, mail.before);
                check(u64, "choice after the switch", expected, mail.after);
            }
        }

        fn run(case: Case) void {
            switch (case) {
                .message => message(),
                .counting => counting(),
                .values => values(),
                .float => Halves(f64).run(),
                .flags => flags(),
                .f80 => Halves(f80).run(),
            }
        }
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = try init.args.toSlice(std.heap.page_allocator);
    if (args.len != 3) {
        std.debug.print("usage: std_switch <list> <case>\n", .{});
        std.process.exit(2);
    }
    const list = std.meta.stringToEnum(List, args[1]) orelse std.process.exit(2);
    const case = std.meta.stringToEnum(Case, args[2]) orelse std.process.exit(2);
    switch (list) {
        inline else => |chosen| Cases(chosen).run(case),
    }
    if (failed) std.process.exit(1);
    std.debug.print("PASS\n", .{});
}
