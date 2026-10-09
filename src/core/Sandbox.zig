//! An environment for untrusted scripts, with limits of its own.
//!
//!     var sandbox = try lua.newSandbox(.{ .limits = .{ .memory = 1 << 20, .instructions = 1_000_000 } });
//!     defer sandbox.deinit();
//!     try sandbox.set("log", log);
//!     try sandbox.doString(untrusted_source);
//!     try sandbox.call(void, "on_event", .{event});
//!
//! The limits apply to every call made through the sandbox, on top of the
//! state's own (`State.setMemoryLimit`, `State.setInstructionLimit`): the
//! stricter one wins.

const std = @import("std");
const api = @import("../runtime/api.zig");
const convert = @import("../binding/convert.zig");
const State = @import("State.zig");
const ref = @import("ref.zig");

const Sandbox = @This();

state: State,
/// The global environment of code run in the sandbox.
env: ref.Table,
limits: Limits,

pub const Limits = struct {
    /// Bytes a call may add to the state's memory use.
    memory: ?usize = null,
    /// Instructions a call may run, counted as in `State.setInstructionLimit`.
    instructions: ?u64 = null,
};

/// Which libraries the environment gets, and its limits. Base functions
/// that cannot escape (pairs, pcall, tostring, ...) are always there; `io`,
/// `os` (beyond time), `debug`, `package`, `require`, `load` and `dofile`
/// never are.
pub const Options = struct {
    string: bool = true,
    table: bool = true,
    math: bool = true,
    coroutine: bool = true,
    /// Lua 5.3+.
    utf8: bool = true,
    /// bit32 (5.2, Luau) or bit (LuaJIT).
    bit: bool = true,
    /// os.time, os.clock and os.difftime.
    os_time: bool = true,
    limits: Limits = .{},
    /// Luau: mark the environment "safe" so that builtins and globals are
    /// resolved when code is loaded (Luau's fast paths). Code loaded earlier
    /// then keeps seeing the old value of a global that later code redefines,
    /// so leave it off for scripts that are reloaded or extend each other.
    luau_fast_builtins: bool = false,
};

pub fn init(state: State, options: Options) State.Error!Sandbox {
    const env = try state.runChunk(ref.Table, "=zilua.sandbox", @embedFile("sandbox.lua"), .{convert.asTable(options)});
    if (comptime api.lang == .luau) {
        // Luau's own sandboxing model: library tables are read-only.
        env.push(state.L);
        defer api.pop(state.L, 1);
        api.pushNil(state.L);
        while (api.next(state.L, -2)) {
            // Not _G, which is the environment itself.
            if (api.typeOf(state.L, -1) == .table and !api.rawEqual(state.L, -1, -3)) {
                api.setReadonly(state.L, -1, true);
            }
            api.pop(state.L, 1);
        }
        if (options.luau_fast_builtins) api.setSafeEnv(state.L, -1, true);
    }
    return .{ .state = state, .env = env, .limits = options.limits };
}

pub fn deinit(self: Sandbox) void {
    self.env.deinit();
}

/// Adds `value` to the environment as global `name`.
pub fn set(self: Sandbox, name: [:0]const u8, value: anytype) error{ InvalidKey, ReadOnly }!void {
    return self.env.set(name, value);
}

/// Reads global `name` of the environment.
pub fn get(self: Sandbox, comptime T: type, name: [:0]const u8) State.Error!T {
    return self.env.get(T, name);
}

/// Compiles `source` (text only) and runs it in the sandbox.
pub fn doString(self: Sandbox, source: []const u8) State.Error!void {
    return self.doStringNamed(source, "=(sandbox)");
}

pub fn doStringNamed(self: Sandbox, source: []const u8, chunkname: [:0]const u8) State.Error!void {
    const saved = self.state.applyLimits(self.limits.memory, self.limits.instructions);
    defer self.state.restoreLimits(saved);
    return self.state.doStringInNamed(self.env, source, chunkname);
}

/// Compiles `source` for the sandbox without running it. Calls to the
/// result made through `Function.call` are not limited; use `call`.
pub fn load(self: Sandbox, source: []const u8, chunkname: [:0]const u8) State.Error!ref.Function {
    return self.state.loadStringIn(self.env, source, chunkname);
}

/// Calls the sandbox's global function `name` under the sandbox's limits.
pub fn call(self: Sandbox, comptime R: type, name: [:0]const u8, args: anytype) State.Error!R {
    const L = self.state.L;
    try self.state.reserveCall(@TypeOf(args), R);
    self.env.push(L);
    // Raw: the script may have given its environment an __index that raises.
    api.pushString(L, name);
    _ = api.rawGet(L, -2);
    api.remove(L, -2);
    const nargs = convert.pushMulti(L, args);
    const saved = self.state.applyLimits(self.limits.memory, self.limits.instructions);
    defer self.state.restoreLimits(saved);
    return self.state.callStack(R, nargs);
}
