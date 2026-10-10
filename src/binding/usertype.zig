//! Exposes Zig structs to Lua as userdata with a metatable generated at
//! comptime from the struct's fields and public declarations.
//!
//! A struct `T` gets one metatable, created on first use:
//! - `__index`: public functions of `T` (methods and static functions), then fields
//! - `__newindex`: assigns fields, converting the value to the field's type
//! - `__gc`: finalizes values owned by Lua, through `T.__gc` or `T.deinit`
//!   (on Luau, which has no `__gc`, a userdata destructor does the same)
//! - `__tostring`, `__eq`: defaults unless `T` declares its own
//! - any other `pub fn __name` declared by `T` (`__add`, `__len`, `__call`, ...)

const std = @import("std");
const api = @import("../runtime/api.zig");
const bind = @import("bind.zig");
const convert = @import("convert.zig");

const lua_State = api.lua_State;

/// Every zilua userdata starts with this header.
pub const Header = extern struct {
    /// The Zig value: the payload stored in this userdata for owned values,
    /// the referenced object for references.
    ptr: *anyopaque,
    /// The value lives in this userdata and is finalized by `__gc`.
    owned: bool,
    /// Created from a `*const T`: Lua may read the value but not modify it.
    read_only: bool,
    /// The value must not be used any more: its finalizer has run (a later
    /// finalizer may still resurrect the userdata), or the Zig object of a
    /// reference was detached with `invalidate`.
    dead: bool = false,
};

/// Registry name of the metatable of `T` (as with `luaL_newmetatable`, for
/// C code that wants to check zilua userdata).
pub fn metatableName(comptime T: type) [:0]const u8 {
    return "zilua:" ++ @typeName(T);
}

fn TypeKey(comptime T: type) type {
    return struct {
        // One per T: generic types are instantiated once per argument.
        var key: u8 = 0;
        comptime {
            _ = T;
        }
    };
}

/// Registry key of the metatable of `T`: a light userdata, cheaper to look
/// up than the name.
fn typeKey(comptime T: type) *const anyopaque {
    return &TypeKey(T).key;
}

/// Name shown to Lua: `T.zilua_name` if declared, otherwise the last component
/// of `@typeName(T)` ("Vec2" for "game.math.Vec2").
pub fn displayName(comptime T: type) [:0]const u8 {
    if (@hasDecl(T, "zilua_name")) return T.zilua_name;
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        const full = @typeName(T);
        var start: usize = 0;
        var depth: usize = 0;
        for (full, 0..) |ch, i| {
            switch (ch) {
                '(' => depth += 1,
                ')' => depth -= 1,
                '.' => if (depth == 0) {
                    start = i + 1;
                },
                else => {},
            }
        }
        break :blk full[start..];
    };
}

fn validate(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".is_tuple) @compileError("zilua: usertypes must be structs, got " ++ @typeName(T));
    for ([_][]const u8{ "__index", "__newindex" }) |reserved| {
        if (@hasDecl(T, reserved)) @compileError("zilua: " ++ @typeName(T) ++ " declares " ++ reserved ++ ", which zilua generates");
    }
}

// ---------------------------------------------------------------------------
// Finalization

const Finalizer = enum {
    none,
    /// `pub fn __gc(self: *T) void`
    gc_decl,
    /// `pub fn deinit(self: *T) void` or `*const T`
    deinit_ptr,
    /// `pub fn deinit(self: T) void`
    deinit_value,
    /// No `deinit`, but fields holding handles (`Table`, ...), which the Lua
    /// object owns and zilua releases.
    handles,
    /// `deinit` exists but takes more than `self`, so Lua cannot call it.
    unsupported,
};

fn finalizer(comptime T: type) Finalizer {
    if (@hasDecl(T, "__gc")) {
        const F = @typeInfo(@TypeOf(T.__gc)).@"fn";
        const ok = !F.is_generic and F.param_types.len == 1 and F.param_types[0].? == *T and F.return_type.? == void;
        if (!ok) @compileError("zilua: " ++ @typeName(T) ++ ".__gc must be `pub fn __gc(self: *" ++ @typeName(T) ++ ") void`");
        return .gc_decl;
    }
    if (@hasDecl(T, "deinit")) {
        const info = @typeInfo(@TypeOf(T.deinit));
        if (info != .@"fn") return .none;
        const F = info.@"fn";
        if (F.is_generic or F.param_types.len != 1 or F.return_type.? != void) return .unsupported;
        const Self = F.param_types[0].?;
        if (Self == *T or Self == *const T) return .deinit_ptr;
        if (Self == T) return .deinit_value;
        return .unsupported;
    }
    return if (hasHandleFields(T)) .handles else .none;
}

fn hasHandleFields(comptime T: type) bool {
    for (@typeInfo(T).@"struct".field_types) |FT| {
        if (convert.isHandleLike(FT)) return true;
    }
    return false;
}

/// Whether a bitwise copy of a `T` read from Lua would share something a
/// finalizer releases (memory freed by `deinit`/`__gc`, handles), so that
/// assigning one to a field would give it two owners.
fn copyShares(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .optional => |o| return copyShares(o.child),
        .array => |a| return copyShares(a.child),
        .@"union" => |u| {
            for (u.field_types) |FT| {
                if (copyShares(FT)) return true;
            }
            return false;
        },
        .@"struct" => |s| {
            if (convert.isUsertype(T)) {
                if (finalizer(T) != .none) return true;
            } else if (!s.is_tuple) {
                return false;
            }
            for (s.field_types) |FT| {
                if (copyShares(FT)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Whether Lua can own (and later finalize) values of `T`.
pub fn canOwn(comptime T: type) bool {
    return finalizer(T) != .unsupported;
}

/// Whether `T` can be exposed as a usertype at all.
pub fn isValid(comptime T: type) bool {
    return !@hasDecl(T, "__index") and !@hasDecl(T, "__newindex");
}

/// Declarations not exposed to Lua: the finalizer zilua calls itself, and
/// `deinit` in any form, since calling it from Lua would let the object be
/// destroyed twice (or used after being destroyed).
fn isHiddenDecl(comptime T: type, comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "deinit")) return true;
    return finalizer(T) == .gc_decl and std.mem.eql(u8, name, "__gc");
}

// ---------------------------------------------------------------------------
// Pushing and checking

fn ownedSize(comptime T: type) usize {
    // Lua aligns userdata at least like a pointer; stricter types need padding.
    const padding = if (@alignOf(T) > @alignOf(Header)) @alignOf(T) - @alignOf(Header) else 0;
    return @sizeOf(Header) + padding + @sizeOf(T);
}

fn payloadPtr(comptime T: type, raw: *anyopaque) *T {
    const addr = std.mem.Alignment.of(T).forward(@intFromPtr(raw) + @sizeOf(Header));
    return @ptrFromInt(addr);
}

/// Pushes a userdata that owns a copy of `value`. Lua finalizes it when collected.
pub fn pushOwned(L: *lua_State, comptime T: type, value: T) void {
    comptime validate(T);
    if (comptime finalizer(T) == .unsupported) {
        @compileError("zilua: " ++ @typeName(T) ++ ".deinit takes more than `self`, so Lua cannot finalize owned values. " ++
            "Declare `pub fn __gc(self: *" ++ @typeName(T) ++ ") void`, or push a pointer instead.");
    }
    const needs_dtor = comptime api.has_userdata_dtor and finalizer(T) != .none;
    const raw = if (needs_dtor) api.newUserdataDtor(L, ownedSize(T), dtorFn(T)) else api.newUserdata(L, ownedSize(T));
    const payload = payloadPtr(T, raw);
    payload.* = value;
    const header: *Header = @ptrCast(@alignCast(raw));
    header.* = .{ .ptr = payload, .owned = true, .read_only = false };
    pushMetatable(L, T);
    api.setMetatable(L, -2);
}

/// Slots of the metatable holding the reference caches (see `pushRef`).
const cache_mutable = 1;
const cache_read_only = 2;

/// Pushes a userdata that refers to `ptr` (`*T` or `*const T`). Zig keeps
/// ownership: the object must outlive every use from Lua, or be detached
/// with `invalidate` first. Lua gets one userdata per object, type and
/// mutability, which is how `invalidate` finds it.
pub fn pushRef(L: *lua_State, comptime T: type, ptr: anytype, read_only: bool) void {
    comptime validate(T);
    const mutable: *T = @constCast(ptr);
    pushMetatable(L, T);
    _ = api.rawGetI(L, -1, if (read_only) cache_read_only else cache_mutable);
    if (api.rawGetP(L, -1, mutable) != .userdata) {
        api.pop(L, 1);
        const header: *Header = @ptrCast(@alignCast(api.newUserdata(L, @sizeOf(Header))));
        header.* = .{ .ptr = mutable, .owned = false, .read_only = read_only };
        api.pushValue(L, -3);
        api.setMetatable(L, -2);
        api.pushValue(L, -1);
        api.rawSetP(L, -3, mutable);
    }
    // metatable, cache, userdata -> userdata
    api.insert(L, -3);
    api.pop(L, 2);
}

/// Detaches Lua from the Zig object at `ptr`: the references Lua holds to
/// it, and to the struct fields inside it, die, and every later use of them
/// raises an error. Call it before the object goes away.
pub fn invalidate(L: *lua_State, comptime T: type, ptr: *const T) void {
    if (api.rawGetP(L, api.registry_index, typeKey(T)) == .table) {
        inline for (.{ cache_mutable, cache_read_only }) |slot| {
            _ = api.rawGetI(L, -1, slot);
            if (api.rawGetP(L, -1, ptr) == .userdata) {
                const header: *Header = @ptrCast(@alignCast(api.toUserdata(L, -1).?));
                header.dead = true;
                api.pushNil(L);
                api.rawSetP(L, -3, ptr);
            }
            api.pop(L, 2);
        }
    }
    api.pop(L, 1);
    // Usertype fields are handed out as references into the object.
    const info = @typeInfo(T).@"struct";
    if (info.layout == .@"packed") return;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
        if (comptime !attrs.@"comptime" and convert.isUsertype(FT) and isValid(FT)) {
            invalidate(L, FT, &@field(ptr.*, name));
        }
    }
}

/// The header of the value at `idx` if it is a `T` userdata created by zilua
/// that is still alive (see `Header.dead`).
pub fn check(L: *lua_State, comptime T: type, idx: c_int) ?*Header {
    const header = headerOf(L, T, idx) orelse return null;
    return if (header.dead) null else header;
}

/// Whether the value at `idx` is a `T` userdata that `check` refuses only
/// because it is dead.
pub fn isDead(L: *lua_State, comptime T: type, idx: c_int) bool {
    const header = headerOf(L, T, idx) orelse return false;
    return header.dead;
}

/// The header of the value at `idx` if it is a `T` userdata created by
/// zilua, dead or alive.
fn headerOf(L: *lua_State, comptime T: type, idx: c_int) ?*Header {
    if (api.typeOf(L, idx) != .userdata) return null;
    if (!api.getMetatable(L, idx)) return null;
    _ = api.rawGetP(L, api.registry_index, typeKey(T));
    const same = api.rawEqual(L, -1, -2);
    api.pop(L, 2);
    if (!same) return null;
    return @ptrCast(@alignCast(api.toUserdata(L, idx).?));
}

/// Like `headerOf`, comparing with the metatable at `mt` (an upvalue of the
/// metamethods) instead of looking it up in the registry.
fn headerWith(L: *lua_State, idx: c_int, mt: c_int) ?*Header {
    if (api.typeOf(L, idx) != .userdata) return null;
    if (!api.getMetatable(L, idx)) return null;
    const same = api.rawEqual(L, -1, mt);
    api.pop(L, 1);
    if (!same) return null;
    return @ptrCast(@alignCast(api.toUserdata(L, idx).?));
}

fn raiseDead(L: *lua_State, comptime T: type) c_int {
    return api.raiseF(L, "%s no longer exists", displayName(T).ptr);
}

/// Makes the userdata at `child` keep the value at `parent` alive, for
/// references into the parent's memory.
fn anchor(L: *lua_State, child: c_int, parent: c_int) void {
    const child_idx = api.absIndex(L, child);
    const parent_idx = api.absIndex(L, parent);
    if (comptime api.user_value_must_be_table) {
        api.createTable(L, 1, 0);
        api.pushValue(L, parent_idx);
        api.rawSetI(L, -2, 1);
    } else {
        api.pushValue(L, parent_idx);
    }
    api.setUserValue(L, child_idx);
}

// ---------------------------------------------------------------------------
// Metatable

/// Pushes the metatable of `T`, creating it on first use.
pub fn pushMetatable(L: *lua_State, comptime T: type) void {
    comptime validate(T);
    if (api.rawGetP(L, api.registry_index, typeKey(T)) == .table) return;
    api.pop(L, 1);
    _ = api.newMetatable(L, metatableName(T).ptr);
    const mt = api.getTop(L);
    api.pushValue(L, mt);
    api.rawSetP(L, api.registry_index, typeKey(T));

    // Reference caches (see `pushRef`), with weak values so that they keep
    // no reference alive.
    inline for (.{ cache_mutable, cache_read_only }) |slot| {
        api.newTable(L);
        api.newTable(L);
        api.pushString(L, "v");
        api.setField(L, -2, "__mode");
        api.setMetatable(L, -2);
        api.rawSetI(L, mt, slot);
    }

    api.pushString(L, displayName(T));
    api.setField(L, mt, "__name");
    // getmetatable() returns the name instead, so scripts can neither call
    // __gc themselves nor change the metatable every value shares.
    api.pushString(L, displayName(T));
    api.setField(L, mt, "__metatable");
    if (comptime api.lang == .luau) {
        // What Luau's typeof() returns.
        api.pushString(L, displayName(T));
        api.setField(L, mt, "__type");
    }

    // Upvalues: the function table, then the metatable itself for checks.
    pushFunctionTable(L, T);
    api.pushValue(L, mt);
    api.pushCClosure(L, indexFn(T), 2);
    api.setField(L, mt, "__index");

    api.pushValue(L, mt);
    api.pushCClosure(L, newIndexFn(T), 1);
    api.setField(L, mt, "__newindex");

    switch (comptime finalizer(T)) {
        .gc_decl, .deinit_ptr, .deinit_value, .handles => {
            api.pushCFunction(L, gcFn(T));
            api.setField(L, mt, "__gc");
        },
        .none, .unsupported => {},
    }

    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        if (comptime isBindable(T, name) and isMetamethodName(name) and !isHiddenDecl(T, name)) {
            bind.push(L, @field(T, name), name.ptr);
            api.setField(L, mt, name.ptr);
        }
    }

    if (!@hasDecl(T, "__tostring")) {
        api.pushCFunction(L, toStringFn(T));
        api.setField(L, mt, "__tostring");
    }
    if (!@hasDecl(T, "__eq")) {
        api.pushCFunction(L, eqFn(T));
        api.setField(L, mt, "__eq");
    }
}

/// Public functions of `T` whose parameter and return types zilua can
/// convert. Others are silently left out, like fields of unsupported types.
fn isBindable(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name)) return false;
    const F = @TypeOf(@field(T, name));
    return @typeInfo(F) == .@"fn" and bind.isWrappable(F);
}

fn isMetamethodName(comptime name: []const u8) bool {
    return name.len > 2 and name[0] == '_' and name[1] == '_';
}

/// Pushes a table with the public functions of `T`, excluding metamethods.
pub fn pushFunctionTable(L: *lua_State, comptime T: type) void {
    api.newTable(L);
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        if (comptime isBindable(T, name) and !isMetamethodName(name) and !isHiddenDecl(T, name)) {
            bind.push(L, @field(T, name), name.ptr);
            api.setField(L, -2, name.ptr);
        }
    }
}

/// Makes `T` reachable from Lua as global `name`: a table with the public
/// functions of `T`, so that `Vec2.init(1, 2)` calls `Vec2.init`.
pub fn register(L: *lua_State, comptime T: type, name: [*:0]const u8) void {
    pushMetatable(L, T);
    api.pop(L, 1);
    pushFunctionTable(L, T);
    api.setGlobal(L, name);
}

fn indexFn(comptime T: type) api.CFunction {
    return &struct {
        fn index(L_: ?*lua_State) callconv(.c) c_int {
            const L = L_.?;
            // Functions first: upvalue 1 is the function table.
            api.pushValue(L, 2);
            if (api.rawGet(L, api.upvalueIndex(1)) != .nil) return 1;
            api.pop(L, 1);

            if (api.typeOf(L, 2) != .string) return 0;
            const key = api.toLString(L, 2).?;
            const header = headerWith(L, 1, api.upvalueIndex(2)) orelse return 0;
            if (header.dead) return raiseDead(L, T);
            const self: *T = @ptrCast(@alignCast(header.ptr));
            const info = @typeInfo(T).@"struct";
            // Fields of a packed struct have no addressable memory of their own.
            const by_ref = info.layout != .@"packed";
            inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
                // Fields of types zilua cannot convert are invisible to Lua.
                // Usertype fields are pushed as references, which Lua never finalizes.
                if (comptime !(convert.canPush(FT) or (by_ref and convert.isUsertype(FT) and isValid(FT)))) continue;
                if (std.mem.eql(u8, key, name)) {
                    if (attrs.@"comptime") {
                        convert.push(L, @field(self.*, name));
                    } else if (comptime by_ref and convert.isUsertype(FT)) {
                        // A reference into the parent rather than a copy, so
                        // that `body.pos.x = 1` modifies `body`.
                        pushRef(L, FT, &@field(self.*, name), header.read_only);
                        anchor(L, -1, 1);
                    } else {
                        convert.push(L, @field(self.*, name));
                    }
                    return 1;
                }
            }
            return 0;
        }
    }.index;
}

fn newIndexFn(comptime T: type) api.CFunction {
    return &struct {
        fn newIndex(L_: ?*lua_State) callconv(.c) c_int {
            const L = L_.?;
            const name_z = displayName(T).ptr;
            const header = headerWith(L, 1, api.upvalueIndex(1)) orelse return api.raiseF(L, "%s expected", name_z);
            if (header.dead) return raiseDead(L, T);
            if (header.read_only) return api.raiseF(L, "attempt to modify a read-only %s", name_z);
            if (api.typeOf(L, 2) != .string) return api.raiseF(L, "%s fields are indexed by name, got %s", name_z, api.typeName(L, 2));
            const key = api.toLString(L, 2).?;
            const self: *T = @ptrCast(@alignCast(header.ptr));
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
                if (std.mem.eql(u8, key, name)) {
                    if (comptime attrs.@"comptime" or convert.isBorrowed(FT) or !convert.canRead(FT) or copyShares(FT)) {
                        return api.raiseF(L, "field '%s' of %s cannot be set from Lua", name.ptr, name_z);
                    } else {
                        const value = convert.to(FT, L, 3) catch {
                            return api.raiseF(L, "bad value for field '%s' of %s (%s expected, got %s)", name.ptr, name_z, convert.typeName(FT).ptr, api.typeName(L, 3));
                        };
                        // A Lua-owned object owns the handles in its fields.
                        if (comptime convert.isHandleLike(FT)) {
                            if (header.owned) convert.releaseHandle(@field(self.*, name));
                        }
                        @field(self.*, name) = value;
                        return 0;
                    }
                }
            }
            // Lua strings are NUL-terminated, so key.ptr is a valid C string.
            return api.raiseF(L, "%s has no field '%s'", name_z, key.ptr);
        }
    }.newIndex;
}

fn gcFn(comptime T: type) api.CFunction {
    return &struct {
        fn gc(L_: ?*lua_State) callconv(.c) c_int {
            const header = check(L_.?, T, 1) orelse return 0;
            finalize(T, header, false);
            return 0;
        }
    }.gc;
}

/// Luau's replacement for `__gc`, given to `api.newUserdataDtor`.
fn dtorFn(comptime T: type) api.Destructor {
    return &struct {
        fn dtor(L: ?*lua_State, userdata: ?*anyopaque) callconv(.c) void {
            _ = L;
            // During a Luau collection the API is off limits, so handle
            // fields are released later (see State.deferUnref).
            finalize(T, @ptrCast(@alignCast(userdata.?)), true);
        }
    }.dtor;
}

fn finalize(comptime T: type, header: *Header, deferred: bool) void {
    if (!header.owned) return;
    // Finalize once, even if a later finalizer resurrects the object, and
    // make every later use of it fail (`check`).
    header.owned = false;
    header.dead = true;
    const self: *T = @ptrCast(@alignCast(header.ptr));
    switch (comptime finalizer(T)) {
        .gc_decl => T.__gc(self),
        .deinit_ptr => T.deinit(self),
        .deinit_value => T.deinit(self.*),
        .handles => releaseHandleFields(T, self, deferred),
        .none, .unsupported => {},
    }
}

/// Releases the handles in the fields of a Lua-owned value. Types with their
/// own `deinit` or `__gc` manage their fields themselves.
fn releaseHandleFields(comptime T: type, self: *T, deferred: bool) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
        if (comptime !attrs.@"comptime" and convert.isHandleLike(FT)) {
            if (convert.handleRef(@field(self.*, name))) |r| {
                if (deferred) r.state.deferUnref(r.id) else r.deinit();
            }
        }
    }
}

fn toStringFn(comptime T: type) api.CFunction {
    return &struct {
        fn toString(L_: ?*lua_State) callconv(.c) c_int {
            const L = L_.?;
            const header = headerOf(L, T, 1) orelse return api.raiseF(L, "%s expected", displayName(T).ptr);
            if (header.dead) {
                _ = api.pushFString(L, "%s (no longer exists)", displayName(T).ptr);
            } else {
                _ = api.pushFString(L, "%s: %p", displayName(T).ptr, header.ptr);
            }
            return 1;
        }
    }.toString;
}

/// Two userdata are equal when they refer to the same Zig object.
fn eqFn(comptime T: type) api.CFunction {
    return &struct {
        fn eq(L_: ?*lua_State) callconv(.c) c_int {
            const L = L_.?;
            const a = check(L, T, 1);
            const b = check(L, T, 2);
            api.pushBoolean(L, a != null and b != null and a.?.ptr == b.?.ptr);
            return 1;
        }
    }.eq;
}
