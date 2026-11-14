//! The way in which each form of the probe gets the switch: its types, its first context, its
//! switch, and the place where a switch saves the address to resume at. `switch_probe.zig` is the
//! entry of the probe, and this file is a piece of it.
//!
//! - The form of the package comes from the module `switch`, `src/switch.zig`, with a plain call
//!   of `switch_context`, as the package calls it. It is a copy on aarch64, and the jump on x86_64
//!   (record 6).
//! - On aarch64 the call comes from `switch_other_form` of the same module (record 5).
//! - On x86_64 the call and the copy come from `std_switch_x86_64.zig`: std's switch with the list
//!   of the package, which the package does not use.
const builtin = @import("builtin");
const switching = @import("switch");
const std_switch = @import("std_switch_x86_64.zig");
const probe_forms = @import("switch_probe_forms.zig");
const Form = probe_forms.Form;
const package_form = probe_forms.package_form;

/// The words that the jump of x86_64 pops from a context: six registers, then the address to
/// resume at. It is `resume_words` of `src/switch_jump.zig`, which is private there.
const resume_words = 7;

/// The types, the first context and the switch of one form.
pub fn Way(comptime form: Form) type {
    if (form == package_form) return struct {
        pub const Context = switching.Context;
        pub const Switch = switching.Switch;
        pub const initial_context = switching.initial_context;

        pub inline fn switch_once(message: *const Switch) void {
            switching.switch_context(message);
        }

        /// The address to resume at that a switch saved for `context`. The jump keeps it on the
        /// stack of the context, as the last word that it pops.
        pub fn resume_address(context: *const Context) usize {
            return switch (builtin.cpu.arch) {
                .aarch64 => context.pc,
                .x86_64 => {
                    const words: *const [resume_words]usize = @ptrFromInt(context.stack_pointer);
                    return words[resume_words - 1];
                },
                else => @compileError("no fiber switch for this architecture"),
            };
        }
    };
    if (builtin.cpu.arch == .x86_64) return struct {
        pub const Context = std_switch.Context;
        pub const Switch = std_switch.Switch;
        pub const initial_context = std_switch.initial_context;

        pub inline fn switch_once(message: *const Switch) void {
            switch (form) {
                .copy => std_switch.switch_copied(message),
                .call => std_switch.switch_called(message),
                .jump => @compileError("the jump is the form of the package on x86_64"),
            }
        }

        /// The address to resume at that a switch saved in `context`.
        pub fn resume_address(context: *const Context) usize {
            return context.rip;
        }
    };
    return struct {
        pub const Context = switching.Context;
        pub const Switch = switching.Switch;
        pub const initial_context = switching.initial_context;

        pub inline fn switch_once(message: *const Switch) void {
            switch (form) {
                .call => switching.switch_other_form(message),
                .copy, .jump => @compileError("the probe has no such form on aarch64"),
            }
        }

        /// The address to resume at that a switch saved in `context`.
        pub fn resume_address(context: *const Context) usize {
            return context.pc;
        }
    };
}

/// The function that a call of the switch calls: std's `switch_called` on x86_64, and
/// `switch_other_form` on aarch64.
pub fn called_switch_start() usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => @intFromPtr(&std_switch.switch_called),
        else => @intFromPtr(&switching.switch_other_form),
    };
}

/// The return address of the call of the function of a call that saved `context`, which a test
/// reads. That function keeps a frame pointer, and the switch saves it. The word above that frame
/// pointer is the return address of the call. Debug and ReleaseSafe keep frame pointers.
pub fn caller_of(context: *const Way(.call).Context) usize {
    const frame_pointer = switch (builtin.cpu.arch) {
        .aarch64 => context.fp,
        .x86_64 => context.rbp,
        else => @compileError("no fiber switch for this architecture"),
    };
    const frame: *const [2]usize = @ptrFromInt(frame_pointer);
    return frame[1];
}
