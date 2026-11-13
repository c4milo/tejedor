//! The machine that a probe ran on, as rows of the Markdown table that a report starts with. A
//! measured number names its machine, so each run says where it ran. The file is rotor's
//! `bench/costs/machine.zig` at rotor's `b2bcf60`, with the load average added and the cache
//! sizes left out.
//!
//! On macOS the facts come from `sysctl`. On Linux they come from `/proc` and from `sysinfo`.
//! That matters where the processor is not the same two times: a hosted runner gives the
//! processor that its pool has. On each other system this file prints what `uname` knows.
//!
//! The load average is the system's own. In a container it is the load of the Linux kernel of the
//! virtual machine. It does not count the work of the host beside that virtual machine.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const Writer = std.Io.Writer;

/// The longest text that this file reads from `sysctl`: the brand of the processor, or a version
/// of the system.
const text_bytes_max = 128;

/// The bytes of `/proc/cpuinfo` and of `/proc/meminfo` that this file reads. The model name is
/// in the block of the first processor, and `MemTotal` is the first line of the second file.
const proc_bytes_max = 4096;

/// The load averages that a system keeps: over 1, 5 and 15 minutes.
pub const load_average_count = 3;

/// Linux gives a load average as a fixed-point number with this many fraction bits
/// (`SI_LOAD_SHIFT`).
const linux_load_shift = 16;

/// Byte units, the largest first. A size prints in the largest unit that divides it.
const units = [_]struct { bytes: u64, name: []const u8 }{
    .{ .bytes = 1 << 30, .name = "GiB" },
    .{ .bytes = 1 << 20, .name = "MiB" },
    .{ .bytes = 1 << 10, .name = "KiB" },
    .{ .bytes = 1, .name = "bytes" },
};

comptime {
    // `sysctl_integer` reads an answer of 4 bytes into the low half of a u64.
    assert(builtin.cpu.arch.endian() == .little);
}

extern "c" fn getloadavg(loads: [*]f64, count: c_int) c_int;

/// Prints the rows `processor`, `system`, `Zig`, `build mode` and `date`.
pub fn print_rows(writer: *Writer) Writer.Error!void {
    try writer.writeAll("| processor | ");
    switch (builtin.os.tag) {
        .macos => try print_macos(writer),
        .linux => try print_linux(writer),
        else => try print_uname(writer),
    }
    try writer.print(" |\n| Zig | {s} |\n| build mode | {s} |\n", .{
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    try print_date(writer);
}

/// The load averages of the system over 1, 5 and 15 minutes. Null when the system gives none.
pub fn load_averages() ?[load_average_count]f64 {
    switch (builtin.os.tag) {
        .macos => {
            var loads: [load_average_count]f64 = undefined;
            if (getloadavg(&loads, load_average_count) != load_average_count) return null;
            return loads;
        },
        .linux => {
            const linux = std.os.linux;
            var info: linux.Sysinfo = undefined;
            if (linux.errno(linux.sysinfo(&info)) != .SUCCESS) return null;
            return loads_of_fixed_point(.{ info.loads[0], info.loads[1], info.loads[2] });
        },
        else => return null,
    }
}

fn loads_of_fixed_point(fixed: [load_average_count]u64) [load_average_count]f64 {
    var loads: [load_average_count]f64 = undefined;
    for (&loads, fixed) |*load, value| {
        load.* = @as(f64, @floatFromInt(value)) / (1 << linux_load_shift);
    }
    return loads;
}

fn print_macos(writer: *Writer) Writer.Error!void {
    var brand: [text_bytes_max]u8 = undefined;
    try writer.print("{s}, ", .{sysctl_text("machdep.cpu.brand_string", &brand)});
    try print_count(writer, sysctl_integer("hw.perflevel0.physicalcpu"));
    try writer.writeAll(" performance and ");
    try print_count(writer, sysctl_integer("hw.perflevel1.physicalcpu"));
    try writer.writeAll(" efficiency cores, ");
    try print_size(writer, sysctl_integer("hw.memsize"));
    var product: [text_bytes_max]u8 = undefined;
    var release: [text_bytes_max]u8 = undefined;
    try writer.print(" memory |\n| system | macOS {s}, Darwin {s}, {s}", .{
        sysctl_text("kern.osproductversion", &product),
        sysctl_text("kern.osrelease", &release),
        @tagName(builtin.cpu.arch),
    });
}

fn print_linux(writer: *Writer) Writer.Error!void {
    var buffer: [proc_bytes_max]u8 = undefined;
    const cpuinfo = read_proc("/proc/cpuinfo", &buffer) orelse "";
    // x86-64 answers `model name`. aarch64 has no such field, and answers `CPU implementer`,
    // which is a number.
    if (field_of(cpuinfo, "model name")) |model| {
        try writer.print("{s}, ", .{model});
    } else if (field_of(cpuinfo, "CPU implementer")) |implementer| {
        try writer.print("CPU implementer {s}, ", .{implementer});
    } else {
        try writer.writeAll("a processor with no name in /proc/cpuinfo, ");
    }
    try print_count(writer, std.Thread.getCpuCount() catch null);
    try writer.writeAll(" processors, ");
    var second: [proc_bytes_max]u8 = undefined;
    const meminfo = read_proc("/proc/meminfo", &second) orelse "";
    try print_size(writer, kibibytes_of(field_of(meminfo, "MemTotal")));
    try writer.writeAll(" memory |\n| system | ");
    try print_uname_system(writer);
}

fn print_uname(writer: *Writer) Writer.Error!void {
    try writer.writeAll("not read on this system |\n| system | ");
    try print_uname_system(writer);
}

fn print_uname_system(writer: *Writer) Writer.Error!void {
    const uts = posix.uname();
    try writer.print("{s} {s}, {s}", .{
        std.mem.sliceTo(&uts.sysname, 0),
        std.mem.sliceTo(&uts.release, 0),
        std.mem.sliceTo(&uts.machine, 0),
    });
}

/// The text after the first `name:` of `contents`, with no blank at either end. Null when the
/// field is not there.
fn field_of(contents: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// The start of a `/proc` file, through the system calls. Null when the file is not there.
fn read_proc(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const opened = linux.openat(linux.AT.FDCWD, path, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const descriptor: i32 = @intCast(opened);
    defer _ = linux.close(descriptor);
    const count = linux.read(descriptor, buffer.ptr, buffer.len);
    if (linux.errno(count) != .SUCCESS) return null;
    return buffer[0..count];
}

/// `MemTotal` prints as a count of kibibytes and a unit: "16384000 kB".
fn kibibytes_of(field: ?[]const u8) ?u64 {
    const text = field orelse return null;
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const count = std.fmt.parseInt(u64, text[0..end], 10) catch return null;
    return std.math.mul(u64, count, 1 << 10) catch null;
}

/// The date of the run in UTC, from the wall clock.
fn print_date(writer: *Writer) Writer.Error!void {
    var time: posix.timespec = undefined;
    const returned = posix.system.clock_gettime(.REALTIME, &time);
    assert(posix.errno(returned) == .SUCCESS);
    assert(time.sec >= 0);
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(time.sec) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print("| date | {d}-{d:0>2}-{d:0>2} (UTC) |\n", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    });
}

fn print_count(writer: *Writer, value: ?u64) Writer.Error!void {
    const count = value orelse return writer.writeAll("an unknown number of");
    try writer.print("{d}", .{count});
}

fn print_size(writer: *Writer, value: ?u64) Writer.Error!void {
    const bytes = value orelse return writer.writeAll("unknown");
    for (units) |unit| {
        if (bytes % unit.bytes != 0) continue;
        return writer.print("{d} {s}", .{ bytes / unit.bytes, unit.name });
    }
    unreachable; // The last unit is 1 byte, which divides each size.
}

fn sysctl_integer(name: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var value_bytes: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &value, &value_bytes, null, 0) != 0) return null;
    assert(value_bytes == @sizeOf(u32) or value_bytes == @sizeOf(u64));
    return value;
}

fn sysctl_text(name: [*:0]const u8, buffer: *[text_bytes_max]u8) []const u8 {
    var text_bytes: usize = buffer.len;
    if (std.c.sysctlbyname(name, buffer, &text_bytes, null, 0) != 0) return "unknown";
    assert(text_bytes <= buffer.len);
    // The kernel counts the zero at the end in the length.
    return std.mem.sliceTo(buffer[0..text_bytes], 0);
}

const testing = std.testing;

test "field_of reads the first field of a name, and gives null for a name that is not there" {
    const cpuinfo = "processor\t: 0\nmodel name\t: AMD EPYC 7763\nmodel name\t: other\n";
    try testing.expectEqualStrings("AMD EPYC 7763", field_of(cpuinfo, "model name").?);
    try testing.expectEqualStrings("0", field_of(cpuinfo, "processor").?);
    try testing.expectEqual(null, field_of(cpuinfo, "CPU implementer"));
    try testing.expectEqual(null, field_of("", "model name"));
}

test "kibibytes_of reads the count of MemTotal as bytes" {
    try testing.expectEqual(@as(?u64, 16384000 * 1024), kibibytes_of("16384000 kB"));
    try testing.expectEqual(@as(?u64, null), kibibytes_of("many kB"));
    try testing.expectEqual(@as(?u64, null), kibibytes_of(null));
}

test "a size prints in the largest unit that divides it" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try print_size(&writer, 32 << 30);
    try writer.writeAll("; ");
    try print_size(&writer, 3 << 19);
    try writer.writeAll("; ");
    try print_size(&writer, 1025);
    try writer.writeAll("; ");
    try print_size(&writer, null);
    try testing.expectEqualStrings("32 GiB; 1536 KiB; 1025 bytes; unknown", writer.buffered());
}

test "a fixed-point load of Linux becomes a load average" {
    const loads = loads_of_fixed_point(.{ 1 << 16, 3 << 15, 0 });
    try testing.expectEqual(@as(f64, 1.0), loads[0]);
    try testing.expectEqual(@as(f64, 1.5), loads[1]);
    try testing.expectEqual(@as(f64, 0.0), loads[2]);
}

test "the system gives three load averages, and none is negative" {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return error.SkipZigTest,
    }
    const loads = load_averages() orelse return error.TestUnexpectedResult;
    for (loads) |load| try testing.expect(load >= 0);
}
