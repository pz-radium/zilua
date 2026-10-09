//! Hot reload: watched files and module hot-swapping.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;

test "Reloader runs files again when they change" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.lua",
        .data = "value = 1\nfunction on_reload(path) reloaded = path end\n",
    });

    const lua = try open();
    defer lua.deinit();
    var reloader: zilua.Reloader = .init(lua, testing.allocator, tmp.dir);
    defer reloader.deinit();

    try reloader.watch(io, "config.lua");
    try testing.expectEqual(1, try lua.getGlobal(i64, "value"));
    try testing.expectEqual(0, try reloader.poll(io));

    // Sizes differ, so the change is seen even within one mtime tick.
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.lua",
        .data = "value = 22 -- edited\nfunction on_reload(path) reloaded = path end\n",
    });
    try testing.expectEqual(1, try reloader.poll(io));
    try testing.expectEqual(22, try lua.getGlobal(i64, "value"));
    try run(lua, "assert(reloaded == 'config.lua')");

    // A version that does not compile leaves the previous one in place.
    try tmp.dir.writeFile(io, .{ .sub_path = "config.lua", .data = "value = = 3" });
    try testing.expectError(error.Syntax, reloader.poll(io));
    try testing.expectEqual(22, try lua.getGlobal(i64, "value"));
    // ...and is not retried until it changes again.
    try testing.expectEqual(0, try reloader.poll(io));
}

test "reloadModule swaps new code into the loaded table" {
    const lua = try open();
    defer lua.deinit();

    if (zilua.lang == .luau) {
        // No require on Luau.
        try testing.expectError(error.Runtime, lua.reloadModule("greeter"));
        return;
    }
    try run(lua,
        \\version = 1
        \\package.preload.greeter = function()
        \\  local v = version
        \\  return { hello = function() return "v" .. v end }
        \\end
        \\greeter = require("greeter")
        \\assert(greeter.hello() == "v1")
        \\version = 2
    );
    try lua.reloadModule("greeter");
    try run(lua, "assert(greeter.hello() == 'v2' and require('greeter') == greeter)");
}
