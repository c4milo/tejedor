//! linux_backend: prints the name of the backend that rotor chooses in this process, `uring` or
//! `epoll`, then `supported` when a reactor of that backend starts, and `unsupported` when its
//! `init` returns `Unsupported`. tools/linux_test.sh runs it in each kind of container before the
//! tests, and requires `uring` where it relaxes the seccomp profile and `epoll` where it does not.
//! So a run of the gate that names a backend ran on it (rotor's decision 34, "Upkeep").
//!
//! This program is a developer tool. The build links no part of it into the package.
const std = @import("std");
const rotor = @import("rotor");

const Reactor = rotor.Reactor(rotor.Loop);

/// A small reactor: the tool only starts it and ends it.
const options: Reactor.Options = .{ .loop = .{ .operations = 4 } };

var memory: [Reactor.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
var reactor: Reactor align(@alignOf(Reactor)) = undefined;

pub fn main(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const started = if (reactor.init(&memory, &options)) true else |err| switch (err) {
        error.Unsupported => false,
        else => return err,
    };
    if (started) reactor.deinit();
    const support = if (started) "supported" else "unsupported";
    try writer.interface.print("{s} {s}\n", .{ @tagName(rotor.backend()), support });
    try writer.interface.flush();
}
