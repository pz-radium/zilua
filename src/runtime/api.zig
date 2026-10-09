//! Runtime-independent wrappers over the Lua C API.
//!
//! This is the only file that knows how the runtimes differ. Every branch on
//! `lang` is comptime-known, so the functions of other runtimes are never
//! referenced and never need to link.
//!
//! All functions take the raw `*lua_State`. They follow the C API's stack
//! conventions and may raise Lua errors (longjmp) exactly where the C function
//! they wrap may.

const std = @import("std");
const c = @import("c.zig");
const luau = @import("luau.zig");

pub const lang = c.lang;
pub const lua_State = c.lua_State;
pub const Integer = c.Integer;
pub const Number = c.Number;
pub const CFunction = c.CFunction;
pub const Alloc = c.Alloc;

pub const registry_index = c.LUA_REGISTRYINDEX;
pub const multret = c.LUA_MULTRET;

/// Whether the runtime distinguishes integers from floats.
pub const has_integers = lang.hasIntegers();

/// Whether userdata is finalized through a destructor given at creation
/// (`newUserdataDtor`) instead of a `__gc` metamethod. Luau has no `__gc`.
pub const has_userdata_dtor = lang == .luau;

/// Whether `traceback` produces a real stack traceback (no `luaL_traceback` in 5.1).
pub const has_traceback = lang != .lua51;

/// Whether `setUserValue` only accepts tables (the 5.1 environment, and 5.2,
/// which allows a table or nil).
pub const user_value_must_be_table = switch (lang) {
    .lua51, .luajit, .lua52 => true,
    .lua53, .lua54, .lua55, .luau => false,
};

/// Variadic C functions can't be wrapped (Zig can't forward `...`), so they
/// are re-exported as is. Arguments must be C types: `c_int`, `[*:0]const u8`, ...
pub const pushFString = if (lang == .luau) luau.lua_pushfstringL else c.lua_pushfstring;
/// Raises an error with position information. Never returns.
pub const raiseF = if (lang == .luau) luau.luaL_errorL else c.luaL_error;
/// Raises "bad argument #arg to 'fname' (extramsg)" ("invalid argument" on
/// Luau). Never returns.
pub const raiseArgError = if (lang == .luau) luau.luaL_argerrorL else c.luaL_argerror;

/// Luau userdata destructor: receives the userdata's memory when it is
/// collected. Must not call back into Lua.
pub const Destructor = luau.Destructor;

pub const Type = enum(c_int) {
    none = -1,
    nil = 0,
    boolean = 1,
    light_userdata = 2,
    number = 3,
    string = 4,
    table = 5,
    function = 6,
    userdata = 7,
    thread = 8,
    /// Luau only.
    vector = 9,
    /// Luau only.
    buffer = 10,
    _,
};

pub const Status = enum {
    ok,
    yield,
    runtime,
    syntax,
    memory,
    message_handler,
    gc_metamethod,
    file,
};

pub fn toStatus(code: c_int) Status {
    if (code == c.LUA_OK) return .ok;
    if (code == c.LUA_YIELD) return .yield;
    if (code == c.LUA_ERRRUN) return .runtime;
    if (code == c.LUA_ERRSYNTAX) return .syntax;
    if (code == c.LUA_ERRMEM) return .memory;
    if (code == c.LUA_ERRERR) return .message_handler;
    if (code == c.LUA_ERRFILE) return .file;
    if ((lang == .lua52 or lang == .lua53) and code == c.LUA_ERRGCMM) return .gc_metamethod;
    return .runtime;
}

/// Mode argument of the load functions.
pub const LoadMode = enum {
    text,
    binary,
    any,

    fn cString(mode: LoadMode) [*:0]const u8 {
        return switch (mode) {
            .text => "t",
            .binary => "b",
            .any => "bt",
        };
    }
};

// ---------------------------------------------------------------------------
// State

/// Creates a state that allocates through `alloc`. Returns null on failure.
pub fn newState(alloc: Alloc, ud: ?*anyopaque) ?*lua_State {
    switch (lang) {
        .lua55 => {
            // Lua 5.5 takes the string hash seed from the caller. The address
            // of `ud` gives per-process variation through ASLR, which is
            // what luai_makeseed relies on as well.
            const addr: u64 = if (ud) |p| @intFromPtr(p) else 0;
            const seed: c_uint = @truncate(addr ^ (addr >> 32));
            return c.lua_newstate(alloc, ud, seed);
        },
        else => return c.lua_newstate(alloc, ud),
    }
}

/// A state with Lua's default allocator (`luaL_newstate`), as a Lua host
/// would create it. zilua's own states come from `newState`.
pub fn newDefaultState() ?*lua_State {
    return c.luaL_newstate();
}

pub fn close(L: *lua_State) void {
    c.lua_close(L);
}

pub fn openLibs(L: *lua_State) void {
    switch (lang) {
        // luaL_openlibs(L) is a macro for luaL_openselectedlibs(L, ~0, 0).
        .lua55 => c.luaL_openselectedlibs(L, -1, 0),
        else => c.luaL_openlibs(L),
    }
}

/// Raises a Lua error if the runtime was compiled with different numeric
/// types than `c.zig` assumes. Must run in protected mode (see `checkVersionFn`).
pub fn checkVersion(L: *lua_State) void {
    switch (lang) {
        .lua53, .lua54, .lua55 => c.luaL_checkversion_(L, c.LUA_VERSION_NUM, c.LUAL_NUMSIZES),
        else => {},
    }
}

/// The main thread of the state `L` belongs to. Lua 5.1 and LuaJIT cannot
/// tell, so there `L` itself is returned.
pub fn mainThread(L: *lua_State) *lua_State {
    switch (lang) {
        .lua51, .luajit => return L,
        .luau => return luau.lua_mainthread(L),
        else => {
            _ = rawGetI(L, c.LUA_REGISTRYINDEX, c.LUA_RIDX_MAINTHREAD);
            const main = c.lua_tothread(L, -1).?;
            pop(L, 1);
            return main;
        },
    }
}

pub fn newThread(L: *lua_State) *lua_State {
    // lua_newthread raises on allocation failure instead of returning null.
    return c.lua_newthread(L).?;
}

/// Sets the function called for errors outside any protected call. It must
/// not return.
pub fn atPanic(L: *lua_State, f: CFunction) void {
    switch (lang) {
        .luau => {
            luau_panic = f;
            luau.lua_callbacks(L).panic = &luauPanic;
        },
        else => _ = c.lua_atpanic(L, f),
    }
}

/// Luau calls `lua_callbacks()->panic` with a different signature than
/// `lua_atpanic` handlers; this forwards to the handler given to `atPanic`.
var luau_panic: ?CFunction = null;

fn luauPanic(L: ?*lua_State, errcode: c_int) callconv(.c) void {
    _ = errcode;
    if (luau_panic) |f| _ = f(L);
}

// ---------------------------------------------------------------------------
// Stack

pub fn upvalueIndex(i: c_int) c_int {
    return if (comptime lang.usesGlobalsIndex()) c.LUA_GLOBALSINDEX - i else c.LUA_REGISTRYINDEX - i;
}

pub fn absIndex(L: *lua_State, idx: c_int) c_int {
    switch (lang) {
        .lua51, .luajit => return if (idx > 0 or idx <= c.LUA_REGISTRYINDEX) idx else c.lua_gettop(L) + idx + 1,
        else => return c.lua_absindex(L, idx),
    }
}

pub fn getTop(L: *lua_State) c_int {
    return c.lua_gettop(L);
}

pub fn setTop(L: *lua_State, idx: c_int) void {
    c.lua_settop(L, idx);
}

pub fn pop(L: *lua_State, n: c_int) void {
    c.lua_settop(L, -n - 1);
}

pub fn pushValue(L: *lua_State, idx: c_int) void {
    c.lua_pushvalue(L, idx);
}

/// Moves the top element into position `idx`, shifting the elements above it up.
pub fn insert(L: *lua_State, idx: c_int) void {
    switch (lang) {
        .lua53, .lua54, .lua55 => c.lua_rotate(L, idx, 1),
        else => c.lua_insert(L, idx),
    }
}

/// Removes the element at `idx`, shifting the elements above it down.
pub fn remove(L: *lua_State, idx: c_int) void {
    switch (lang) {
        .lua53, .lua54, .lua55 => {
            c.lua_rotate(L, idx, -1);
            pop(L, 1);
        },
        else => c.lua_remove(L, idx),
    }
}

/// Pops the top element and stores it at `idx`.
pub fn replace(L: *lua_State, idx: c_int) void {
    switch (lang) {
        .lua53, .lua54, .lua55 => {
            c.lua_copy(L, -1, idx);
            pop(L, 1);
        },
        else => c.lua_replace(L, idx),
    }
}

pub fn checkStack(L: *lua_State, n: c_int) bool {
    return c.lua_checkstack(L, n) != 0;
}

pub fn xmove(from: *lua_State, to: *lua_State, n: c_int) void {
    c.lua_xmove(from, to, n);
}

// ---------------------------------------------------------------------------
// Reading values

pub fn typeOf(L: *lua_State, idx: c_int) Type {
    const tag = c.lua_type(L, idx);
    if (lang != .luau) return @fromBackingInt(tag);
    return switch (tag) {
        luau.LUA_TNIL => .nil,
        luau.LUA_TBOOLEAN => .boolean,
        luau.LUA_TLIGHTUSERDATA => .light_userdata,
        // Luau's 64-bit integers convert like numbers.
        luau.LUA_TNUMBER, luau.LUA_TINTEGER => .number,
        luau.LUA_TVECTOR => .vector,
        luau.LUA_TSTRING => .string,
        luau.LUA_TTABLE => .table,
        luau.LUA_TFUNCTION => .function,
        luau.LUA_TUSERDATA => .userdata,
        luau.LUA_TTHREAD => .thread,
        luau.LUA_TBUFFER => .buffer,
        c.LUA_TNONE => .none,
        // Classes and objects of newer Luau releases.
        else => @fromBackingInt(1000 + tag),
    };
}

/// Name of the type of the value at `idx`, as Lua spells it ("nil", "table", ...).
pub fn typeName(L: *lua_State, idx: c_int) [*:0]const u8 {
    return c.lua_typename(L, c.lua_type(L, idx));
}

pub fn isNoneOrNil(L: *lua_State, idx: c_int) bool {
    return c.lua_type(L, idx) <= c.LUA_TNIL;
}

pub fn toBoolean(L: *lua_State, idx: c_int) bool {
    return c.lua_toboolean(L, idx) != 0;
}

/// The value as a number, if it is a number or a string convertible to one.
pub fn toNumber(L: *lua_State, idx: c_int) ?Number {
    if (lang == .luau and c.lua_type(L, idx) == luau.LUA_TINTEGER) {
        return @floatFromInt(luau.lua_tointeger64(L, idx, null));
    }
    switch (lang) {
        .lua51, .luajit => {
            if (c.lua_isnumber(L, idx) == 0) return null;
            return c.lua_tonumber(L, idx);
        },
        else => {
            var isnum: c_int = 0;
            const n = c.lua_tonumberx(L, idx, &isnum);
            return if (isnum != 0) n else null;
        },
    }
}

/// The value as an integer, if it is a number (or numeric string) with an
/// exact integer value that fits an `i64`. Unlike `lua_tointeger` in 5.1 and
/// 5.2 this never truncates.
pub fn toInteger(L: *lua_State, idx: c_int) ?i64 {
    if (comptime has_integers) {
        var isnum: c_int = 0;
        const i = c.lua_tointegerx(L, idx, &isnum);
        return if (isnum != 0) i else null;
    }
    if (lang == .luau and c.lua_type(L, idx) == luau.LUA_TINTEGER) {
        return luau.lua_tointeger64(L, idx, null);
    }
    const n = toNumber(L, idx) orelse return null;
    return floatToInteger(n);
}

fn floatToInteger(n: Number) ?i64 {
    const lo: Number = std.math.minInt(i64); // -2^63, exact in a double
    // -lo is 2^63, which is exactly representable even though maxInt(i64) is not.
    if (!(n >= lo and n < -lo)) return null; // also rejects NaN
    const whole: Number = @trunc(n);
    if (whole != n) return null;
    const i: i64 = @trunc(n);
    return i;
}

/// Whether the value is an integer: a real integer subtype from 5.3 on, a
/// number with an integral value before.
pub fn isInteger(L: *lua_State, idx: c_int) bool {
    if (comptime has_integers) return c.lua_isinteger(L, idx) != 0;
    if (typeOf(L, idx) != .number) return false;
    return toInteger(L, idx) != null;
}

/// The value as a string. Numbers are converted in place, which confuses
/// `next` during table traversal, so check the type first when iterating.
/// The slice points into Lua memory and is valid while the value stays on the stack.
pub fn toLString(L: *lua_State, idx: c_int) ?[:0]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len :0];
}

/// Like `toLString`, as a C string. Lua strings may contain zeros, so this
/// is only for messages.
pub fn toCString(L: *lua_State, idx: c_int) ?[*:0]const u8 {
    return c.lua_tolstring(L, idx, null);
}

/// Converts any value to a string the way `tostring` does and pushes it.
/// Respects `__tostring` and `__name` where the runtime supports them.
pub fn toStringMeta(L: *lua_State, idx: c_int) [:0]const u8 {
    switch (lang) {
        .lua51, .luajit => {
            const i = absIndex(L, idx);
            switch (typeOf(L, i)) {
                .number, .string => {
                    pushValue(L, i);
                    return toLString(L, -1).?;
                },
                .nil => pushString(L, "nil"),
                .boolean => pushString(L, if (toBoolean(L, i)) "true" else "false"),
                else => _ = pushFString(L, "%s: %p", typeName(L, i), c.lua_topointer(L, i)),
            }
            return toLString(L, -1).?;
        },
        else => {
            var len: usize = 0;
            const ptr = c.luaL_tolstring(L, idx, &len);
            return ptr[0..len :0];
        },
    }
}

pub fn toUserdata(L: *lua_State, idx: c_int) ?*anyopaque {
    return c.lua_touserdata(L, idx);
}

pub fn toThread(L: *lua_State, idx: c_int) ?*lua_State {
    return c.lua_tothread(L, idx);
}

pub fn toPointer(L: *lua_State, idx: c_int) ?*const anyopaque {
    return c.lua_topointer(L, idx);
}

/// Raw length: string length, userdata size, or table border (no `__len`).
pub fn rawLen(L: *lua_State, idx: c_int) usize {
    switch (lang) {
        .lua51, .luajit => return c.lua_objlen(L, idx),
        .luau => return @intCast(luau.lua_objlen(L, idx)),
        else => return @intCast(c.lua_rawlen(L, idx)),
    }
}

pub fn rawEqual(L: *lua_State, idx1: c_int, idx2: c_int) bool {
    return c.lua_rawequal(L, idx1, idx2) != 0;
}

// ---------------------------------------------------------------------------
// Pushing values

pub fn pushNil(L: *lua_State) void {
    c.lua_pushnil(L);
}

pub fn pushBoolean(L: *lua_State, b: bool) void {
    c.lua_pushboolean(L, @intFromBool(b));
}

pub fn pushInteger(L: *lua_State, n: Integer) void {
    c.lua_pushinteger(L, n);
}

pub fn pushNumber(L: *lua_State, n: Number) void {
    c.lua_pushnumber(L, n);
}

pub fn pushString(L: *lua_State, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}

pub fn pushLightUserdata(L: *lua_State, p: ?*const anyopaque) void {
    switch (lang) {
        .luau => luau.lua_pushlightuserdatatagged(L, @constCast(p), 0),
        else => c.lua_pushlightuserdata(L, @constCast(p)),
    }
}

pub fn pushCFunction(L: *lua_State, f: CFunction) void {
    pushCClosureNamed(L, f, 0, null);
}

/// Like `pushCFunction`. Luau shows `name` in error messages and tracebacks;
/// the other runtimes find names from the call site and ignore it.
pub fn pushCFunctionNamed(L: *lua_State, f: CFunction, name: ?[*:0]const u8) void {
    pushCClosureNamed(L, f, 0, name);
}

/// Pops `n` values and pushes a C closure with them as upvalues.
pub fn pushCClosure(L: *lua_State, f: CFunction, n: c_int) void {
    pushCClosureNamed(L, f, n, null);
}

pub fn pushCClosureNamed(L: *lua_State, f: CFunction, n: c_int, name: ?[*:0]const u8) void {
    switch (lang) {
        .luau => luau.lua_pushcclosurek(L, f, name, n, null),
        else => c.lua_pushcclosure(L, f, n),
    }
}

pub fn pushGlobalTable(L: *lua_State) void {
    if (comptime lang.usesGlobalsIndex()) {
        c.lua_pushvalue(L, c.LUA_GLOBALSINDEX);
    } else {
        _ = rawGetI(L, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);
    }
}

/// Pushes the thread `L` itself. Returns true if it is the main thread.
pub fn pushThread(L: *lua_State) bool {
    return c.lua_pushthread(L) != 0;
}

// ---------------------------------------------------------------------------
// Tables

pub fn createTable(L: *lua_State, narr: c_int, nrec: c_int) void {
    c.lua_createtable(L, narr, nrec);
}

pub fn newTable(L: *lua_State) void {
    c.lua_createtable(L, 0, 0);
}

/// Pushes `t[k]` (may invoke `__index`) and returns its type.
pub fn getField(L: *lua_State, idx: c_int, k: [*:0]const u8) Type {
    switch (lang) {
        .lua53, .lua54, .lua55 => return @fromBackingInt(c.lua_getfield(L, idx, k)),
        else => {
            c.lua_getfield(L, idx, k);
            return typeOf(L, -1);
        },
    }
}

/// Does `t[k] = v` where `v` is the top value (may invoke `__newindex`). Pops `v`.
pub fn setField(L: *lua_State, idx: c_int, k: [*:0]const u8) void {
    c.lua_setfield(L, idx, k);
}

/// Pops a key and pushes `t[key]` (may invoke `__index`).
pub fn getTable(L: *lua_State, idx: c_int) Type {
    switch (lang) {
        .lua53, .lua54, .lua55 => return @fromBackingInt(c.lua_gettable(L, idx)),
        else => {
            c.lua_gettable(L, idx);
            return typeOf(L, -1);
        },
    }
}

/// Does `t[k] = v` with `k` below `v` on top of the stack. Pops both.
pub fn setTable(L: *lua_State, idx: c_int) void {
    c.lua_settable(L, idx);
}

pub fn rawGet(L: *lua_State, idx: c_int) Type {
    switch (lang) {
        .lua53, .lua54, .lua55 => return @fromBackingInt(c.lua_rawget(L, idx)),
        else => {
            c.lua_rawget(L, idx);
            return typeOf(L, -1);
        },
    }
}

pub fn rawSet(L: *lua_State, idx: c_int) void {
    c.lua_rawset(L, idx);
}

pub fn rawGetI(L: *lua_State, idx: c_int, n: Integer) Type {
    switch (lang) {
        .lua53, .lua54, .lua55 => return @fromBackingInt(c.lua_rawgeti(L, idx, n)),
        else => {
            c.lua_rawgeti(L, idx, @intCast(n));
            return typeOf(L, -1);
        },
    }
}

pub fn rawSetI(L: *lua_State, idx: c_int, n: Integer) void {
    switch (lang) {
        .lua53, .lua54, .lua55 => c.lua_rawseti(L, idx, n),
        else => c.lua_rawseti(L, idx, @intCast(n)),
    }
}

/// Pushes `t[p]` where `p` is a light userdata key.
pub fn rawGetP(L: *lua_State, idx: c_int, p: *const anyopaque) Type {
    switch (lang) {
        .lua53, .lua54, .lua55 => return @fromBackingInt(c.lua_rawgetp(L, idx, p)),
        .lua52 => {
            c.lua_rawgetp(L, idx, p);
            return typeOf(L, -1);
        },
        else => {
            const t = absIndex(L, idx);
            pushLightUserdata(L, p);
            return rawGet(L, t);
        },
    }
}

/// Does `t[p] = v` where `p` is a light userdata key and `v` the top value. Pops `v`.
pub fn rawSetP(L: *lua_State, idx: c_int, p: *const anyopaque) void {
    switch (lang) {
        .lua52, .lua53, .lua54, .lua55 => c.lua_rawsetp(L, idx, p),
        else => {
            const t = absIndex(L, idx);
            pushLightUserdata(L, p);
            insert(L, -2);
            rawSet(L, t);
        },
    }
}

pub fn getGlobal(L: *lua_State, name: [*:0]const u8) Type {
    switch (lang) {
        .lua51, .luajit, .luau => return getField(L, c.LUA_GLOBALSINDEX, name),
        .lua52 => {
            c.lua_getglobal(L, name);
            return typeOf(L, -1);
        },
        else => return @fromBackingInt(c.lua_getglobal(L, name)),
    }
}

/// Pops a value and stores it as global `name`.
pub fn setGlobal(L: *lua_State, name: [*:0]const u8) void {
    switch (lang) {
        .lua51, .luajit, .luau => c.lua_setfield(L, c.LUA_GLOBALSINDEX, name),
        else => c.lua_setglobal(L, name),
    }
}

/// Pushes `t[k]` for the next key after the one on top. Returns false at the end.
pub fn next(L: *lua_State, idx: c_int) bool {
    return c.lua_next(L, idx) != 0;
}

pub fn concat(L: *lua_State, n: c_int) void {
    c.lua_concat(L, n);
}

// ---------------------------------------------------------------------------
// Metatables and userdata

/// Pushes the metatable of the value at `idx`, or nothing if it has none.
pub fn getMetatable(L: *lua_State, idx: c_int) bool {
    return c.lua_getmetatable(L, idx) != 0;
}

/// Pops a table (or nil) and sets it as the metatable of the value at `idx`.
pub fn setMetatable(L: *lua_State, idx: c_int) void {
    _ = c.lua_setmetatable(L, idx);
}

/// Pushes the registry metatable `name`, creating it if needed. Returns true
/// if it was created by this call.
pub fn newMetatable(L: *lua_State, name: [*:0]const u8) bool {
    return c.luaL_newmetatable(L, name) != 0;
}

/// Pushes the registry metatable `name` (nil if not created yet).
pub fn getMetatableByName(L: *lua_State, name: [*:0]const u8) Type {
    return getField(L, c.LUA_REGISTRYINDEX, name);
}

/// The userdata at `idx` if its metatable is the registry metatable `name`.
pub fn testUserdata(L: *lua_State, idx: c_int, name: [*:0]const u8) ?*anyopaque {
    switch (lang) {
        .lua51, .luau => {
            const p = c.lua_touserdata(L, idx) orelse return null;
            if (!getMetatable(L, idx)) return null;
            _ = getMetatableByName(L, name);
            const same = rawEqual(L, -1, -2);
            pop(L, 2);
            return if (same) p else null;
        },
        else => return c.luaL_testudata(L, idx, name),
    }
}

/// Pushes a new full userdata of `size` bytes with one user value slot.
/// The memory is aligned like `malloc` and never moves.
pub fn newUserdata(L: *lua_State, size: usize) *anyopaque {
    switch (lang) {
        .lua54, .lua55 => return c.lua_newuserdatauv(L, size, 1).?,
        .luau => return luau.lua_newuserdatatagged(L, size, 0).?,
        else => return c.lua_newuserdata(L, size).?,
    }
}

/// Luau only (see `has_userdata_dtor`): a userdata whose memory is passed to
/// `dtor` when it is collected.
pub fn newUserdataDtor(L: *lua_State, size: usize, dtor: Destructor) *anyopaque {
    if (lang != .luau) @compileError("newUserdataDtor is Luau-only, other runtimes use __gc");
    return luau.lua_newuserdatadtor(L, size, dtor).?;
}

/// Pushes the user value of the userdata at `idx`.
pub fn getUserValue(L: *lua_State, idx: c_int) Type {
    switch (lang) {
        .luau => {
            const ud = absIndex(L, idx);
            pushUserValueTable(L);
            pushValue(L, ud);
            const ty = rawGet(L, -2);
            remove(L, -2);
            return ty;
        },
        .lua51, .luajit => {
            c.lua_getfenv(L, idx);
            return typeOf(L, -1);
        },
        .lua52 => {
            c.lua_getuservalue(L, idx);
            return typeOf(L, -1);
        },
        .lua53 => return @fromBackingInt(c.lua_getuservalue(L, idx)),
        else => return @fromBackingInt(c.lua_getiuservalue(L, idx, 1)),
    }
}

/// Pops a value and sets it as the user value of the userdata at `idx`.
/// See `user_value_must_be_table`.
pub fn setUserValue(L: *lua_State, idx: c_int) void {
    switch (lang) {
        .luau => {
            const ud = absIndex(L, idx);
            pushUserValueTable(L);
            pushValue(L, ud);
            pushValue(L, -3);
            rawSet(L, -3);
            pop(L, 2);
        },
        .lua51, .luajit => _ = c.lua_setfenv(L, idx),
        .lua52, .lua53 => c.lua_setuservalue(L, idx),
        else => _ = c.lua_setiuservalue(L, idx, 1),
    }
}

/// Luau has no user values, so they live in a registry table with weak keys:
/// an entry goes away with its userdata and keeps the value alive until then.
var user_values_key: u8 = 0;

fn pushUserValueTable(L: *lua_State) void {
    if (rawGetP(L, c.LUA_REGISTRYINDEX, &user_values_key) == .table) return;
    pop(L, 1);
    newTable(L);
    createTable(L, 0, 1);
    pushString(L, "k");
    setField(L, -2, "__mode");
    setMetatable(L, -2);
    pushValue(L, -1);
    rawSetP(L, c.LUA_REGISTRYINDEX, &user_values_key);
}

// ---------------------------------------------------------------------------
// Calls, loading, errors

pub fn call(L: *lua_State, nargs: c_int, nresults: c_int) void {
    switch (lang) {
        .lua51, .luajit, .luau => c.lua_call(L, nargs, nresults),
        else => c.lua_callk(L, nargs, nresults, 0, null),
    }
}

pub fn pcall(L: *lua_State, nargs: c_int, nresults: c_int, msgh: c_int) Status {
    switch (lang) {
        .lua51, .luajit, .luau => return toStatus(c.lua_pcall(L, nargs, nresults, msgh)),
        else => return toStatus(c.lua_pcallk(L, nargs, nresults, msgh, 0, null)),
    }
}

/// Compiles `buf` and pushes the resulting function (or an error message).
/// `mode` is ignored by 5.1, which always accepts binary chunks.
pub fn loadBuffer(L: *lua_State, buf: []const u8, chunkname: [*:0]const u8, mode: LoadMode) Status {
    switch (lang) {
        .lua51 => {
            // 5.1 has no mode argument: reject precompiled chunks ("\x1bLua") here.
            if (mode == .text and buf.len > 0 and buf[0] == 0x1b) {
                _ = pushFString(L, "attempt to load a binary chunk (mode is 't')");
                return .syntax;
            }
            return toStatus(c.luaL_loadbuffer(L, buf.ptr, buf.len, chunkname));
        },
        .luau => {
            // Luau only loads bytecode, so source is compiled first. Its
            // bytecode has no signature, so `.any` is treated as source.
            if (mode == .binary) return luauLoad(L, chunkname, buf);
            var size: usize = 0;
            const bytecode = luau.luau_compile(buf.ptr, buf.len, null, &size) orelse return .memory;
            // luau_load runs in protected mode, so this defer cannot be skipped.
            defer std.c.free(bytecode);
            return luauLoad(L, chunkname, bytecode[0..size]);
        },
        else => return toStatus(c.luaL_loadbufferx(L, buf.ptr, buf.len, chunkname, mode.cString())),
    }
}

fn luauLoad(L: *lua_State, chunkname: [*:0]const u8, bytecode: []const u8) Status {
    // Compile errors are encoded in the bytecode and reported here.
    return if (luau.luau_load(L, chunkname, bytecode.ptr, bytecode.len, 0) == 0) .ok else .syntax;
}

pub fn loadFile(L: *lua_State, path: [*:0]const u8, mode: LoadMode) Status {
    switch (lang) {
        .lua51 => return toStatus(c.luaL_loadfile(L, path)),
        .luau => {
            // No luaL_loadfile: read the file into a Lua string with C stdio.
            const file = std.c.fopen(path, "rb") orelse {
                _ = pushFString(L, "cannot open %s", path);
                return .file;
            };
            defer _ = std.c.fclose(file);
            _ = pushFString(L, "@%s", path);
            pushString(L, "");
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = std.c.fread(&chunk, 1, chunk.len, file);
                if (n == 0) break;
                pushString(L, chunk[0..n]);
                concat(L, 2);
            }
            const status = loadBuffer(L, toLString(L, -1).?, toCString(L, -2).?, mode);
            // Drop the chunk name and the source below the result.
            remove(L, -2);
            remove(L, -2);
            return status;
        },
        else => return toStatus(c.luaL_loadfilex(L, path, mode.cString())),
    }
}

/// Raises the value on top of the stack as an error. Never returns.
///
/// This unwinds with longjmp: Zig `defer`s between here and the enclosing
/// protected call do not run.
pub fn raise(L: *lua_State) noreturn {
    _ = c.lua_error(L);
    unreachable;
}

/// Pushes "chunkname:currentline:" for the function at call level `lvl`
/// (1 = the Lua function that called the running C function).
pub fn where(L: *lua_State, lvl: c_int) void {
    c.luaL_where(L, lvl);
}

/// Pushes a traceback of `L1` prefixed with `msg`. 5.1 has no
/// `luaL_traceback`, so there the message is pushed as is.
pub fn traceback(L: *lua_State, L1: *lua_State, msg: ?[*:0]const u8, level: c_int) void {
    switch (lang) {
        .lua51 => c.lua_pushstring(L, msg),
        else => c.luaL_traceback(L, L1, msg, level),
    }
}

/// Pops the top value and stores it in table `t`, returning a reference key.
/// Luau only has registry references (`t` is ignored there).
pub fn ref(L: *lua_State, t: c_int) c_int {
    switch (lang) {
        .luau => {
            const r = luau.lua_ref(L, -1);
            pop(L, 1);
            return r;
        },
        else => return c.luaL_ref(L, t),
    }
}

pub fn unref(L: *lua_State, t: c_int, r: c_int) void {
    switch (lang) {
        .luau => _ = luau.lua_unref(L, r),
        else => c.luaL_unref(L, t, r),
    }
}

// ---------------------------------------------------------------------------
// Coroutines

pub const ResumeResult = struct {
    status: Status,
    /// Number of values the coroutine yielded or returned, on top of its stack.
    nresults: c_int,
};

pub fn resumeThread(co: *lua_State, from: ?*lua_State, nargs: c_int) ResumeResult {
    switch (lang) {
        .lua51, .luajit => {
            const st = toStatus(c.lua_resume(co, nargs));
            return .{ .status = st, .nresults = c.lua_gettop(co) };
        },
        .lua52, .lua53, .luau => {
            const st = toStatus(c.lua_resume(co, from, nargs));
            return .{ .status = st, .nresults = c.lua_gettop(co) };
        },
        else => {
            var nres: c_int = 0;
            const st = toStatus(c.lua_resume(co, from, nargs, &nres));
            return .{ .status = st, .nresults = nres };
        },
    }
}

pub fn threadStatus(L: *lua_State) Status {
    return toStatus(c.lua_status(L));
}

/// Yields the top `nresults` values from a C function: use as
/// `return yieldValues(L, n)`. On 5.2+ this unwinds with longjmp straight
/// away (no continuation), elsewhere the C function must return the result.
pub fn yieldValues(L: *lua_State, nresults: c_int) c_int {
    switch (lang) {
        .lua51, .luajit, .luau => return c.lua_yield(L, nresults),
        else => return c.lua_yieldk(L, nresults, 0, null),
    }
}

/// Continuation for `callWithContinuation`; receives the `ctx` given to it.
pub const ContinuationFn = fn (L: *lua_State, ctx: isize) c_int;

/// Calls the function below the top `nargs` values (keeping all results)
/// and returns `k(L, ctx)`. Use as `return callWithContinuation(...)` from a
/// C function. On 5.2+ the call may yield: `k` then runs once the coroutine
/// is resumed and the call has returned, with the bound function's own frame
/// gone. Elsewhere a yield inside the call is an error.
pub fn callWithContinuation(L: *lua_State, nargs: c_int, ctx: isize, comptime k: ContinuationFn) c_int {
    switch (lang) {
        .lua52 => {
            c.lua_callk(L, nargs, c.LUA_MULTRET, @intCast(ctx), &K52(k).f);
            return k(L, ctx);
        },
        .lua53, .lua54, .lua55 => {
            c.lua_callk(L, nargs, c.LUA_MULTRET, ctx, &K53(k).f);
            return k(L, ctx);
        },
        else => {
            call(L, nargs, c.LUA_MULTRET);
            return k(L, ctx);
        },
    }
}

fn K52(comptime k: ContinuationFn) type {
    return struct {
        fn f(L: ?*lua_State) callconv(.c) c_int {
            var ctx: c_int = 0;
            _ = c.lua_getctx(L.?, &ctx);
            return k(L.?, ctx);
        }
    };
}

fn K53(comptime k: ContinuationFn) type {
    return struct {
        fn f(L: ?*lua_State, status: c_int, ctx: c.KContext) callconv(.c) c_int {
            _ = status;
            return k(L.?, ctx);
        }
    };
}

/// Pops a table and makes it the global environment of the Lua function at
/// `idx` (a freshly loaded chunk).
pub fn setFunctionEnv(L: *lua_State, idx: c_int) void {
    switch (lang) {
        .lua51, .luajit, .luau => _ = c.lua_setfenv(L, idx),
        else => {
            // From 5.2 on the environment is the chunk's first upvalue, _ENV.
            if (c.lua_setupvalue(L, idx, 1) == null) pop(L, 1);
        },
    }
}

// ---------------------------------------------------------------------------
// Step hook (execution limits)

/// Roughly how many VM instructions run between two calls of the step
/// hook. Luau calls it at every safepoint (loop back edge, call, return).
pub const step_instructions: u64 = if (lang == .luau) 1 else 1000;

/// Called every `step_instructions` instructions while a step hook is set.
/// It may raise a Lua error to stop the running code.
pub const StepFn = *const fn (L: *lua_State) void;

var step_fn: ?StepFn = null;

/// Installs (or with null removes) the step hook. Hooks are per thread on
/// PUC Lua and LuaJIT: coroutines created afterwards inherit it. LuaJIT does
/// not run hooks inside compiled traces, so its JIT compiler is switched off
/// while a hook is set.
pub fn setStepHook(L: *lua_State, f: ?StepFn) void {
    // Shared by every state in the process, so removing one state's hook
    // must not clear it; the hook itself checks whether its state has a limit.
    if (f) |func| step_fn = func;
    switch (lang) {
        .luau => luau.lua_callbacks(L).interrupt = if (f != null) &luauInterrupt else null,
        else => {
            if (lang == .luajit) {
                if (f != null) {
                    _ = c.luaJIT_setmode(L, 0, c.LUAJIT_MODE_ENGINE | c.LUAJIT_MODE_FLUSH);
                    _ = c.luaJIT_setmode(L, 0, c.LUAJIT_MODE_ENGINE | c.LUAJIT_MODE_OFF);
                } else {
                    _ = c.luaJIT_setmode(L, 0, c.LUAJIT_MODE_ENGINE | c.LUAJIT_MODE_ON);
                }
            }
            if (f != null) {
                c.lua_sethook(L, &countHook, c.LUA_MASKCOUNT, @intCast(step_instructions));
            } else {
                c.lua_sethook(L, null, 0, 0);
            }
        },
    }
}

/// Makes the step hook of thread `L` fire every `interval` instructions
/// instead of `step_instructions`. Luau's interrupt already fires at every
/// safepoint, so there it does nothing.
pub fn setStepInterval(L: *lua_State, interval: c_int) void {
    if (lang == .luau) return;
    c.lua_sethook(L, &countHook, c.LUA_MASKCOUNT, interval);
}

fn countHook(L: ?*lua_State, ar: ?*anyopaque) callconv(.c) void {
    _ = ar;
    if (step_fn) |f| f(L.?);
}

fn luauInterrupt(L: ?*lua_State, gc: c_int) callconv(.c) void {
    // During garbage collection the interrupt must not raise.
    if (gc >= 0) return;
    if (step_fn) |f| f(L.?);
}

/// Luau: makes the table at `idx` read-only (or writable). No-op elsewhere.
pub fn setReadonly(L: *lua_State, idx: c_int, enabled: bool) void {
    if (lang == .luau) luau.lua_setreadonly(L, idx, @intFromBool(enabled));
}

/// Luau: whether the table at `idx` is read-only. Always false elsewhere.
pub fn isReadonly(L: *lua_State, idx: c_int) bool {
    if (lang != .luau) return false;
    return luau.lua_getreadonly(L, idx) != 0;
}

/// Luau: marks the environment table at `idx` as safe, enabling the fast
/// paths that resolve globals and builtins at load time. No-op elsewhere.
pub fn setSafeEnv(L: *lua_State, idx: c_int, enabled: bool) void {
    if (lang == .luau) luau.lua_setsafeenv(L, idx, @intFromBool(enabled));
}

/// Luau: `luaL_sandbox`, making the globals and libraries read-only.
pub fn luauSandbox(L: *lua_State) void {
    if (lang == .luau) luau.luaL_sandbox(L);
}

/// The `ud` the state was created with (`newState`), without a registry lookup.
pub fn allocUserdata(L: *lua_State) ?*anyopaque {
    var ud: ?*anyopaque = null;
    _ = c.lua_getallocf(L, &ud);
    return ud;
}

// ---------------------------------------------------------------------------
// Garbage collector

pub fn gcCollect(L: *lua_State) void {
    _ = c.lua_gc(L, c.LUA_GCCOLLECT, @as(c_int, 0));
}

/// Bytes currently allocated by the state.
pub fn gcCount(L: *lua_State) usize {
    const kb: usize = @intCast(c.lua_gc(L, c.LUA_GCCOUNT, @as(c_int, 0)));
    const rest: usize = @intCast(c.lua_gc(L, c.LUA_GCCOUNTB, @as(c_int, 0)));
    return kb * 1024 + rest;
}
