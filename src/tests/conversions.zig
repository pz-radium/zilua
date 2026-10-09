//! Value conversions: integer checks, tables to structs and arrays, enums.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

test "integer conversion is checked" {
    const lua = try open();
    defer lua.deinit();

    try run(lua, "big = 300; frac = 1.5; neg = -1");
    try testing.expectError(error.IntegerOutOfRange, lua.getGlobal(u8, "big"));
    try testing.expectError(error.NotAnInteger, lua.getGlobal(i32, "frac"));
    try testing.expectError(error.IntegerOutOfRange, lua.getGlobal(u32, "neg"));
    try testing.expectError(error.TypeMismatch, lua.getGlobal(i32, "missing"));
}

test "tables convert to structs, tuples and arrays" {
    const Config = struct {
        width: u32 = 800,
        height: u32 = 600,
        fullscreen: bool = false,
        scale: ?f32 = null,
    };
    const lua = try open();
    defer lua.deinit();

    try run(lua, "config = { width = 1024, fullscreen = true }; rgb = { 1, 2, 3 }");
    const config = try lua.getGlobal(Config, "config");
    try testing.expectEqual(1024, config.width);
    try testing.expectEqual(600, config.height);
    try testing.expectEqual(true, config.fullscreen);
    try testing.expectEqual(null, config.scale);

    const rgb = try lua.getGlobal([3]u8, "rgb");
    try testing.expectEqual([3]u8{ 1, 2, 3 }, rgb);
    try testing.expectError(error.TypeMismatch, lua.getGlobal([4]u8, "rgb"));

    lua.setGlobal("from_zig", zilua.asTable(Config{ .width = 1 }));
    try run(lua, "assert(type(from_zig) == 'table' and from_zig.width == 1 and from_zig.height == 600)");
}

test "enums map to their names" {
    const Mode = enum { fast, safe };
    const S = struct {
        fn flip(m: Mode) Mode {
            return if (m == .fast) .safe else .fast;
        }
    };
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("flip", S.flip);
    try run(lua, "m = flip('fast')");
    try testing.expectEqual(Mode.safe, try lua.getGlobal(Mode, "m"));
    try testing.expectError(error.Runtime, lua.doString("flip('slow')"));
    try expectContains(lua.errorMessage(), "invalid enum value");
}
