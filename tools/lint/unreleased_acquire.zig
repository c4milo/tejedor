//! unreleased-acquire: a descriptor that a function takes with `try` and that no statement of its
//! block releases, while a statement under it can still fail. When that statement returns its
//! error, the function loses the descriptor. `defer_order.zig` reads the order of a cleanup that
//! exists. This rule finds an acquire with no cleanup.
//!
//! The rule reads names and not types, so the acquire list is its whole precision. The list holds
//! the four calls of rotor's `sync` namespace that hand back a descriptor, at the rotor tag that
//! `build.zig.zon` pins. `close_now` releases each one, and the default `close` prefix of the rule
//! covers that call. The list writes each call out. A shorter entry, such as `open`, would also
//! report a call that returns flags and owns nothing.
//!
//! Three switches are on, as in rotor's configuration:
//!
//! - `read_assignments`: `slot.* = try open_socket(...)` is an acquire of `slot`;
//! - `read_subscript_targets`: `sockets[index] = try open_socket(...)` is an acquire of `sockets`;
//! - `read_loop_reentry`: an acquire that ends the body of a loop is a finding, when the loop
//!   does not release it. The next turn takes another descriptor, and no name holds the last one.
//!
//! The scope is `bench/` alone, as rotor's is. A program there that opens a socket calls
//! `rotor.sync`. The tests under `src/` are outside the scope. A test can close a descriptor on
//! purpose and then check that a call refuses it, and a `defer` cannot cover that shape. A wider
//! scope is Camilo's choice.
//!
//! At step 0 of the build order, no program opens a descriptor, so the rule has no finding to
//! report yet. The canary of `build/lint.zig` proves that it runs.
//!
//! The rule is pepegrillo's `unreleased_acquire`. This file holds tejedor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const unreleased_acquire = lint.rules.unreleased_acquire;

/// The calls of `rotor.sync` that hand back a descriptor, which the block must close.
const acquires = [_][]const u8{
    "open_socket",
    "open_datagram",
    "open_file",
    "listen",
};

pub const config: unreleased_acquire.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"bench"},
    },
    .acquire_prefixes = &acquires,
    .read_assignments = true,
    .read_loop_reentry = true,
    .read_subscript_targets = true,
};

const Rule = unreleased_acquire.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

/// The finding of the rule for a lost `socket`. The harness matches the whole text.
const socket_message = "socket is acquired here and a statement under it can fail," ++
    " and no defer releases socket";

/// The finding for a descriptor that a function assigns through `client`.
const client_message = "client is acquired here and a statement under it can fail," ++
    " and no defer releases client";

/// The finding for a descriptor that a function assigns into `sockets`.
const sockets_message = "sockets is acquired here and a statement under it can fail," ++
    " and no defer releases sockets";

/// The finding for listeners that a loop opens and no statement above the loop releases.
const listeners_message = "listeners is acquired here and a statement under it can fail," ++
    " and no defer releases listeners";

test "unreleased-acquire passes a descriptor that an errdefer closes" {
    try expect_findings("bench/echo.zig",
        \\pub fn connect_one(address: *const Address) !Descriptor {
        \\    const socket = try rotor.sync.open_socket(address.family);
        \\    errdefer rotor.sync.close_now(socket);
        \\    try connect_now(socket, address);
        \\    return socket;
        \\}
    , &.{});
}

test "unreleased-acquire reports each call of rotor.sync that hands back a descriptor" {
    try expect_findings("bench/echo.zig",
        \\pub fn connect_all(address: *const Address) !void {
        \\    const socket = try rotor.sync.open_socket(.ipv4);
        \\    try connect_now(socket, address);
        \\}
    , &.{socket_message});
    try expect_findings("bench/echo.zig",
        \\pub fn bind(address: *const Address) !void {
        \\    const socket = try rotor.sync.open_datagram(address, .{});
        \\    try check(socket);
        \\}
    , &.{socket_message});
    try expect_findings("bench/echo.zig",
        \\pub fn read(path: [*:0]const u8) !void {
        \\    const socket = try rotor.sync.open_file(path, .{});
        \\    try check(socket);
        \\}
    , &.{socket_message});
    try expect_findings("bench/echo.zig",
        \\pub fn serve(address: *const Address) !void {
        \\    const socket = try rotor.sync.listen(address, .{});
        \\    try check(socket);
        \\}
    , &.{socket_message});
}

test "unreleased-acquire does not report a call that owns nothing" {
    try expect_findings("bench/echo.zig",
        \\pub fn settings(socket: Descriptor) !Address {
        \\    const address = try rotor.sync.local_address(socket);
        \\    try check(socket);
        \\    return address;
        \\}
    , &.{});
}

test "unreleased-acquire reads bench, and does not read src or tools" {
    const leaking: [:0]const u8 =
        \\pub fn run() !void {
        \\    const socket = try open_socket(.ipv4);
        \\    try connect_now(socket, &address);
        \\}
    ;
    try expect_findings("bench/echo.zig", leaking, &.{socket_message});
    try expect_findings("src/tejedor.zig", leaking, &.{});
    try expect_findings("tools/lint/main.zig", leaking, &.{});
}

test "unreleased-acquire reads an acquire through a pointer and into an element" {
    try expect_findings("bench/echo.zig",
        \\pub fn connect_all(clients: []Descriptor) !void {
        \\    for (clients) |*client| {
        \\        client.* = try open_socket(.ipv4);
        \\        try connect_now(client.*, &address);
        \\    }
        \\}
    , &.{client_message});
    try expect_findings("bench/echo.zig",
        \\pub fn connect_all(sockets: []Descriptor) !void {
        \\    sockets[0] = try open_socket(.ipv4);
        \\    try connect_now(sockets[0], &address);
        \\}
    , &.{sockets_message});
}

test "unreleased-acquire reads an acquire that ends the body of a loop" {
    try expect_findings("bench/echo.zig",
        \\pub fn serve_all(loops: u32) !void {
        \\    var listeners: [8]Descriptor = undefined;
        \\    var opened: u32 = 0;
        \\    while (opened < loops) : (opened += 1) {
        \\        listeners[opened] = try listen(&address, .{});
        \\    }
        \\    defer for (listeners[0..loops]) |l| close_now(l);
        \\}
    , &.{listeners_message});
}
