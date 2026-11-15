//! The calls that the package hands to `rest`, the `std.Io` that the program hands to `init`
//! (rotor's decision 34, "What `rest` is"). Each forwarder takes the `Fibers` value as its
//! `userdata`, checks that the reactor's thread makes the call, and calls the same field of the
//! table of `rest` with the `userdata` of `rest` (decision 34, question 15).
//!
//! The forwarders are built from `Io.VTable` at comptime. So a Zig release that adds, removes or
//! changes a call changes them with it. Each call of the package's own is named in `fibers.zig`
//! alone.
const std = @import("std");
const Io = std.Io;
const run = @import("run.zig");

/// The calls of the table, by how many parameters each takes, `userdata` included. The widest call
/// of the table of Zig 0.16.0 takes six.
const Arity = enum(usize) { one = 1, two, three, four, five, six };

/// The place of a parameter after `userdata`, which is place 0.
const Place = enum(usize) { first = 1, second, third, fourth, fifth };

fn Function(comptime name: []const u8) std.builtin.Type.Fn {
    return @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
}

/// The type of the parameter at `place` of the call `name`.
fn Parameter(comptime name: []const u8, comptime place: Place) type {
    return Function(name).params[@intFromEnum(place)].type.?;
}

/// The forwarders of one `Fibers(Reactor)` type, `This`.
pub fn Rest(comptime This: type) type {
    return struct {
        /// `rest` of the value behind `userdata`, for a call from the reactor's thread.
        fn rest_of(userdata: ?*anyopaque) Io {
            return run.from(This, userdata).rest;
        }

        /// The forwarder of the call `name` of `Io.VTable`.
        pub fn forwarder(comptime name: []const u8) @FieldType(Io.VTable, name) {
            const R = Function(name).return_type.?;
            const arity: Arity = @enumFromInt(Function(name).params.len);
            return switch (arity) {
                .one => &struct {
                    fn call(userdata: ?*anyopaque) R {
                        const rest = rest_of(userdata);
                        return @field(rest.vtable.*, name)(rest.userdata);
                    }
                }.call,
                .two => &struct {
                    fn call(userdata: ?*anyopaque, a: Parameter(name, .first)) R {
                        const rest = rest_of(userdata);
                        return @field(rest.vtable.*, name)(rest.userdata, a);
                    }
                }.call,
                .three => &struct {
                    fn call(userdata: ?*anyopaque, a: Parameter(name, .first), b: Parameter(name, .second)) R {
                        const rest = rest_of(userdata);
                        return @field(rest.vtable.*, name)(rest.userdata, a, b);
                    }
                }.call,
                .four => &struct {
                    fn call(
                        userdata: ?*anyopaque,
                        a: Parameter(name, .first),
                        b: Parameter(name, .second),
                        c: Parameter(name, .third),
                    ) R {
                        const rest = rest_of(userdata);
                        return @field(rest.vtable.*, name)(rest.userdata, a, b, c);
                    }
                }.call,
                .five => &struct {
                    fn call(
                        userdata: ?*anyopaque,
                        a: Parameter(name, .first),
                        b: Parameter(name, .second),
                        c: Parameter(name, .third),
                        d: Parameter(name, .fourth),
                    ) R {
                        const rest = rest_of(userdata);
                        return @field(rest.vtable.*, name)(rest.userdata, a, b, c, d);
                    }
                }.call,
                .six => &struct {
                    fn call(
                        userdata: ?*anyopaque,
                        a: Parameter(name, .first),
                        b: Parameter(name, .second),
                        c: Parameter(name, .third),
                        d: Parameter(name, .fourth),
                        e: Parameter(name, .fifth),
                    ) R {
                        const rest = rest_of(userdata);
                        return @field(rest.vtable.*, name)(rest.userdata, a, b, c, d, e);
                    }
                }.call,
            };
        }
    };
}
