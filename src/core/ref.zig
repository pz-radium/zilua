//! Handles that keep Lua values alive from Zig through registry references.
//!
//! Every handle must be released with `deinit`. Handles operate on the main
//! thread of their state and must not outlive it.

const std = @import("std");
const api = @import("../runtime/api.zig");
const convert = @import("../binding/convert.zig");
const State = @import("State.zig");

/// A reference to any Lua value.
pub const Ref = struct {
    state: State,
    id: c_int,

    /// References the value at `idx` of `state`'s stack, without popping it.
    pub fn fromStack(state: State, idx: c_int) Ref {
        api.pushValue(state.L, idx);
        const main = state.mainThread();
        // The registry is shared by all threads, so ref'ing from `state.L`
        // and using the id from the main thread is fine.
        return .{ .state = main, .id = api.ref(state.L, api.registry_index) };
    }

    pub fn deinit(self: Ref) void {
        api.unref(self.state.L, api.registry_index, self.id);
    }

    /// Pushes the referenced value onto `L`, which must belong to the same state.
    pub fn push(self: Ref, L: *api.lua_State) void {
        _ = api.rawGetI(L, api.registry_index, self.id);
    }

    /// A second, independent reference to the same value.
    pub fn clone(self: Ref) Ref {
        self.push(self.state.L);
        return .{ .state = self.state, .id = api.ref(self.state.L, api.registry_index) };
    }

    /// Reads the value as a `T` that owns its memory (see `State.getGlobalAlloc`).
    pub fn getAlloc(self: Ref, gpa: std.mem.Allocator, comptime T: type) State.Error!T {
        self.push(self.state.L);
        defer api.pop(self.state.L, 1);
        return convert.toAlloc(T, gpa, self.state.L, -1);
    }

    /// Reads the value as a `T`.
    pub fn get(self: Ref, comptime T: type) State.Error!T {
        comptime convert.ensureOwned(T, "Ref.get");
        self.push(self.state.L);
        defer api.pop(self.state.L, 1);
        return convert.to(T, self.state.L, -1);
    }
};

/// A reference to a Lua table. Access is raw: metamethods are not invoked,
/// so these functions never raise Lua errors (except out of memory).
pub const Table = struct {
    ref: Ref,

    pub fn fromStack(state: State, idx: c_int) Table {
        return .{ .ref = .fromStack(state, idx) };
    }

    pub fn deinit(self: Table) void {
        self.ref.deinit();
    }

    pub fn push(self: Table, L: *api.lua_State) void {
        self.ref.push(L);
    }

    /// `t[key]` as a `T`. `key` is any value zilua can push, usually a string
    /// or an integer.
    pub fn get(self: Table, comptime T: type, key: anytype) State.Error!T {
        comptime convert.ensureOwned(T, "Table.get");
        const L = self.ref.state.L;
        self.push(L);
        convert.push(L, key);
        _ = api.rawGet(L, -2);
        defer api.pop(L, 2);
        return convert.to(T, L, -1);
    }

    /// `t[key]` as a `T` that owns its memory (see `State.getGlobalAlloc`).
    pub fn getAlloc(self: Table, gpa: std.mem.Allocator, comptime T: type, key: anytype) State.Error!T {
        const L = self.ref.state.L;
        self.push(L);
        convert.push(L, key);
        _ = api.rawGet(L, -2);
        defer api.pop(L, 2);
        return convert.toAlloc(T, gpa, L, -1);
    }

    /// A second, independent reference to the same table.
    pub fn clone(self: Table) Table {
        return .{ .ref = self.ref.clone() };
    }

    /// `t[key] = value`. Lua tables cannot have nil or NaN keys, and Luau
    /// tables can be read-only.
    pub fn set(self: Table, key: anytype, value: anytype) error{ InvalidKey, ReadOnly }!void {
        const L = self.ref.state.L;
        self.push(L);
        if (api.isReadonly(L, -1)) {
            api.pop(L, 1);
            return error.ReadOnly;
        }
        convert.push(L, key);
        const bad_key = switch (api.typeOf(L, -1)) {
            .nil => true,
            .number => std.math.isNan(api.toNumber(L, -1).?),
            else => false,
        };
        if (bad_key) {
            api.pop(L, 2);
            return error.InvalidKey;
        }
        convert.push(L, value);
        api.rawSet(L, -3);
        api.pop(L, 1);
    }

    /// Length of the sequence part (`#t` without `__len`).
    pub fn len(self: Table) usize {
        const L = self.ref.state.L;
        self.push(L);
        defer api.pop(L, 1);
        return api.rawLen(L, -1);
    }
};

/// A reference to a Lua function.
pub const Function = struct {
    ref: Ref,

    pub fn fromStack(state: State, idx: c_int) Function {
        return .{ .ref = .fromStack(state, idx) };
    }

    pub fn deinit(self: Function) void {
        self.ref.deinit();
    }

    pub fn push(self: Function, L: *api.lua_State) void {
        self.ref.push(L);
    }

    /// A second, independent reference to the same function.
    pub fn clone(self: Function) Function {
        return .{ .ref = self.ref.clone() };
    }

    /// Like `call`, with results read by `toAlloc` (see `State.callAlloc`).
    pub fn callAlloc(self: Function, gpa: std.mem.Allocator, comptime R: type, args: anytype) State.Error!R {
        const state = self.ref.state;
        try state.reserveCall(@TypeOf(args), R);
        self.push(state.L);
        const nargs = convert.pushMulti(state.L, args);
        return state.callStackAlloc(gpa, R, nargs);
    }

    /// Calls the function in protected mode with the elements of the tuple
    /// `args` and converts the results to `R` (see `State.call`).
    pub fn call(self: Function, comptime R: type, args: anytype) State.Error!R {
        const state = self.ref.state;
        try state.reserveCall(@TypeOf(args), R);
        self.push(state.L);
        const nargs = convert.pushMulti(state.L, args);
        return state.callStack(R, nargs);
    }
};
