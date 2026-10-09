//! Raw Lua C API declarations for the runtime selected with `-Dlang`.
//!
//! Hand-written rather than produced by `zig translate-c`: Zig 0.17 has no
//! `@cImport`, most of the Lua API is macros that translate-c cannot turn into
//! functions, and the signatures differ between runtimes. Declaring every
//! function here is safe because Zig only resolves an `extern fn` when code
//! actually references it, so declarations for other runtimes cost nothing.
//!
//! Luau-only functions live in `luau.zig`; the ones Luau shares with Lua 5.1
//! are declared here.
//!
//! Do not call these directly from the rest of zilua. Go through `api.zig`,
//! which hides the differences between runtimes.

const std = @import("std");
const Lang = @import("lang.zig").Lang;

pub const lang: Lang = @field(Lang, @import("zilua_options").lang);

const v52_plus = switch (lang) {
    .lua52, .lua53, .lua54, .lua55 => true,
    .lua51, .luajit, .luau => false,
};
const v53_plus = switch (lang) {
    .lua53, .lua54, .lua55 => true,
    .lua51, .lua52, .luajit, .luau => false,
};
const v54_plus = switch (lang) {
    .lua54, .lua55 => true,
    .lua51, .lua52, .lua53, .luajit, .luau => false,
};

// ---------------------------------------------------------------------------
// Types

pub const lua_State = opaque {};

pub const Number = f64;

/// `lua_Integer`: `ptrdiff_t` before 5.3, `long long` from 5.3 on (the default
/// `luaconf.h` uses `long long` on every platform, Windows included).
pub const Integer = switch (lang) {
    .lua51, .lua52, .luajit => isize,
    .lua53, .lua54, .lua55 => i64,
    .luau => c_int,
};

/// Continuation context: `int` in 5.2, `intptr_t` from 5.3 on.
pub const KContext = switch (lang) {
    .lua52 => c_int,
    .lua53, .lua54, .lua55 => isize,
    .lua51, .luajit, .luau => void,
};

pub const CFunction = *const fn (L: ?*lua_State) callconv(.c) c_int;

pub const KFunction = switch (lang) {
    // 5.2 continuations are plain C functions that call lua_getctx.
    .lua52 => CFunction,
    .lua53, .lua54, .lua55 => *const fn (L: ?*lua_State, status: c_int, ctx: KContext) callconv(.c) c_int,
    .lua51, .luajit, .luau => void,
};

pub const Alloc = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;

pub const Reader = *const fn (L: ?*lua_State, data: ?*anyopaque, size: *usize) callconv(.c) ?[*]const u8;

/// Return type of `lua_getfield` and friends: `void` before 5.3, then the
/// type tag of the pushed value.
const GetResult = if (v53_plus) c_int else void;

/// `lua_pushstring`/`lua_pushlstring` return the interned copy from 5.2 on.
const PushStringResult = if (v52_plus) [*:0]const u8 else void;

/// Integer key type of `lua_rawgeti`/`lua_rawseti`.
const RawIndex = if (v53_plus) Integer else c_int;

/// `lua_rawlen` returns `lua_Unsigned` from 5.4 on, `size_t` before.
const RawLength = if (v54_plus) u64 else usize;

// ---------------------------------------------------------------------------
// Constants

pub const LUA_MULTRET: c_int = -1;

pub const LUA_REGISTRYINDEX: c_int = switch (lang) {
    .lua51, .luajit, .luau => -10000,
    // -LUAI_MAXSTACK - 1000 with LUAI_MAXSTACK = 1000000
    .lua52, .lua53, .lua54 => -1001000,
    // -(INT_MAX/2 + 1000)
    .lua55 => -(std.math.maxInt(c_int) / 2 + 1000),
};

/// Only meaningful for the 5.1 API family (see `Lang.usesGlobalsIndex`).
pub const LUA_GLOBALSINDEX: c_int = -10002;

/// Registry slot of the globals table (5.2+).
pub const LUA_RIDX_GLOBALS: c_int = 2;
/// Registry slot of the main thread (5.2+).
pub const LUA_RIDX_MAINTHREAD: c_int = if (lang == .lua55) 3 else 1;

pub const LUA_TNONE: c_int = -1;
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TLIGHTUSERDATA: c_int = 2;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;
pub const LUA_TFUNCTION: c_int = 6;
pub const LUA_TUSERDATA: c_int = 7;
pub const LUA_TTHREAD: c_int = 8;

pub const LUA_OK: c_int = 0;
pub const LUA_YIELD: c_int = 1;
pub const LUA_ERRRUN: c_int = 2;
pub const LUA_ERRSYNTAX: c_int = 3;
pub const LUA_ERRMEM: c_int = 4;
/// 5.2 and 5.3 only: error while running a `__gc` metamethod.
pub const LUA_ERRGCMM: c_int = 5;
pub const LUA_ERRERR: c_int = switch (lang) {
    .lua52, .lua53 => 6,
    .lua51, .lua54, .lua55, .luajit, .luau => 5,
};
pub const LUA_ERRFILE: c_int = LUA_ERRERR + 1;

pub const LUA_GCCOLLECT: c_int = 2;
pub const LUA_GCCOUNT: c_int = 3;
pub const LUA_GCCOUNTB: c_int = 4;

pub const LUA_NOREF: c_int = -2;
pub const LUA_REFNIL: c_int = -1;

/// Value of `LUAL_NUMSIZES` that `luaL_checkversion_` expects (5.3+).
pub const LUAL_NUMSIZES: usize = @sizeOf(Integer) * 16 + @sizeOf(Number);

pub const LUA_VERSION_NUM: Number = switch (lang) {
    .lua51, .luajit, .luau => 501,
    .lua52 => 502,
    .lua53 => 503,
    .lua54 => 504,
    .lua55 => 505,
};

// ---------------------------------------------------------------------------
// State manipulation

// Functions whose signature differs between runtimes are bound with @extern
// so that each variant can keep the real C symbol name.
pub const lua_newstate = if (lang == .lua55) lua_newstate_55 else lua_newstate_51;
const lua_newstate_51 = @extern(*const fn (f: Alloc, ud: ?*anyopaque) callconv(.c) ?*lua_State, .{ .name = "lua_newstate" });
const lua_newstate_55 = @extern(*const fn (f: Alloc, ud: ?*anyopaque, seed: c_uint) callconv(.c) ?*lua_State, .{ .name = "lua_newstate" });

pub extern fn lua_close(L: *lua_State) void;
pub extern fn lua_newthread(L: *lua_State) ?*lua_State;
pub extern fn lua_atpanic(L: *lua_State, panicf: ?CFunction) ?CFunction;
pub extern fn lua_getallocf(L: *lua_State, ud: ?*?*anyopaque) Alloc;

// ---------------------------------------------------------------------------
// Basic stack manipulation

pub extern fn lua_absindex(L: *lua_State, idx: c_int) c_int; // 5.2+
pub extern fn lua_gettop(L: *lua_State) c_int;
pub extern fn lua_settop(L: *lua_State, idx: c_int) void;
pub extern fn lua_pushvalue(L: *lua_State, idx: c_int) void;
pub extern fn lua_rotate(L: *lua_State, idx: c_int, n: c_int) void; // 5.3+
pub extern fn lua_insert(L: *lua_State, idx: c_int) void; // 5.1, 5.2
pub extern fn lua_remove(L: *lua_State, idx: c_int) void; // 5.1, 5.2
pub extern fn lua_replace(L: *lua_State, idx: c_int) void; // 5.1, 5.2
pub extern fn lua_copy(L: *lua_State, fromidx: c_int, toidx: c_int) void; // 5.2+
pub extern fn lua_checkstack(L: *lua_State, n: c_int) c_int;
pub extern fn lua_xmove(from: *lua_State, to: *lua_State, n: c_int) void;

// ---------------------------------------------------------------------------
// Access functions (stack -> C)

pub extern fn lua_isnumber(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_isstring(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_iscfunction(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_isinteger(L: *lua_State, idx: c_int) c_int; // 5.3+
pub extern fn lua_isuserdata(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_type(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_typename(L: *lua_State, tp: c_int) [*:0]const u8;

pub extern fn lua_tonumber(L: *lua_State, idx: c_int) Number; // 5.1
pub extern fn lua_tointeger(L: *lua_State, idx: c_int) Integer; // 5.1
pub extern fn lua_tonumberx(L: *lua_State, idx: c_int, isnum: ?*c_int) Number; // 5.2+
pub extern fn lua_tointegerx(L: *lua_State, idx: c_int, isnum: ?*c_int) Integer; // 5.2+
pub extern fn lua_toboolean(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_tolstring(L: *lua_State, idx: c_int, len: ?*usize) ?[*:0]const u8;
pub extern fn lua_objlen(L: *lua_State, idx: c_int) usize; // 5.1
pub extern fn lua_rawlen(L: *lua_State, idx: c_int) RawLength; // 5.2+
pub extern fn lua_tocfunction(L: *lua_State, idx: c_int) ?CFunction;
pub extern fn lua_touserdata(L: *lua_State, idx: c_int) ?*anyopaque;
pub extern fn lua_tothread(L: *lua_State, idx: c_int) ?*lua_State;
pub extern fn lua_topointer(L: *lua_State, idx: c_int) ?*const anyopaque;

pub extern fn lua_rawequal(L: *lua_State, idx1: c_int, idx2: c_int) c_int;

// ---------------------------------------------------------------------------
// Push functions (C -> stack)

pub extern fn lua_pushnil(L: *lua_State) void;
pub extern fn lua_pushnumber(L: *lua_State, n: Number) void;
pub extern fn lua_pushinteger(L: *lua_State, n: Integer) void;
pub extern fn lua_pushlstring(L: *lua_State, s: [*]const u8, len: usize) PushStringResult;
pub extern fn lua_pushstring(L: *lua_State, s: ?[*:0]const u8) PushStringResult;
pub extern fn lua_pushfstring(L: *lua_State, fmt: [*:0]const u8, ...) [*:0]const u8;
pub extern fn lua_pushcclosure(L: *lua_State, f: CFunction, n: c_int) void;
pub extern fn lua_pushboolean(L: *lua_State, b: c_int) void;
pub extern fn lua_pushlightuserdata(L: *lua_State, p: ?*anyopaque) void;
pub extern fn lua_pushthread(L: *lua_State) c_int;

// ---------------------------------------------------------------------------
// Get functions (Lua -> stack)

pub extern fn lua_getglobal(L: *lua_State, name: [*:0]const u8) GetResult; // 5.2+
pub extern fn lua_gettable(L: *lua_State, idx: c_int) GetResult;
pub extern fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) GetResult;
pub extern fn lua_rawget(L: *lua_State, idx: c_int) GetResult;
pub extern fn lua_rawgeti(L: *lua_State, idx: c_int, n: RawIndex) GetResult;
pub extern fn lua_rawgetp(L: *lua_State, idx: c_int, p: ?*const anyopaque) GetResult; // 5.2+
pub extern fn lua_createtable(L: *lua_State, narr: c_int, nrec: c_int) void;
pub extern fn lua_newuserdata(L: *lua_State, size: usize) ?*anyopaque; // 5.1-5.3
pub extern fn lua_newuserdatauv(L: *lua_State, size: usize, nuvalue: c_int) ?*anyopaque; // 5.4+
pub extern fn lua_getmetatable(L: *lua_State, objindex: c_int) c_int;
pub extern fn lua_getfenv(L: *lua_State, idx: c_int) void; // 5.1
pub extern fn lua_getuservalue(L: *lua_State, idx: c_int) GetResult; // 5.2, 5.3
pub extern fn lua_getiuservalue(L: *lua_State, idx: c_int, n: c_int) c_int; // 5.4+

// ---------------------------------------------------------------------------
// Set functions (stack -> Lua)

pub extern fn lua_setglobal(L: *lua_State, name: [*:0]const u8) void; // 5.2+
pub extern fn lua_settable(L: *lua_State, idx: c_int) void;
pub extern fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_rawset(L: *lua_State, idx: c_int) void;
pub extern fn lua_rawseti(L: *lua_State, idx: c_int, n: RawIndex) void;
pub extern fn lua_rawsetp(L: *lua_State, idx: c_int, p: ?*const anyopaque) void; // 5.2+
pub extern fn lua_setmetatable(L: *lua_State, objindex: c_int) c_int;
pub extern fn lua_setfenv(L: *lua_State, idx: c_int) c_int; // 5.1
pub extern fn lua_setuservalue(L: *lua_State, idx: c_int) void; // 5.2, 5.3
pub extern fn lua_setiuservalue(L: *lua_State, idx: c_int, n: c_int) c_int; // 5.4+

// ---------------------------------------------------------------------------
// Load and call

pub extern fn lua_call(L: *lua_State, nargs: c_int, nresults: c_int) void; // 5.1
pub extern fn lua_pcall(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int; // 5.1
pub extern fn lua_callk(L: *lua_State, nargs: c_int, nresults: c_int, ctx: KContext, k: ?KFunction) void; // 5.2+
pub extern fn lua_getctx(L: *lua_State, ctx: ?*c_int) c_int; // 5.2
pub extern fn lua_pcallk(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: KContext, k: ?KFunction) c_int; // 5.2+

// ---------------------------------------------------------------------------
// Coroutines

pub const lua_resume = switch (lang) {
    .lua51, .luajit => lua_resume_51,
    .lua52, .lua53, .luau => lua_resume_52,
    .lua54, .lua55 => lua_resume_54,
};
const lua_resume_51 = @extern(*const fn (L: *lua_State, narg: c_int) callconv(.c) c_int, .{ .name = "lua_resume" });
const lua_resume_52 = @extern(*const fn (L: *lua_State, from: ?*lua_State, narg: c_int) callconv(.c) c_int, .{ .name = "lua_resume" });
const lua_resume_54 = @extern(*const fn (L: *lua_State, from: ?*lua_State, narg: c_int, nres: *c_int) callconv(.c) c_int, .{ .name = "lua_resume" });

pub extern fn lua_yield(L: *lua_State, nresults: c_int) c_int; // 5.1
pub extern fn lua_yieldk(L: *lua_State, nresults: c_int, ctx: KContext, k: ?KFunction) c_int; // 5.2+
pub extern fn lua_status(L: *lua_State) c_int;

// ---------------------------------------------------------------------------
// Garbage collection and miscellaneous

pub const lua_gc = if (v54_plus) lua_gc_54 else lua_gc_51;
const lua_gc_51 = @extern(*const fn (L: *lua_State, what: c_int, data: c_int) callconv(.c) c_int, .{ .name = "lua_gc" });
const lua_gc_54 = @extern(*const fn (L: *lua_State, what: c_int, ...) callconv(.c) c_int, .{ .name = "lua_gc" });

// ---------------------------------------------------------------------------
// Debug interface

pub const Hook = *const fn (L: ?*lua_State, ar: ?*anyopaque) callconv(.c) void;

pub const LUA_MASKCOUNT: c_int = 1 << 3;

/// Returns int before 5.3 and void after; declared void, the result is unused.
pub extern fn lua_sethook(L: *lua_State, func: ?Hook, mask: c_int, count: c_int) void;
pub extern fn lua_setupvalue(L: *lua_State, funcindex: c_int, n: c_int) ?[*:0]const u8;

/// LuaJIT only (luajit.h).
pub extern fn luaJIT_setmode(L: *lua_State, idx: c_int, mode: c_int) c_int;
pub const LUAJIT_MODE_ENGINE: c_int = 0;
pub const LUAJIT_MODE_OFF: c_int = 0x0000;
pub const LUAJIT_MODE_ON: c_int = 0x0100;
pub const LUAJIT_MODE_FLUSH: c_int = 0x0200;

pub extern fn lua_error(L: *lua_State) c_int;
pub extern fn lua_next(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_concat(L: *lua_State, n: c_int) void;

// ---------------------------------------------------------------------------
// Auxiliary library (lauxlib.h / lualib.h)

pub extern fn luaL_newstate() ?*lua_State;
pub extern fn luaL_openlibs(L: *lua_State) void; // macro in 5.5
pub extern fn luaL_openselectedlibs(L: *lua_State, load: c_int, preload: c_int) void; // 5.5
pub extern fn luaL_checkversion_(L: *lua_State, ver: Number, sz: usize) void; // 5.3+
pub extern fn luaL_newmetatable(L: *lua_State, tname: [*:0]const u8) c_int;
pub extern fn luaL_testudata(L: *lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque; // 5.2+
pub extern fn luaL_ref(L: *lua_State, t: c_int) c_int;
pub extern fn luaL_unref(L: *lua_State, t: c_int, ref: c_int) void;
pub extern fn luaL_loadbuffer(L: *lua_State, buff: [*]const u8, size: usize, name: [*:0]const u8) c_int; // 5.1
pub extern fn luaL_loadbufferx(L: *lua_State, buff: [*]const u8, size: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int; // 5.2+
pub extern fn luaL_loadfile(L: *lua_State, filename: [*:0]const u8) c_int; // 5.1
pub extern fn luaL_loadfilex(L: *lua_State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int; // 5.2+
pub extern fn luaL_traceback(L: *lua_State, L1: *lua_State, msg: ?[*:0]const u8, level: c_int) void; // 5.2+
pub extern fn luaL_tolstring(L: *lua_State, idx: c_int, len: ?*usize) [*:0]const u8; // 5.2+
pub extern fn luaL_error(L: *lua_State, fmt: [*:0]const u8, ...) c_int;
pub extern fn luaL_argerror(L: *lua_State, arg: c_int, extramsg: [*:0]const u8) c_int;
pub extern fn luaL_where(L: *lua_State, lvl: c_int) void;
