//! Turns Zig functions into `lua_CFunction`s at comptime.
//!
//! Each parameter is read from the Lua stack with `convert.to`, in order,
//! except for these, which zilua fills in itself:
//! - `zilua.State`: the calling state
//! - `std.mem.Allocator`: the state's allocator
//! - `std.Io`: the `std.Io` given to `State.setIo`
//! - `zilua.Args` (last parameter only): the remaining Lua arguments
//!
//! Handle parameters (`Table`, `Function`, ...) are valid for the duration of
//! the call and released afterwards; `clone` one to keep it.
//!
//! The result is pushed with `convert.pushMulti`, so a tuple return becomes
//! multiple Lua results and `void` becomes none. `zilua.yield(...)` yields
//! from the calling coroutine, and `zilua.callThen(...)` calls a Lua function
//! and continues in another Zig function with its results.
//!
//! Errors never longjmp through Zig frames that have pending `defer`s: the
//! wrapped function returns normally (running its defers), and only then
//! does the trampoline raise the Lua error.

const std = @import("std");
const api = @import("../runtime/api.zig");
const convert = @import("convert.zig");
const State = @import("../core/State.zig");
const ref = @import("../core/ref.zig");
const thread = @import("../core/thread.zig");

const lua_State = api.lua_State;

const RawCFunction = fn (?*lua_State) callconv(.c) c_int;

/// The Lua arguments that remain after the ones bound to parameters: the
/// last parameter of a bound function can be `zilua.Args` to accept any
/// number of arguments. Values read from it are borrowed like parameters.
pub const Args = struct {
    state: State,
    /// Stack index of the first remaining argument.
    first: c_int,
    count: c_int,

    pub const zilua_special = {};

    pub fn len(self: Args) usize {
        return @intCast(self.count);
    }

    /// Argument `i` (0-based) as a `T`. Missing arguments read as nil.
    pub fn get(self: Args, comptime T: type, i: usize) convert.Error!T {
        if (i >= self.len()) {
            if (@typeInfo(T) == .optional) return null;
            return error.TypeMismatch;
        }
        return convert.to(T, self.state.L, self.first + @as(c_int, @intCast(i)));
    }

    pub fn typeOf(self: Args, i: usize) api.Type {
        if (i >= self.len()) return .none;
        return api.typeOf(self.state.L, self.first + @as(c_int, @intCast(i)));
    }
};

/// Returned by a bound function to call `func` and then continue in `next`
/// with its results as arguments. Create with `callThen`.
pub fn CallThen(comptime next: anytype, comptime ArgsT: type) type {
    return struct {
        func: ref.Function,
        args: ArgsT,

        pub const zilua_special = {};
        pub const zilua_call_then = {};
        pub const continuation = next;
    };
}

/// Calls the Lua function `func` with the elements of the tuple `args`, then
/// `next` (a Zig function, bound like any other) with the call's results;
/// what `next` returns is what the bound function returns.
///
/// On Lua 5.2 to 5.5 the call can yield: `func` may suspend the coroutine,
/// and `next` runs once it is resumed and `func` returns. Elsewhere yielding
/// inside `func` is an "attempt to yield across a C-call boundary" error.
pub fn callThen(func: ref.Function, args: anytype, comptime next: anytype) CallThen(next, @TypeOf(args)) {
    return .{ .func = func, .args = args };
}

/// Returned by a bound function to hand Lua memory it allocated: zilua
/// pushes `value` and then frees it with `zilua.free(gpa, value)`.
///
///     fn greet(gpa: std.mem.Allocator, name: []const u8) !zilua.Owned([]u8) {
///         return .{ .value = try std.mem.concat(gpa, u8, &.{ "hi ", name }), .gpa = gpa };
///     }
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        gpa: std.mem.Allocator,

        pub const zilua_special = {};
        pub const zilua_owned = {};
    };
}

fn isOwned(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zilua_owned");
}

fn isCallThen(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zilua_call_then");
}

/// Parameter types zilua fills in instead of reading them from Lua.
fn isInjected(comptime T: type) bool {
    return T == State or T == std.mem.Allocator or T == std.Io or T == Args;
}

/// Whether `wrap` accepts functions of type `F`.
pub fn isWrappable(comptime F: type) bool {
    if (F == RawCFunction) return true;
    const info = @typeInfo(F).@"fn";
    if (info.is_generic or info.attrs.varargs) return false;
    for (info.param_types, 0..) |P, i| {
        if (P.? == Args and i != info.param_types.len - 1) return false;
        if (!isInjected(P.?) and !convert.canRead(P.?)) return false;
    }
    const R = info.return_type.?;
    const Payload = switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
    if (thread.isYield(Payload)) return convert.canPush(@FieldType(Payload, "values"));
    if (isCallThen(Payload)) return convert.canPush(@FieldType(Payload, "args")) and isWrappable(@TypeOf(Payload.continuation));
    if (isOwned(Payload)) return convert.canPush(@FieldType(Payload, "value"));
    return Payload == void or Payload == noreturn or convert.canPush(Payload);
}

/// Returns a C function that calls `f` with arguments converted from Lua.
pub fn wrap(comptime f: anytype) api.CFunction {
    const F = @TypeOf(f);
    if (@typeInfo(F) != .@"fn") @compileError("zilua: expected a function, got " ++ @typeName(F));
    if (F == RawCFunction) return &f;
    comptime check(F);
    return &Trampoline(f).call;
}

fn check(comptime F: type) void {
    const info = @typeInfo(F).@"fn";
    if (info.is_generic) @compileError("zilua: cannot bind generic function " ++ @typeName(F) ++ " (it has anytype or comptime parameters)");
    if (info.attrs.varargs) @compileError("zilua: cannot bind variadic function " ++ @typeName(F) ++ ", take zilua.Args instead");
    for (info.param_types, 0..) |P, i| {
        if (P.? == Args and i != info.param_types.len - 1) @compileError("zilua: zilua.Args must be the last parameter of " ++ @typeName(F));
    }
}

/// What went wrong while reading an argument, for the error message.
const Diagnostic = struct {
    /// 1-based Lua argument index, 0 if the error did not come from an argument.
    arg: c_int = 0,
    expected: [:0]const u8 = "",
};

fn Trampoline(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const Params = blk: {
        var types: [info.param_types.len]type = undefined;
        for (info.param_types, 0..) |P, i| types[i] = P.?;
        const final = types;
        break :blk @Tuple(&final);
    };

    return struct {
        fn call(L_: ?*lua_State) callconv(.c) c_int {
            const L = L_.?;
            var diag: Diagnostic = .{};
            return invoke(L, 1, &diag) catch |err| fail(L, err, diag);
        }

        /// Entry point for continuations: the arguments start at `first`.
        fn callFrom(L: *lua_State, first: c_int) c_int {
            var diag: Diagnostic = .{};
            return invoke(L, first, &diag) catch |err| fail(L, err, diag);
        }

        fn invoke(L: *lua_State, first: c_int, diag: *Diagnostic) !c_int {
            var params: Params = undefined;
            var read: usize = 0;
            comptime var offset: c_int = 0;
            inline for (info.param_types, 0..) |P, i| {
                const T = P.?;
                if (T == State) {
                    params[i] = State.fromLua(L);
                } else if (T == std.mem.Allocator) {
                    params[i] = State.fromLua(L).allocator();
                } else if (T == std.Io) {
                    params[i] = State.fromLua(L).io() orelse {
                        releaseParams(params, read);
                        return error.NoIo;
                    };
                } else if (T == Args) {
                    const start = first + offset;
                    params[i] = .{ .state = State.fromLua(L), .first = start, .count = @max(0, api.getTop(L) - start + 1) };
                } else {
                    const idx = first + offset;
                    params[i] = convert.to(T, L, idx) catch |err| {
                        releaseParams(params, read);
                        // The stack index: the argument number for ordinary calls.
                        diag.* = .{ .arg = idx, .expected = convert.typeName(T) };
                        return err;
                    };
                    offset += 1;
                }
                read = i + 1;
            }

            const result = @call(.auto, f, params);
            const value = if (@typeInfo(@TypeOf(result)) == .error_union) result catch |err| {
                releaseParams(params, read);
                return err;
            } else result;
            const Value = @TypeOf(value);

            if (comptime thread.isYield(Value)) {
                if (!api.checkStack(L, comptime convert.resultCount(@TypeOf(value.values)) + 2)) return error.StackOverflow;
                const n = convert.pushMulti(L, value.values);
                releaseParams(params, read);
                // On 5.2+ this longjmps out right away; nothing here has a defer.
                return api.yieldValues(L, n);
            }
            if (comptime isCallThen(Value)) {
                if (!api.checkStack(L, comptime convert.resultCount(@TypeOf(value.args)) + 3)) return error.StackOverflow;
                const base = api.getTop(L);
                value.func.push(L);
                const nargs = convert.pushMulti(L, value.args);
                releaseParams(params, read);
                return api.callWithContinuation(L, nargs, base, Continuation(Value.continuation).resume_);
            }
            if (comptime isOwned(Value)) {
                if (!api.checkStack(L, comptime convert.resultCount(@TypeOf(value.value)) + 2)) {
                    convert.free(value.gpa, value.value);
                    return error.StackOverflow;
                }
                const n = convert.pushMulti(L, value.value);
                convert.free(value.gpa, value.value);
                releaseParams(params, read);
                return n;
            }
            // Lua guarantees LUA_MINSTACK (20) free slots on entry, not more.
            if (!api.checkStack(L, comptime convert.resultCount(Value) + 2)) return error.StackOverflow;
            const n = convert.pushMulti(L, value);
            // After pushing: the result may be one of the handles.
            releaseParams(params, read);
            return n;
        }

        fn releaseParams(params: Params, read: usize) void {
            inline for (info.param_types, 0..) |P, i| {
                if (comptime convert.isHandleLike(P.?)) {
                    if (i < read) convert.releaseHandle(params[i]);
                }
            }
        }
    };
}

/// Runs `next` with the results of a `callThen` call, which start after the
/// `base` values the bound function had on its stack.
fn Continuation(comptime next: anytype) type {
    return struct {
        fn resume_(L: *lua_State, base: isize) c_int {
            return Trampoline(next).callFrom(L, @intCast(base + 1));
        }
    };
}

/// Raises the Lua error for `err`. Called from the trampoline after the
/// wrapped function has returned, so no Zig `defer` is skipped.
fn fail(L: *lua_State, err: anyerror, diag: Diagnostic) noreturn {
    @branchHint(.cold);
    if (err == error.LuaError) {
        // `State.fail` pushed the message. Prefix it with the position of
        // the Lua caller, like `error("msg")` does.
        if (api.typeOf(L, -1) == .string) {
            api.where(L, 1);
            api.insert(L, -2);
            api.concat(L, 2);
        }
        api.raise(L);
    }
    if (err == error.NoIo) {
        _ = api.raiseF(L, "this function needs std.Io: call State.setIo first");
        unreachable;
    }
    if (diag.arg != 0) {
        const msg: [*:0]const u8 = switch (err) {
            error.NotAnInteger => "number has no integer representation",
            error.IntegerOutOfRange => "integer out of range",
            error.InvalidEnum => "invalid enum value",
            error.MissingField => api.pushFString(L, "%s expected, got table with missing fields", diag.expected.ptr),
            error.ReadOnly => api.pushFString(L, "mutable %s expected, got read-only reference", diag.expected.ptr),
            else => api.pushFString(L, "%s expected, got %s", diag.expected.ptr, api.typeName(L, diag.arg)),
        };
        _ = api.raiseArgError(L, diag.arg, msg);
        unreachable;
    }
    _ = api.raiseF(L, "%s", @errorName(err).ptr);
    unreachable;
}
