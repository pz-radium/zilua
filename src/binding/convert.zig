//! Conversion between Zig values and Lua stack values, driven by comptime
//! reflection. This is where the type mapping documented in README.md lives.

const std = @import("std");
const api = @import("../runtime/api.zig");
const bind = @import("bind.zig");
const usertype = @import("usertype.zig");
const ref = @import("../core/ref.zig");
const thread = @import("../core/thread.zig");
const State = @import("../core/State.zig");

const lua_State = api.lua_State;

pub const Error = error{
    /// The Lua value has the wrong type.
    TypeMismatch,
    /// A number without an exact integer value where an integer was expected.
    NotAnInteger,
    /// An integer that does not fit the Zig integer type.
    IntegerOutOfRange,
    /// A string or integer that names no value of the Zig enum (or union tag).
    InvalidEnum,
    /// A table converted to a struct lacks a field that has no default value.
    MissingField,
    /// A read-only usertype reference where a mutable `*T` was required.
    ReadOnly,
};

/// Errors of the conversions that allocate (`toAlloc`).
pub const AllocError = Error || error{OutOfMemory};

/// Wraps a value so that `push` builds a Lua table from it (recursively)
/// instead of a userdata. Create with `asTable`.
pub fn AsTable(comptime T: type) type {
    return struct {
        value: T,

        pub const zilua_special = {};
        pub const zilua_as_table = {};
    };
}

pub fn asTable(value: anytype) AsTable(@TypeOf(value)) {
    return .{ .value = value };
}

// ---------------------------------------------------------------------------
// Type classification

/// zilua handle types that wrap a registry reference.
pub fn isRefType(comptime T: type) bool {
    return T == ref.Ref or T == ref.Table or T == ref.Function or T == thread.Thread;
}

/// A handle or an optional handle.
pub fn isHandleLike(comptime T: type) bool {
    return isRefType(T) or (@typeInfo(T) == .optional and isRefType(@typeInfo(T).optional.child));
}

/// zilua's own marker types (AsTable, Yield, CallThen, Args, Job, ...).
fn isSpecial(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zilua_special");
}

fn isAsTable(comptime T: type) bool {
    return isSpecial(T) and @hasDecl(T, "zilua_as_table");
}

/// Pushed as the light userdata in their `ptr` field (scheduler jobs).
fn isLightUserdata(comptime T: type) bool {
    return isSpecial(T) and @hasDecl(T, "zilua_light_userdata");
}

/// std types that only make sense on the Zig side. Bound functions get the
/// state's allocator and `std.Io` injected; elsewhere they are left out.
pub fn isHostType(comptime T: type) bool {
    return T == std.mem.Allocator or T == std.Io or T == std.Io.Writer or T == std.Io.Reader or
        T == std.Io.Dir or T == std.Io.File;
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            .many, .c => p.child == u8 and p.sentinel_ptr != null,
        },
        else => false,
    };
}

/// Types pushed as userdata with a generated metatable: every struct that is
/// not a tuple, a zilua handle, one of zilua's marker types or a std type.
pub fn isUsertype(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| !s.is_tuple and !isRefType(T) and !isSpecial(T) and !isHostType(T) and T != State,
        else => false,
    };
}

/// Whether a value of this type would point into memory owned by Lua when
/// read from the stack, and so must not outlive the stack slot it came from.
pub fn isBorrowed(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| !(p.size == .one and @typeInfo(p.child) == .@"fn"),
        .optional => |o| isBorrowed(o.child),
        .array => |a| isBorrowed(a.child),
        .@"struct" => |s| s.is_tuple and anyBorrowed(s.field_types),
        .@"union" => |u| anyBorrowed(u.field_types),
        else => false,
    };
}

fn anyBorrowed(comptime types: []const type) bool {
    for (types) |T| {
        if (isBorrowed(T)) return true;
    }
    return false;
}

/// Compile error unless values of `T` stay valid after being popped.
pub fn ensureOwned(comptime T: type, comptime what: []const u8) void {
    if (isBorrowed(T)) @compileError("zilua: " ++ what ++ " cannot return " ++ @typeName(T) ++
        ": it would point into Lua memory that is popped before returning. " ++
        "Use the *Alloc variant, which copies it, or read it inside a bound function.");
}

/// Whether `push` accepts values of type `T`. Used to leave out fields and
/// functions zilua cannot convert instead of failing to compile.
pub fn canPush(comptime T: type) bool {
    if (isString(T) or isRefType(T) or isAsTable(T) or isLightUserdata(T)) return true;
    if (isUsertype(T)) return usertype.isValid(T) and usertype.canOwn(T);
    return switch (@typeInfo(T)) {
        .void, .null, .bool, .int, .comptime_int, .float, .comptime_float, .enum_literal => true,
        .@"enum" => true,
        .optional => |o| canPush(o.child),
        .pointer => |p| switch (p.size) {
            .one => (isUsertype(p.child) and usertype.isValid(p.child)) or p.child == anyopaque or
                (@typeInfo(p.child) == .array and canPush(@typeInfo(p.child).array.child)),
            .slice => canPush(p.child),
            .many, .c => false,
        },
        .array => |a| canPush(a.child),
        .@"struct" => |s| s.is_tuple and allCanPush(s.field_types),
        .@"union" => |u| u.tag_type != null and allCanPush(u.field_types),
        else => false,
    };
}

fn allCanPush(comptime types: []const type) bool {
    for (types) |T| {
        if (!canPush(T)) return false;
    }
    return true;
}

/// Whether `to` accepts `T`.
pub fn canRead(comptime T: type) bool {
    if (isString(T)) {
        const p = @typeInfo(T).pointer;
        return p.attrs.@"const" and (p.size == .slice or (p.size == .many and p.sentinel_ptr != null));
    }
    if (isRefType(T)) return true;
    if (isUsertype(T)) return usertype.isValid(T);
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => true,
        .optional => |o| canRead(o.child),
        .pointer => |p| p.size == .one and ((isUsertype(p.child) and usertype.isValid(p.child)) or p.child == anyopaque),
        .array => |a| canRead(a.child) and !isBorrowed(a.child),
        .@"struct" => |s| s.is_tuple and !anyBorrowed(s.field_types) and allCanRead(s.field_types),
        .@"union" => |u| u.tag_type != null and allCanRead(u.field_types),
        else => false,
    };
}

fn allCanRead(comptime types: []const type) bool {
    for (types) |T| {
        if (!canRead(T)) return false;
    }
    return true;
}

/// Name of the Lua type expected for `T`, for error messages.
pub fn typeName(comptime T: type) [:0]const u8 {
    if (comptime isString(T)) return "string";
    if (comptime isUsertype(T)) return usertype.displayName(T);
    return comptime switch (@typeInfo(T)) {
        .bool => "boolean",
        .int, .comptime_int => if (api.has_integers) "integer" else "number",
        .float, .comptime_float => "number",
        .optional => |o| typeName(o.child),
        .@"enum" => "string",
        .pointer => |p| if (isUsertype(p.child)) usertype.displayName(p.child) else "userdata",
        .array, .@"union" => "table",
        .@"struct" => if (T == ref.Function) "function" else if (T == thread.Thread) "thread" else "table",
        else => @typeName(T),
    };
}

// ---------------------------------------------------------------------------
// Zig -> Lua

/// Pushes `value` as one Lua value. See README.md for the mapping.
/// May raise a Lua memory error.
pub fn push(L: *lua_State, value: anytype) void {
    const T = @TypeOf(value);
    if (comptime isString(T)) return pushStringLike(L, value);
    if (comptime isRefType(T)) return value.push(L);
    if (comptime isAsTable(T)) return pushAsTable(L, value.value);
    if (comptime isLightUserdata(T)) return api.pushLightUserdata(L, value.ptr);
    if (comptime isUsertype(T)) return usertype.pushOwned(L, T, value);

    switch (@typeInfo(T)) {
        .void, .null => api.pushNil(L),
        .bool => api.pushBoolean(L, value),
        .comptime_int => {
            if (comptime std.math.minInt(api.Integer) <= value and value <= std.math.maxInt(api.Integer)) {
                api.pushInteger(L, value);
            } else {
                api.pushNumber(L, @floatFromInt(value));
            }
        },
        .int => pushInt(L, value),
        .comptime_float => api.pushNumber(L, value),
        .float => api.pushNumber(L, @floatCast(value)),
        .optional => if (value) |v| push(L, v) else api.pushNil(L),
        .@"enum" => |e| switch (e.mode) {
            .exhaustive => api.pushString(L, @tagName(value)),
            .nonexhaustive => pushInt(L, @backingInt(value)),
        },
        .enum_literal => api.pushString(L, @tagName(value)),
        .pointer => |p| switch (p.size) {
            .one => {
                if (comptime isUsertype(p.child)) {
                    usertype.pushRef(L, p.child, value, p.attrs.@"const");
                } else if (p.child == anyopaque) {
                    api.pushLightUserdata(L, value);
                } else if (@typeInfo(p.child) == .array) {
                    pushArray(L, value);
                } else {
                    @compileError("zilua: cannot push " ++ @typeName(T));
                }
            },
            .slice => pushArray(L, value),
            .many, .c => @compileError("zilua: cannot push " ++ @typeName(T) ++ " (no length)"),
        },
        .array => pushArray(L, &value),
        .@"struct" => |s| {
            if (!s.is_tuple) @compileError("zilua: cannot push " ++ @typeName(T));
            pushArray(L, value);
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("zilua: cannot push untagged union " ++ @typeName(T));
            pushUnion(L, value);
        },
        .@"fn" => api.pushCFunction(L, bind.wrap(value)),
        .error_union => @compileError("zilua: handle the error before pushing " ++ @typeName(T)),
        else => @compileError("zilua: cannot push values of type " ++ @typeName(T)),
    }
}

fn pushInt(L: *lua_State, value: anytype) void {
    if (std.math.cast(api.Integer, value)) |i| {
        api.pushInteger(L, i);
    } else {
        api.pushNumber(L, @floatFromInt(value));
    }
}

fn pushStringLike(L: *lua_State, value: anytype) void {
    const p = @typeInfo(@TypeOf(value)).pointer;
    switch (p.size) {
        .slice => api.pushString(L, value),
        .one => api.pushString(L, value),
        .many, .c => api.pushString(L, std.mem.span(value)),
    }
}

/// A tagged union becomes a table with one entry, `{ [tag] = payload }`,
/// with `true` for a void payload: `.{ .circle = 2 }` is `{ circle = 2 }`.
fn pushUnion(L: *lua_State, value: anytype) void {
    api.createTable(L, 0, 1);
    switch (value) {
        inline else => |payload, tag| {
            if (@TypeOf(payload) == void) api.pushBoolean(L, true) else push(L, payload);
            api.setField(L, -2, @tagName(tag).ptr);
        },
    }
}

/// Pushes an array, slice or tuple as a sequence (1-based).
fn pushArray(L: *lua_State, items: anytype) void {
    const T = @TypeOf(items);
    if (@typeInfo(T) == .@"struct") {
        const fields = @typeInfo(T).@"struct".field_names;
        api.createTable(L, fields.len, 0);
        inline for (fields, 1..) |name, i| {
            push(L, @field(items, name));
            api.rawSetI(L, -2, i);
        }
        return;
    }
    api.createTable(L, @intCast(items.len), 0);
    for (items, 1..) |item, i| {
        push(L, item);
        api.rawSetI(L, -2, @intCast(i));
    }
}

/// Pushes a struct as a table of its fields, converting nested structs,
/// arrays and slices to tables as well.
fn pushAsTable(L: *lua_State, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime (s.is_tuple or !isUsertype(T))) return push(L, value);
            api.createTable(L, 0, s.field_names.len);
            inline for (s.field_names) |name| {
                pushAsTable(L, @field(value, name));
                api.setField(L, -2, name.ptr);
            }
        },
        .array => {
            api.createTable(L, value.len, 0);
            for (value, 1..) |item, i| {
                pushAsTable(L, item);
                api.rawSetI(L, -2, @intCast(i));
            }
        },
        .pointer => |p| {
            if (comptime (p.size != .slice or isString(T))) return push(L, value);
            api.createTable(L, @intCast(value.len), 0);
            for (value, 1..) |item, i| {
                pushAsTable(L, item);
                api.rawSetI(L, -2, @intCast(i));
            }
        },
        .optional => if (value) |v| pushAsTable(L, v) else api.pushNil(L),
        else => push(L, value),
    }
}

/// Pushes the elements of a tuple as separate values and returns how many.
/// Any other value is pushed as one value.
pub fn pushMulti(L: *lua_State, values: anytype) c_int {
    const T = @TypeOf(values);
    switch (@typeInfo(T)) {
        .void => return 0,
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.field_names) |name| push(L, @field(values, name));
            return s.field_names.len;
        },
        else => {},
    }
    push(L, values);
    return 1;
}

// ---------------------------------------------------------------------------
// Lua -> Zig

/// Reads the value at `idx` as a `T`. Never raises a Lua error.
///
/// `[]const u8` and `*T` results point into Lua memory and are only valid
/// while the value stays on the stack. Bound functions can use them freely
/// for the duration of the call; `toAlloc` copies them instead.
pub fn to(comptime T: type, L: *lua_State, idx: c_int) Error!T {
    if (comptime isString(T)) return toString(T, L, idx);
    if (comptime isRefType(T)) return toRef(T, L, idx);
    if (comptime isUsertype(T)) return toStruct(T, L, idx);

    switch (@typeInfo(T)) {
        .void => return,
        .bool => return api.toBoolean(L, idx),
        .int => {
            const i = api.toInteger(L, idx) orelse {
                return if (api.typeOf(L, idx) == .number) error.NotAnInteger else error.TypeMismatch;
            };
            return std.math.cast(T, i) orelse return error.IntegerOutOfRange;
        },
        .float => {
            const n = api.toNumber(L, idx) orelse return error.TypeMismatch;
            return @floatCast(n);
        },
        .optional => |o| {
            if (api.isNoneOrNil(L, idx)) return null;
            return try to(o.child, L, idx);
        },
        .@"enum" => return toEnum(T, L, idx),
        .pointer => |p| {
            if (p.size != .one) @compileError("zilua: cannot read " ++ @typeName(T) ++ " from Lua");
            if (comptime isUsertype(p.child)) {
                const header = usertype.check(L, p.child, idx) orelse return error.TypeMismatch;
                if (!p.attrs.@"const" and header.read_only) return error.ReadOnly;
                return @ptrCast(@alignCast(header.ptr));
            }
            if (p.child == anyopaque) {
                return switch (api.typeOf(L, idx)) {
                    .light_userdata, .userdata => api.toUserdata(L, idx).?,
                    else => error.TypeMismatch,
                };
            }
            @compileError("zilua: cannot read " ++ @typeName(T) ++ " from Lua");
        },
        .array => |a| return toArray(T, a.len, a.child, L, idx),
        .@"struct" => |s| {
            if (!s.is_tuple) @compileError("zilua: cannot read " ++ @typeName(T) ++ " from Lua");
            return toTuple(T, L, idx);
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("zilua: cannot read untagged union " ++ @typeName(T));
            return toUnion(T, null, L, idx) catch |err| switch (err) {
                error.OutOfMemory => unreachable, // nothing allocates without gpa
                else => |e| return e,
            };
        },
        else => @compileError("zilua: cannot read values of type " ++ @typeName(T) ++ " from Lua"),
    }
}

fn toString(comptime T: type, L: *lua_State, idx: c_int) Error!T {
    const p = @typeInfo(T).pointer;
    if (!p.attrs.@"const") @compileError("zilua: Lua strings are immutable, use []const u8 instead of " ++ @typeName(T));
    switch (api.typeOf(L, idx)) {
        .string, .number => {},
        else => return error.TypeMismatch,
    }
    const s = api.toLString(L, idx).?;
    if (p.size == .slice) {
        // Lua strings are always NUL-terminated, so [:0]const u8 works too.
        return if (p.sentinel_ptr != null) s.ptr[0..s.len :0] else s;
    }
    if (p.size == .many and p.sentinel_ptr != null) return s.ptr[0..s.len :0].ptr;
    @compileError("zilua: cannot read " ++ @typeName(T) ++ " from Lua, use []const u8");
}

fn toRef(comptime T: type, L: *lua_State, idx: c_int) Error!T {
    const expected: api.Type = if (T == ref.Table) .table else if (T == ref.Function) .function else if (T == thread.Thread) .thread else .none;
    if (expected != .none and api.typeOf(L, idx) != expected) return error.TypeMismatch;
    return T.fromStack(State.fromLua(L), idx);
}

fn toEnum(comptime E: type, L: *lua_State, idx: c_int) Error!E {
    const info = @typeInfo(E).@"enum";
    switch (api.typeOf(L, idx)) {
        .string => {
            const s = api.toLString(L, idx).?;
            inline for (info.field_names) |name| {
                if (std.mem.eql(u8, s, name)) return @field(E, name);
            }
            return error.InvalidEnum;
        },
        .number => {
            const i = api.toInteger(L, idx) orelse return error.NotAnInteger;
            const tag = std.math.cast(info.tag_type, i) orelse return error.InvalidEnum;
            if (info.mode == .nonexhaustive) return @fromBackingInt(tag);
            inline for (info.field_values) |value| {
                if (tag == value) return @fromBackingInt(tag);
            }
            return error.InvalidEnum;
        },
        else => return error.TypeMismatch,
    }
}

/// The inverse of `pushUnion`: a table with exactly one `[tag] = payload`
/// entry, or a string naming a tag with a void payload. With `gpa`, the
/// payload is read with `toAlloc`.
fn toUnion(comptime U: type, gpa: ?std.mem.Allocator, L: *lua_State, idx: c_int) AllocError!U {
    const info = @typeInfo(U).@"union";
    switch (api.typeOf(L, idx)) {
        .string => {
            const s = api.toLString(L, idx).?;
            inline for (info.field_names, info.field_types) |name, FT| {
                if (FT == void and std.mem.eql(u8, s, name)) return @unionInit(U, name, {});
            }
            return error.InvalidEnum;
        },
        .table => {
            const t = api.absIndex(L, idx);
            api.pushNil(L);
            if (!api.next(L, t)) return error.TypeMismatch;
            // Stack: key, value. Check the key's type first so that it is
            // never converted in place, which would confuse `next`.
            if (api.typeOf(L, -2) != .string) {
                api.pop(L, 2);
                return error.TypeMismatch;
            }
            const key = api.toLString(L, -2).?;
            inline for (info.field_names, info.field_types) |name, FT| {
                if (std.mem.eql(u8, key, name)) {
                    const payload: FT = if (FT == void) {} else readPayload(FT, gpa, L) catch |err| {
                        api.pop(L, 2);
                        return err;
                    };
                    api.pop(L, 1);
                    if (api.next(L, t)) {
                        // More than one entry.
                        api.pop(L, 2);
                        if (gpa) |a| free(a, payload) else releaseHandle(payload);
                        return error.TypeMismatch;
                    }
                    return @unionInit(U, name, payload);
                }
            }
            api.pop(L, 2);
            return error.InvalidEnum;
        },
        else => return error.TypeMismatch,
    }
}

fn readPayload(comptime T: type, gpa: ?std.mem.Allocator, L: *lua_State) AllocError!T {
    if (gpa) |a| return toAlloc(T, a, L, -1);
    if (comptime !canRead(T)) unreachable; // canRead(U) guarantees this for `to`
    return to(T, L, -1);
}

/// A usertype by value: copied out of its userdata, or built from a table
/// when every field has a type that can be read and owned.
///
/// The copy shares the handles (`Table`, ...) stored in the userdata's
/// fields: they stay owned by the Lua object. Use `toAlloc` for a deep copy.
fn toStruct(comptime T: type, L: *lua_State, idx: c_int) Error!T {
    if (usertype.check(L, T, idx)) |header| {
        const ptr: *const T = @ptrCast(@alignCast(header.ptr));
        return ptr.*;
    }
    if (api.typeOf(L, idx) != .table) return error.TypeMismatch;

    const info = @typeInfo(T).@"struct";
    // Fields such as []const u8 would point into the table's strings, which
    // can be collected once the table is gone, so such structs only come
    // from userdata (or `toAlloc`). So do structs with fields zilua cannot
    // read at all.
    if (comptime anyBorrowed(info.field_types) or !allCanRead(info.field_types)) return error.TypeMismatch;
    return tableToStruct(T, null, L, idx) catch |err| switch (err) {
        error.OutOfMemory => unreachable, // nothing allocates without gpa
        else => |e| return e,
    };
}

fn tableToStruct(comptime T: type, gpa: ?std.mem.Allocator, L: *lua_State, idx: c_int) AllocError!T {
    const info = @typeInfo(T).@"struct";
    const t = api.absIndex(L, idx);
    var result: T = undefined;
    var filled: usize = 0;
    errdefer releaseFields(T, gpa, &result, filled);
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FT, attrs, i| {
        if (attrs.@"comptime") continue;
        // Raw access: an __index metamethod could raise, and conversions never do.
        api.pushString(L, name);
        const ty = api.rawGet(L, t);
        defer api.pop(L, 1);
        if (ty == .nil) {
            if (attrs.default_value_ptr) |dp| {
                const default: *const FT = @ptrCast(@alignCast(dp));
                @field(result, name) = if (gpa) |a| try dupe(a, default.*) else default.*;
            } else if (@typeInfo(FT) == .optional) {
                @field(result, name) = null;
            } else {
                return error.MissingField;
            }
        } else {
            @field(result, name) = try readPayload(FT, gpa, L);
        }
        filled = i + 1;
    }
    return result;
}

fn toArray(comptime T: type, comptime len: usize, comptime Child: type, L: *lua_State, idx: c_int) Error!T {
    if (comptime isBorrowed(Child)) @compileError("zilua: cannot read " ++ @typeName(T) ++ " from a table, its elements would point into Lua memory");
    if (api.typeOf(L, idx) != .table) return error.TypeMismatch;
    if (api.rawLen(L, idx) != len) return error.TypeMismatch;
    const t = api.absIndex(L, idx);
    var result: T = undefined;
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |item| releaseHandle(item);
    }
    for (&result, 1..) |*item, i| {
        _ = api.rawGetI(L, t, @intCast(i));
        defer api.pop(L, 1);
        item.* = try to(Child, L, -1);
        filled = i;
    }
    return result;
}

fn toTuple(comptime T: type, L: *lua_State, idx: c_int) Error!T {
    const info = @typeInfo(T).@"struct";
    if (comptime anyBorrowed(info.field_types)) @compileError("zilua: cannot read " ++ @typeName(T) ++ " from a table, its elements would point into Lua memory");
    if (api.typeOf(L, idx) != .table) return error.TypeMismatch;
    const t = api.absIndex(L, idx);
    var result: T = undefined;
    var filled: usize = 0;
    errdefer releaseFields(T, null, &result, filled);
    inline for (info.field_names, info.field_types, 1..) |name, FT, i| {
        _ = api.rawGetI(L, t, i);
        defer api.pop(L, 1);
        @field(result, name) = try to(FT, L, -1);
        filled = i;
    }
    return result;
}

/// Number of Lua values that make up a result of type `R`.
pub fn resultCount(comptime R: type) c_int {
    return switch (@typeInfo(R)) {
        .void => 0,
        .@"struct" => |s| if (s.is_tuple) s.field_names.len else 1,
        else => 1,
    };
}

/// Reads `resultCount(R)` values starting at `first` as an `R`.
pub fn toMulti(comptime R: type, L: *lua_State, first: c_int) Error!R {
    switch (@typeInfo(R)) {
        .void => return,
        .@"struct" => |s| if (s.is_tuple) {
            var result: R = undefined;
            var filled: usize = 0;
            errdefer releaseFields(R, null, &result, filled);
            inline for (s.field_names, s.field_types, 0..) |name, FT, i| {
                @field(result, name) = try to(FT, L, first + @as(c_int, i));
                filled = i + 1;
            }
            return result;
        },
        else => {},
    }
    return to(R, L, first);
}

/// Like `toMulti`, with `toAlloc`.
pub fn toMultiAlloc(comptime R: type, gpa: std.mem.Allocator, L: *lua_State, first: c_int) AllocError!R {
    switch (@typeInfo(R)) {
        .void => return,
        .@"struct" => |s| if (s.is_tuple) {
            var result: R = undefined;
            var filled: usize = 0;
            errdefer releaseFields(R, gpa, &result, filled);
            inline for (s.field_names, s.field_types, 0..) |name, FT, i| {
                @field(result, name) = try toAlloc(FT, gpa, L, first + @as(c_int, i));
                filled = i + 1;
            }
            return result;
        },
        else => {},
    }
    return toAlloc(R, gpa, L, first);
}

// ---------------------------------------------------------------------------
// Conversions that allocate

/// Whether `toAlloc` accepts `T`: what `to` accepts, plus strings and slices
/// anywhere (copied), and structs with such fields read from tables.
pub fn canReadAlloc(comptime T: type) bool {
    if (isString(T)) return @typeInfo(T).pointer.size == .slice;
    if (isRefType(T)) return true;
    if (isUsertype(T)) return usertype.isValid(T);
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => true,
        .optional => |o| canReadAlloc(o.child),
        .pointer => |p| p.size == .slice and canReadAlloc(p.child),
        .array => |a| canReadAlloc(a.child),
        .@"struct" => |s| s.is_tuple and allCanReadAlloc(s.field_types),
        .@"union" => |u| u.tag_type != null and allCanReadAlloc(u.field_types),
        else => false,
    };
}

fn allCanReadAlloc(comptime types: []const type) bool {
    for (types) |T| {
        if (!canReadAlloc(T)) return false;
    }
    return true;
}

/// Reads the value at `idx` as a `T` that owns all its memory: strings and
/// slices are copied with `gpa`, handles are new references, and usertypes
/// are deep copies. Release the result with `free`.
pub fn toAlloc(comptime T: type, gpa: std.mem.Allocator, L: *lua_State, idx: c_int) AllocError!T {
    if (comptime !canReadAlloc(T)) @compileError("zilua: cannot read " ++ @typeName(T) ++ " from Lua");
    if (comptime isString(T)) {
        const s = try to([]const u8, L, idx);
        const p = @typeInfo(T).pointer;
        if (p.sentinel_ptr != null) return gpa.dupeSentinel(u8, s, 0);
        return gpa.dupe(u8, s);
    }
    if (comptime isRefType(T)) return to(T, L, idx);
    if (comptime isUsertype(T)) {
        if (usertype.check(L, T, idx)) |header| {
            const ptr: *const T = @ptrCast(@alignCast(header.ptr));
            return dupe(gpa, ptr.*);
        }
        if (api.typeOf(L, idx) != .table) return error.TypeMismatch;
        if (comptime !allCanReadAlloc(@typeInfo(T).@"struct".field_types)) return error.TypeMismatch;
        return tableToStruct(T, gpa, L, idx);
    }
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (api.isNoneOrNil(L, idx)) return null;
            return try toAlloc(o.child, gpa, L, idx);
        },
        .pointer => |p| {
            if (api.typeOf(L, idx) != .table) return error.TypeMismatch;
            const t = api.absIndex(L, idx);
            // #t can be far larger than the number of elements (keys 1, 2,
            // 4, ..., 2^30 make a border at 2^30), so make sure the sequence
            // has no holes before allocating for it.
            const len = api.rawLen(L, t);
            for (0..len) |k| {
                const ty = api.rawGetI(L, t, @intCast(k + 1));
                api.pop(L, 1);
                if (ty == .nil) return error.TypeMismatch;
            }
            const items = try gpa.alloc(p.child, len);
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |item| free(gpa, item);
                gpa.free(items);
            }
            for (items, 1..) |*item, i| {
                _ = api.rawGetI(L, t, @intCast(i));
                defer api.pop(L, 1);
                item.* = try toAlloc(p.child, gpa, L, -1);
                filled = i;
            }
            return items;
        },
        .array => |a| {
            if (api.typeOf(L, idx) != .table) return error.TypeMismatch;
            if (api.rawLen(L, idx) != a.len) return error.TypeMismatch;
            const t = api.absIndex(L, idx);
            var result: T = undefined;
            var filled: usize = 0;
            errdefer {
                for (result[0..filled]) |item| free(gpa, item);
            }
            for (&result, 1..) |*item, i| {
                _ = api.rawGetI(L, t, @intCast(i));
                defer api.pop(L, 1);
                item.* = try toAlloc(a.child, gpa, L, -1);
                filled = i;
            }
            return result;
        },
        .@"struct" => |s| {
            if (api.typeOf(L, idx) != .table) return error.TypeMismatch;
            const t = api.absIndex(L, idx);
            var result: T = undefined;
            var filled: usize = 0;
            errdefer releaseFields(T, gpa, &result, filled);
            inline for (s.field_names, s.field_types, 1..) |name, FT, i| {
                _ = api.rawGetI(L, t, i);
                defer api.pop(L, 1);
                @field(result, name) = try toAlloc(FT, gpa, L, -1);
                filled = i;
            }
            return result;
        },
        .@"union" => return toUnion(T, gpa, L, idx),
        else => return to(T, L, idx),
    }
}

/// A deep copy of `value`: slices copied with `gpa`, handles cloned.
/// Pointers to single values are copied as they are.
pub fn dupe(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime isRefType(T)) return cloneHandle(value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |v| try dupe(gpa, v) else null,
        .pointer => |p| {
            if (p.size != .slice) return value;
            if (p.sentinel_ptr != null) {
                if (p.child != u8) @compileError("zilua: cannot copy " ++ @typeName(T));
                return gpa.dupeSentinel(u8, value, 0);
            }
            const items = try gpa.alloc(p.child, value.len);
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |item| free(gpa, item);
                gpa.free(items);
            }
            for (items, value) |*dst, src| {
                dst.* = try dupe(gpa, src);
                filled += 1;
            }
            return items;
        },
        .array => {
            var result: T = undefined;
            var filled: usize = 0;
            errdefer {
                for (result[0..filled]) |item| free(gpa, item);
            }
            for (&result, value) |*dst, src| {
                dst.* = try dupe(gpa, src);
                filled += 1;
            }
            return result;
        },
        .@"struct" => |s| {
            var result: T = value;
            var filled: usize = 0;
            errdefer releaseFields(T, gpa, &result, filled);
            inline for (s.field_names, s.field_attrs, 1..) |name, attrs, i| {
                if (!attrs.@"comptime") @field(result, name) = try dupe(gpa, @field(value, name));
                filled = i;
            }
            return result;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try dupe(gpa, payload)),
        },
        else => return value,
    }
}

/// Frees what `toAlloc` or `dupe` allocated in `value` and releases its
/// handles. Pointers to single values are left alone.
pub fn free(gpa: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);
    if (comptime isRefType(T)) return value.deinit();
    switch (@typeInfo(T)) {
        .optional => if (value) |v| free(gpa, v),
        .pointer => |p| if (p.size == .slice) {
            if (p.child != u8) {
                for (value) |item| free(gpa, item);
            }
            gpa.free(value);
        },
        .array => for (value) |item| free(gpa, item),
        .@"struct" => |s| inline for (s.field_names, s.field_attrs) |name, attrs| {
            if (!attrs.@"comptime") free(gpa, @field(value, name));
        },
        .@"union" => switch (value) {
            inline else => |payload| free(gpa, payload),
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Handles

/// Releases a zilua handle (or optional handle). Other values need no
/// cleanup without an allocator.
pub fn releaseHandle(value: anytype) void {
    const T = @TypeOf(value);
    if (comptime isRefType(T)) {
        value.deinit();
    } else if (@typeInfo(T) == .optional) {
        if (value) |v| releaseHandle(v);
    }
}

/// The underlying reference of a handle or optional handle, if any.
pub fn handleRef(value: anytype) ?ref.Ref {
    const T = @TypeOf(value);
    if (T == ref.Ref) return value;
    if (comptime isRefType(T)) return value.ref;
    if (@typeInfo(T) == .optional) return if (value) |v| handleRef(v) else null;
    return null;
}

fn cloneHandle(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (T == ref.Ref) return value.clone();
    var copy = value;
    copy.ref = value.ref.clone();
    return copy;
}

/// Releases what the first `filled` fields of a partly built struct or
/// tuple hold: with `gpa` everything `free` would, otherwise only handles.
/// Nested structs are left alone without `gpa`: by-value usertypes are
/// copies whose handles belong to the original.
fn releaseFields(comptime T: type, gpa: ?std.mem.Allocator, result: *const T, filled: usize) void {
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_attrs, 0..) |name, attrs, i| {
        if (!attrs.@"comptime" and i < filled) {
            if (gpa) |a| free(a, @field(result.*, name)) else releaseHandle(@field(result.*, name));
        }
    }
}
