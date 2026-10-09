//! Lua C modules: zilua inside a state it did not create.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const api = zilua.api;

const geometry = struct {
    pub fn area(w: f64, h: f64) f64 {
        return w * h;
    }

    /// Takes the state, so zilua has to attach to the foreign one.
    pub fn version(lua: zilua.State) []const u8 {
        _ = lua.allocator();
        return "1.0";
    }
};

comptime {
    zilua.exportModule("zilua_test_geometry", geometry);
}

extern fn luaopen_zilua_test_geometry(L: ?*api.lua_State) callconv(.c) c_int;

fn expectRuns(L: *api.lua_State, source: []const u8) !void {
    const status = blk: {
        const load = api.loadBuffer(L, source, "=test", .text);
        if (load != .ok) break :blk load;
        break :blk api.pcall(L, 0, 0, 0);
    };
    if (status != .ok) {
        std.debug.print("lua error: {s}\n", .{api.toLString(L, -1) orelse "?"});
        return error.TestUnexpectedResult;
    }
}

test "a module works in a state zilua did not create" {
    // As a Lua host would: Lua's own allocator, no zilua.State.
    const L = api.newDefaultState() orelse return error.OutOfMemory;
    defer api.close(L);
    api.openLibs(L);

    // The exported luaopen_ function, called like `require` would.
    api.pushCFunction(L, luaopen_zilua_test_geometry);
    api.call(L, 0, 1);
    api.setGlobal(L, "geometry");
    try expectRuns(L, "assert(geometry.area(2, 3) == 6 and geometry.version() == '1.0')");

    // The same open function, without the symbol.
    api.pushCFunction(L, zilua.module.openFunction(geometry));
    api.call(L, 0, 1);
    api.setGlobal(L, "geometry2");
    try expectRuns(L, "assert(geometry2.area(4, 5) == 20)");
}
