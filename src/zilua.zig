//! zilua: automatic Zig <-> Lua bindings, generated at comptime.
//!
//!     const lua = try zilua.State.init(gpa, .{});
//!     defer lua.deinit();
//!     lua.setGlobal("add", add);         // any Zig function
//!     lua.registerType(Vec2);            // any Zig struct
//!     try lua.doString("print(add(1, 2), Vec2.init(3, 4):length())");
//!
//! The Lua runtime is chosen at build time with `-Dlang` (see README.md).

pub const State = @import("core/State.zig");
pub const Error = State.Error;
pub const ConvertError = convert.Error;

pub const Ref = ref.Ref;
pub const Table = ref.Table;
pub const Function = ref.Function;

pub const Thread = thread.Thread;
pub const RunResult = thread.RunResult;
pub const Yield = thread.Yield;
/// Return `zilua.yield(values)` from a bound function to yield from the
/// coroutine that called it.
pub const yield = thread.yield;
pub const Scheduler = @import("core/Scheduler.zig");
pub const Reloader = @import("core/Reloader.zig");
pub const Sandbox = @import("core/Sandbox.zig");

pub const Args = bind.Args;
pub const Owned = bind.Owned;
pub const CallThen = bind.CallThen;
/// Return `zilua.callThen(func, args, next)` from a bound function to call
/// a Lua function and continue in `next` with its results.
pub const callThen = bind.callThen;

/// Reads a value that owns all its memory (see `State.getGlobalAlloc`).
pub const toAlloc = convert.toAlloc;
/// Frees what the *Alloc conversions allocated and releases its handles.
pub const free = convert.free;
/// A deep copy: slices copied, handles cloned. Release it with `free`.
pub const dupe = convert.dupe;

pub const exportModule = module.exportModule;
pub const module = @import("core/module.zig");

pub const AsTable = convert.AsTable;
pub const asTable = convert.asTable;

/// Turns a Zig function into a `lua_CFunction` (done implicitly by `setGlobal`).
pub const wrap = bind.wrap;

pub const Lang = @import("runtime/lang.zig").Lang;
/// The runtime this build of zilua targets.
pub const lang = api.lang;

/// Runtime-independent layer over the Lua C API, for direct stack work.
pub const api = @import("runtime/api.zig");

const ref = @import("core/ref.zig");
const thread = @import("core/thread.zig");
const convert = @import("binding/convert.zig");
const bind = @import("binding/bind.zig");

test {
    _ = @import("tests/state.zig");
    _ = @import("tests/functions.zig");
    _ = @import("tests/usertypes.zig");
    _ = @import("tests/conversions.zig");
    _ = @import("tests/runtimes.zig");
    _ = @import("tests/coroutines.zig");
    _ = @import("tests/sandbox.zig");
    _ = @import("tests/reload.zig");
    _ = @import("tests/binding.zig");
    _ = @import("tests/alloc.zig");
    _ = @import("tests/module.zig");
}
