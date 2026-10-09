//! Behaviour specific to one runtime. Each test skips itself on the others.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;

const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

test "the selected runtime is the one running" {
    const lua = try open();
    defer lua.deinit();

    const expected: []const u8 = switch (zilua.lang) {
        .lua51, .luajit => "Lua 5.1",
        .lua52 => "Lua 5.2",
        .lua53 => "Lua 5.3",
        .lua54 => "Lua 5.4",
        .lua55 => "Lua 5.5",
        .luau => "Luau",
    };
    try run(lua, "version = _VERSION");
    const version = try lua.getGlobal(zilua.Ref, "version");
    defer version.deinit();
    version.push(lua.L);
    defer lua.pop(1);
    try testing.expectEqualStrings(expected, try lua.to([]const u8, -1));
}

test "LuaJIT: the JIT compiler and FFI are available" {
    if (zilua.lang != .luajit) return error.SkipZigTest;
    const lua = try open();
    defer lua.deinit();

    try run(lua,
        \\assert(type(jit) == "table" and jit.status())
        \\local ffi = require("ffi")
        \\assert(ffi.sizeof("int32_t") == 4)
    );
}

test "Luau: typeof reports the usertype name" {
    if (zilua.lang != .luau) return error.SkipZigTest;
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("p", Point{});
    try run(lua, "assert(typeof(p) == 'Point' and type(p) == 'userdata')");
}
