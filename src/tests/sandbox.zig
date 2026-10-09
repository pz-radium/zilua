//! Sandbox environments, binary chunks, memory and instruction limits.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

test "sandboxed code cannot reach the host" {
    const lua = try open();
    defer lua.deinit();
    const sandbox = try lua.newSandbox(.{});
    defer sandbox.deinit();

    try sandbox.doString(
        \\assert(io == nil and require == nil and debug == nil and package == nil)
        \\assert(load == nil and loadstring == nil and dofile == nil)
        \\assert(os.execute == nil and os.exit == nil and type(os.time()) == "number")
        \\assert(getmetatable("") == nil)
        \\assert(string.rep("ab", 2) == "abab" and math.floor(2.5) == 2)
        \\x = 42
    );
    // Globals stay inside the environment.
    try testing.expectEqual(null, try lua.getGlobal(?i64, "x"));
    try testing.expectEqual(42, try sandbox.get(i64, "x"));

    // Libraries are copies: changing them leaves the host's alone. On Luau
    // they are read-only, as in Luau's own sandboxing.
    try sandbox.doString("changed = pcall(function() string.upper = nil end)");
    try testing.expectEqual(zilua.lang != .luau, try sandbox.get(bool, "changed"));
    try run(lua, "assert(string.upper('a') == 'A')");
}

test "the host adds functions to a sandbox" {
    const S = struct {
        fn double(x: i64) i64 {
            return x * 2;
        }
    };
    const lua = try open();
    defer lua.deinit();
    const sandbox = try lua.newSandbox(.{ .os_time = false });
    defer sandbox.deinit();
    try sandbox.set("double", S.double);

    try sandbox.doString("y = double(21); assert(os == nil)");
    try testing.expectEqual(42, try sandbox.get(i64, "y"));
    try sandbox.doString("function triple(v) return v * 3 end");
    try testing.expectEqual(9, try sandbox.call(i64, "triple", .{3}));
}

test "limits of a sandbox apply to its calls only" {
    const lua = try open();
    defer lua.deinit();
    const sandbox = try lua.newSandbox(.{ .limits = .{ .memory = 256 * 1024, .instructions = 100_000 } });
    defer sandbox.deinit();

    try testing.expectError(error.Runtime, sandbox.doString("while true do end"));
    try expectContains(lua.errorMessage(), "instruction limit exceeded");
    try testing.expectError(error.OutOfMemory, sandbox.doString("local t = {} for i = 1, 1e7 do t[i] = i end"));
    try sandbox.doString("function spin() while true do end end");
    try testing.expectError(error.Runtime, sandbox.call(void, "spin", .{}));

    // Outside the sandbox the state has no limits.
    try run(lua, "local s = 0 for i = 1, 1000000 do s = s + i end");
    try run(lua, "local t = {} for i = 1, 100000 do t[i] = i end");
    try sandbox.doString("ok = true");
}

test "Luau: freezeGlobals makes the global environment read-only" {
    const lua = try open();
    defer lua.deinit();
    if (zilua.lang != .luau) {
        try testing.expectError(error.Unsupported, lua.freezeGlobals());
        return;
    }
    lua.setGlobal("answer", @as(i64, 42));
    try lua.freezeGlobals();
    try run(lua, "assert(answer == 42 and not pcall(function() string.upper = nil end))");
    try testing.expectError(error.Runtime, lua.doString("answer = 1"));

    // Sandboxes still work, and may opt into Luau's fast paths.
    const sandbox = try lua.newSandbox(.{ .luau_fast_builtins = true });
    defer sandbox.deinit();
    try sandbox.doString("x = math.max(1, 2)");
    try testing.expectEqual(2, try sandbox.get(i64, "x"));
}

test "binary chunks are rejected" {
    // Luau has no string.dump to produce one.
    if (zilua.lang == .luau) return error.SkipZigTest;
    const lua = try open();
    defer lua.deinit();

    try run(lua, "bytecode = string.dump(function() return 1 end)");
    const bytecode = try lua.getGlobal(zilua.Ref, "bytecode");
    defer bytecode.deinit();
    bytecode.push(lua.L);
    defer lua.pop(1);
    try testing.expectError(error.Syntax, lua.doString(try lua.to([]const u8, -1)));
    // "(mode is 't')" on PUC Lua, "wrong mode" on LuaJIT.
    try expectContains(lua.errorMessage(), "mode");
}

test "memory limit" {
    const lua = try open();
    defer lua.deinit();

    lua.setMemoryLimit(lua.memoryUsed() + 256 * 1024);
    try testing.expectError(error.OutOfMemory, lua.doString("local t = {} for i = 1, 1e7 do t[i] = i end"));
    // Scripts see an ordinary error they can catch.
    try run(lua,
        \\local ok = pcall(function() local t = {} for i = 1, 1e7 do t[i] = i end end)
        \\caught = not ok
    );
    try testing.expect(try lua.getGlobal(bool, "caught"));

    lua.setMemoryLimit(null);
    try run(lua, "local t = {} for i = 1, 100000 do t[i] = i end");
}

test "instruction limit" {
    const lua = try open();
    defer lua.deinit();

    lua.setInstructionLimit(100_000);
    try testing.expectError(error.Runtime, lua.doString("while true do end"));
    try expectContains(lua.errorMessage(), "instruction limit exceeded");
    // pcall does not get around it.
    try testing.expectError(error.Runtime, lua.doString("while true do pcall(function() while true do end end) end"));
    // The budget is per call from Zig: short scripts keep working.
    try run(lua, "local s = 0 for i = 1, 1000 do s = s + i end total = s");
    try testing.expectEqual(500500, try lua.getGlobal(i64, "total"));

    lua.setInstructionLimit(null);
    try run(lua, "local s = 0 for i = 1, 1000000 do s = s + i end");
}
