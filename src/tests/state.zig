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

test "doFile skips a shebang line and refuses precompiled chunks" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "script.lua", .data = "#!/usr/bin/env lua\nvalue = 3\n" });
    var script_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&script_buf, ".zig-cache/tmp/{s}/script.lua", .{&tmp.sub_path}, 0);

    const lua = try open();
    defer lua.deinit();
    try lua.doFile(script);
    try testing.expectEqual(3, try lua.getGlobal(i64, "value"));

    if (zilua.lang == .luau) return; // no string.dump to make a chunk with
    var chunk_buf: [128]u8 = undefined;
    const chunk = try std.fmt.bufPrintSentinel(&chunk_buf, ".zig-cache/tmp/{s}/chunk.out", .{&tmp.sub_path}, 0);
    lua.setGlobal("path", chunk);
    try run(lua,
        \\local f = assert(io.open(path, "wb"))
        \\f:write(string.dump(function() return 1 end))
        \\f:close()
    );
    if (lua.doFile(chunk)) |_| return error.TestUnexpectedResult else |_| {}
    try expectContains(lua.errorMessage(), "mode");
}

test "doFile fails cleanly under a memory limit" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A 1 MiB string constant: loading it needs more than the limit allows.
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const source = try std.mem.concat(testing.allocator, u8, &.{ "s = \"", big, "\"" });
    defer testing.allocator.free(source);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.lua", .data = source });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/big.lua", .{&tmp.sub_path}, 0);

    const lua = try open();
    defer lua.deinit();
    lua.setMemoryLimit(lua.memoryUsed() + (256 << 10));
    if (lua.doFile(path)) |_| return error.TestUnexpectedResult else |_| {}
    lua.setMemoryLimit(null);
    try run(lua, "x = 1");
}

test "the State API ignores metamethods of the globals table" {
    const lua = try open();
    defer lua.deinit();
    // A "strict" module: reading or creating undeclared globals raises.
    try run(lua,
        \\setmetatable(_G, {
        \\  __index = function(_, k) error("undefined global " .. k) end,
        \\  __newindex = function(_, k) error("undeclared global " .. k) end,
        \\})
    );
    try testing.expectEqual(null, try lua.getGlobal(?i64, "missing"));
    try testing.expectError(error.Runtime, lua.call(void, "missing", .{}));
    lua.setGlobal("created", @as(i64, 7));
    try testing.expectEqual(7, try lua.getGlobal(i64, "created"));
}

test "collectGarbage survives a failing finalizer" {
    const lua = try open();
    defer lua.deinit();
    // Lua 5.2 and 5.3 re-throw errors in __gc from a full collection.
    try run(lua, "setmetatable({}, { __gc = function() error('in __gc') end })");
    lua.collectGarbage();
    try run(lua, "x = 1");
}

test "runtime errors carry a traceback on every runtime" {
    const lua = try open();
    defer lua.deinit();

    try testing.expectError(error.Runtime, lua.doString(
        \\local function inner() error('deep') end
        \\local function outer() inner() end
        \\outer()
    ));
    const message = lua.errorMessage();
    try expectContains(message, "deep");
    try expectContains(message, "inner");
    // Luau has its own format, without a header.
    if (zilua.lang != .luau) try expectContains(message, "stack traceback:");

    // Long stacks are cut in the middle.
    try testing.expectError(error.Runtime, lua.doString(
        \\local function down(n) if n == 0 then error('bottom') end down(n - 1) return n end
        \\down(40)
    ));
    if (zilua.lang != .luau) try expectContains(lua.errorMessage(), "\n\t...");
    try testing.expectEqual(0, lua.getTop());
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
