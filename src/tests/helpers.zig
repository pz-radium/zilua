//! Shared helpers for the test files in this folder.
//!
//! The tests run against whichever runtime `-Dlang` selects, so their Lua
//! snippets stick to syntax shared by Lua 5.1 through 5.5.

const std = @import("std");
const zilua = @import("../zilua.zig");

pub fn open() !zilua.State {
    return zilua.State.init(std.testing.allocator, .{});
}

/// `lua.doString` that prints Lua's error message when the chunk fails.
pub fn run(lua: zilua.State, source: []const u8) !void {
    lua.doString(source) catch |err| {
        std.debug.print("lua error: {s}\n", .{lua.errorMessage()});
        return err;
    };
}

/// Registry entries holding tables. Released references leave their slot
/// behind (holding a free-list link), so count what references point to:
/// with the test's references all to tables, this grows only on leaks.
pub fn registryTables(lua: zilua.State) usize {
    const api = zilua.api;
    const L = lua.L;
    api.pushValue(L, api.registry_index);
    defer api.pop(L, 1);
    var n: usize = 0;
    api.pushNil(L);
    while (api.next(L, -2)) {
        if (api.typeOf(L, -1) == .table) n += 1;
        api.pop(L, 1);
    }
    return n;
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (contains(haystack, needle)) return;
    std.debug.print("expected \"{s}\" to contain \"{s}\"\n", .{ haystack, needle });
    return error.TestExpectedContains;
}
