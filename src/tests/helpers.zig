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

/// Registry entries holding a value of this type. A released reference
/// leaves its slot behind (holding a free-list link), so a test counts what
/// its references point to: that grows only when one leaks.
pub fn registryValues(lua: zilua.State, ty: zilua.api.Type) usize {
    const api = zilua.api;
    const L = lua.L;
    api.pushValue(L, api.registry_index);
    defer api.pop(L, 1);
    var n: usize = 0;
    api.pushNil(L);
    while (api.next(L, -2)) {
        if (api.typeOf(L, -1) == ty) n += 1;
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

/// Runs a scheduler until its tasks are done, waiting for jobs on `io`.
/// Gives up after a while, so a test fails instead of hanging.
pub fn drain(scheduler: *zilua.Scheduler, io: std.Io) !void {
    for (0..5000) |_| {
        if (scheduler.count() == 0) return;
        scheduler.update(0);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestSchedulerStuck;
}
