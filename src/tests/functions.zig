//! Binding Zig functions: argument conversion, multiple results, errors.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

const funcs = struct {
    fn add(a: i64, b: i64) i64 {
        return a + b;
    }

    fn divmod(a: i64, b: i64) struct { i64, i64 } {
        return .{ @divFloor(a, b), @mod(a, b) };
    }

    fn greet(name: []const u8, excited: ?bool) []const u8 {
        _ = name;
        return if (excited orelse false) "HELLO" else "hello";
    }

    fn mustBePositive(x: i64) !i64 {
        if (x <= 0) return error.NotPositive;
        return x;
    }

    fn checked(lua: zilua.State, x: i64) !i64 {
        if (x < 0) return lua.fail("x must not be negative");
        return x * 2;
    }

    fn small(x: u8) u8 {
        return x;
    }
};

test "bound functions" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("add", funcs.add);
    lua.setGlobal("divmod", funcs.divmod);
    lua.setGlobal("greet", funcs.greet);
    try run(lua,
        \\sum = add(2, 3)
        \\q, r = divmod(7, 2)
        \\a = greet("x")
        \\b = greet("x", true)
    );
    try testing.expectEqual(5, try lua.getGlobal(i64, "sum"));
    try testing.expectEqual(3, try lua.getGlobal(i64, "q"));
    try testing.expectEqual(1, try lua.getGlobal(i64, "r"));
    try run(lua, "assert(a == 'hello' and b == 'HELLO')");
}

test "argument errors name the argument" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("add", funcs.add);
    lua.setGlobal("small", funcs.small);
    try testing.expectError(error.Runtime, lua.doString("add(1, 'x')"));
    // "bad argument #2" in PUC Lua and LuaJIT, "invalid argument #2" in Luau.
    try expectContains(lua.errorMessage(), "argument #2");
    try expectContains(lua.errorMessage(), "expected, got string");
    try testing.expectError(error.Runtime, lua.doString("small(300)"));
    try expectContains(lua.errorMessage(), "out of range");
}

test "Zig errors become Lua errors" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("positive", funcs.mustBePositive);
    lua.setGlobal("checked", funcs.checked);

    try testing.expectError(error.Runtime, lua.doString("positive(-1)"));
    try expectContains(lua.errorMessage(), "NotPositive");

    try run(lua, "ok, msg = pcall(checked, -5)");
    try testing.expectEqual(false, try lua.getGlobal(bool, "ok"));
    try run(lua, "assert(string.find(msg, 'x must not be negative', 1, true))");

    try run(lua, "v = checked(21)");
    try testing.expectEqual(42, try lua.getGlobal(i64, "v"));
}
