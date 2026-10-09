//! Raw declarations for the parts of the Luau C API that differ from Lua 5.1
//! (VM/include/lua.h, lualib.h, Compiler/include/luacode.h). Functions with
//! the same C signature as in PUC Lua are taken from `c.zig`.
//!
//! zilua builds Luau with `LUA_API=extern "C"`, so everything links by its C
//! name, and with `LUA_USE_LONGJMP=1`, so errors unwind with longjmp like in
//! PUC Lua instead of C++ exceptions.

const c = @import("c.zig");

const lua_State = c.lua_State;

// enum lua_Type, with the default LUA_VECTOR_DOUBLE == 0
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TLIGHTUSERDATA: c_int = 2;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TINTEGER: c_int = 4;
pub const LUA_TVECTOR: c_int = 5;
pub const LUA_TSTRING: c_int = 6;
pub const LUA_TTABLE: c_int = 7;
pub const LUA_TFUNCTION: c_int = 8;
pub const LUA_TUSERDATA: c_int = 9;
pub const LUA_TTHREAD: c_int = 10;
pub const LUA_TBUFFER: c_int = 11;

pub const Continuation = *const fn (L: ?*lua_State, status: c_int) callconv(.c) c_int;
pub const Destructor = *const fn (L: ?*lua_State, userdata: ?*anyopaque) callconv(.c) void;
pub const PanicFn = *const fn (L: ?*lua_State, errcode: c_int) callconv(.c) void;

pub const InterruptFn = *const fn (L: ?*lua_State, gc: c_int) callconv(.c) void;

/// The leading fields of `lua_Callbacks`; zilua only touches `interrupt`
/// and `panic`.
pub const Callbacks = extern struct {
    userdata: ?*anyopaque,
    /// Called at safepoints (loop back edges, calls, returns) with gc = -1,
    /// and during collection with gc >= 0, when it must not raise.
    interrupt: ?InterruptFn,
    panic: ?PanicFn,
};

pub extern fn lua_callbacks(L: *lua_State) *Callbacks;
pub extern fn lua_mainthread(L: *lua_State) *lua_State;
pub extern fn lua_setreadonly(L: *lua_State, idx: c_int, enabled: c_int) void;
pub extern fn lua_getreadonly(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_setsafeenv(L: *lua_State, idx: c_int, enabled: c_int) void;
pub extern fn luaL_sandbox(L: *lua_State) void;
pub extern fn lua_tointeger64(L: *lua_State, idx: c_int, isinteger: ?*c_int) i64;
pub extern fn lua_objlen(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_pushcclosurek(L: *lua_State, f: c.CFunction, debugname: ?[*:0]const u8, nup: c_int, cont: ?Continuation) void;
pub extern fn lua_pushlightuserdatatagged(L: *lua_State, p: ?*anyopaque, tag: c_int) void;
pub extern fn lua_newuserdatatagged(L: *lua_State, size: usize, tag: c_int) ?*anyopaque;
pub extern fn lua_newuserdatadtor(L: *lua_State, size: usize, dtor: Destructor) ?*anyopaque;
pub extern fn lua_ref(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_unref(L: *lua_State, ref: c_int) c_int;
pub extern fn lua_pushfstringL(L: *lua_State, fmt: [*:0]const u8, ...) [*:0]const u8;
/// Never returns (`l_noret` in C); declared with a result so callers can `return` it.
pub extern fn luaL_errorL(L: *lua_State, fmt: [*:0]const u8, ...) c_int;
/// Never returns (`l_noret` in C).
pub extern fn luaL_argerrorL(L: *lua_State, narg: c_int, extramsg: [*:0]const u8) c_int;
pub extern fn luau_load(L: *lua_State, chunkname: [*:0]const u8, data: [*]const u8, size: usize, env: c_int) c_int;
/// Returns bytecode allocated with `malloc`; compile errors are encoded in
/// it and reported by `luau_load`.
pub extern fn luau_compile(source: [*]const u8, size: usize, options: ?*anyopaque, outsize: *usize) ?[*]u8;
