//! A panic in a task of `std.Io.Evented`. The task runs on a fiber that std starts.
//!
//!     zig build-exe halt_in_task.zig -O ReleaseSafe
//!     ./halt_in_task; echo "exit status $?"
//!
//! Expected: the trace ends at the first frame of the fiber, and the process ends with SIGABRT
//! (status 134), as a panic on the main thread does.
const std = @import("std");

pub fn main() !void {
    var evented: std.Io.Evented = undefined;
    try evented.init(std.heap.page_allocator, .{});
    // No `deinit`: the task halts first. `Dispatch.deinit` of Zig 0.16.0 does not compile.
    const io = evented.io();
    var future = io.async(halt_here, .{});
    future.await(io);
}

noinline fn halt_here() void {
    @panic("a panic in a task");
}
