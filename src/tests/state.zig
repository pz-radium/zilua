//! Running code, globals, errors, calling Lua from Zig, handles, memory.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

test "doString and getGlobal" {
    const lua = try open();
    defer lua.deinit();

    try run(lua, "x = 40 + 2; name = 'zilua'; flag = true");
    try testing.expectEqual(42, try lua.getGlobal(i64, "x"));
    try testing.expectEqual(42.0, try lua.getGlobal(f64, "x"));
    try testing.expectEqual(true, try lua.getGlobal(bool, "flag"));
    try testing.expectEqual(null, try lua.getGlobal(?i32, "missing"));
}

test "setGlobal round trip" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("n", @as(u16, 7));
    lua.setGlobal("s", "hello");
    lua.setGlobal("maybe", @as(?f32, null));
    try run(lua, "ok = (n == 7 and s == 'hello' and maybe == nil)");
    try testing.expect(try lua.getGlobal(bool, "ok"));
}

test "syntax and runtime errors carry messages" {
    const lua = try open();
    defer lua.deinit();

    try testing.expectError(error.Syntax, lua.doString("x = = 1"));
    try testing.expectError(error.Runtime, lua.doString("error('boom')"));
    try expectContains(lua.errorMessage(), "boom");
    // The state stays usable and the stack balanced after errors.
    try testing.expectEqual(0, lua.getTop());
    try run(lua, "y = 1");
}

test "call Lua functions" {
    const lua = try open();
    defer lua.deinit();

    try run(lua,
        \\function mul(a, b) return a * b end
        \\function pair() return 1, "two" end
        \\function nothing() end
        \\function fails() error("nope") end
    );
    try testing.expectEqual(12, try lua.call(i64, "mul", .{ 3, 4 }));
    const one, const two = try lua.call(struct { i32, zilua.Ref }, "pair", .{});
    defer two.deinit();
    try testing.expectEqual(1, one);
    try lua.call(void, "nothing", .{});
    try testing.expectError(error.Runtime, lua.call(void, "fails", .{}));
    try expectContains(lua.errorMessage(), "nope");
    try testing.expectEqual(0, lua.getTop());
}

test "Table and Function handles" {
    const lua = try open();
    defer lua.deinit();

    try run(lua, "t = { 10, 20, 30, key = 'value' }; function double(x) return x * 2 end");

    const t = try lua.getGlobal(zilua.Table, "t");
    defer t.deinit();
    try testing.expectEqual(3, t.len());
    try testing.expectEqual(20, try t.get(i64, 2));
    try t.set(4, 40);
    try t.set("added", true);
    try testing.expectError(error.InvalidKey, t.set(@as(?i32, null), 1));
    try run(lua, "assert(t[4] == 40 and t.added == true)");

    const double = try lua.getGlobal(zilua.Function, "double");
    defer double.deinit();
    try testing.expectEqual(42, try double.call(i64, .{21}));

    const g = lua.globals();
    defer g.deinit();
    const same = try g.get(zilua.Table, "t");
    defer same.deinit();
    try testing.expectEqual(40, try same.get(i64, 4));

    // A Table handle can be passed back to Lua as an argument.
    try run(lua, "function count(tbl) return #tbl end");
    try testing.expectEqual(4, try lua.call(i64, "count", .{t}));
}

test "memory goes through the Zig allocator" {
    // testing.allocator fails the test on leaks, so a clean deinit is the check.
    const lua = try open();
    defer lua.deinit();
    try run(lua, "local t = {} for i = 1, 1000 do t[i] = tostring(i) end");
    try testing.expect(lua.memoryUsed() > 0);
}
