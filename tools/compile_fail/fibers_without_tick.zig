//! This file must not compile. `zig build test-compile-fail` builds it, and requires the message of
//! the check of `Fibers` (rotor's decision 34, step 1). The type below declares each name that the
//! package asks of a reactor's type but `tick` and `shared`, so the message names both.
const tejedor = @import("tejedor");

const NoTick = struct {
    pub const submit = {};
    pub const cancel = {};
    pub const now_ns = {};
    pub const add_poller = {};
    pub const remove_poller = {};
    pub const SharedLoop = {};
    pub const Service = {};
};

test "a type that lacks tick and shared" {
    _ = tejedor.Fibers(NoTick);
}
