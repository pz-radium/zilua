//! Conversions that allocate, and who releases handles.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;

const gpa = testing.allocator;

test "getGlobalAlloc copies strings and slices" {
    const lua = try open();
    defer lua.deinit();
    try run(lua, "name = 'zilua'; list = { 'a', 'bb', 'ccc' }; nums = { 1, 2, 3 }");

    const name = try lua.getGlobalAlloc(gpa, []const u8, "name");
    defer zilua.free(gpa, name);
    try testing.expectEqualStrings("zilua", name);

    const list = try lua.getGlobalAlloc(gpa, []const []const u8, "list");
    defer zilua.free(gpa, list);
    try testing.expectEqual(3, list.len);
    try testing.expectEqualStrings("ccc", list[2]);

    const nums = try lua.getGlobalAlloc(gpa, []i64, "nums");
    defer zilua.free(gpa, nums);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, nums);
}

test "slices come from sequences without holes" {
    const lua = try open();
    defer lua.deinit();

    // Keys 1, 2, 4, ..., 2^30: #t can be as large as 2^30 with 31 elements.
    // The read must fail at the first hole, before allocating for #t.
    try run(lua,
        \\sparse = {}
        \\for k = 0, 30 do sparse[2 ^ k] = k end
        \\list = { 1, 2, 3 }
    );
    try testing.expectError(error.TypeMismatch, lua.getGlobalAlloc(gpa, []i64, "sparse"));
    const list = try lua.getGlobalAlloc(gpa, []i64, "list");
    defer zilua.free(gpa, list);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, list);
}

test "structs with string fields come from tables" {
    const Item = struct {
        name: []const u8,
        count: u32 = 1,
        tags: []const []const u8 = &.{},
    };
    const lua = try open();
    defer lua.deinit();
    try run(lua, "items = { { name = 'sword', tags = { 'sharp' } }, { name = 'shield', count = 2 } }");

    const items = try lua.getGlobalAlloc(gpa, []Item, "items");
    defer zilua.free(gpa, items);
    try testing.expectEqualStrings("sword", items[0].name);
    try testing.expectEqualStrings("sharp", items[0].tags[0]);
    try testing.expectEqual(2, items[1].count);
    try testing.expectEqual(0, items[1].tags.len);

    // Without an allocator such structs can only come from userdata.
    try testing.expectError(error.TypeMismatch, lua.getGlobal(Item, "items"));
}

test "callAlloc, Function.callAlloc and deep copies of usertypes" {
    const Named = struct {
        name: []const u8,
        score: u32,
    };
    const lua = try open();
    defer lua.deinit();
    try run(lua, "function greet(who) return 'hi ' .. who, #who end");

    const text, const len = try lua.callAlloc(gpa, struct { []const u8, usize }, "greet", .{"bob"});
    defer zilua.free(gpa, text);
    try testing.expectEqualStrings("hi bob", text);
    try testing.expectEqual(3, len);

    const greet = try lua.getGlobal(zilua.Function, "greet");
    defer greet.deinit();
    const again = try greet.callAlloc(gpa, []const u8, .{"amy"});
    defer zilua.free(gpa, again);
    try testing.expectEqualStrings("hi amy", again);

    lua.setGlobal("n", Named{ .name = "static", .score = 3 });
    const copy = try lua.getGlobalAlloc(gpa, Named, "n");
    defer zilua.free(gpa, copy);
    try testing.expectEqualStrings("static", copy.name);
    try testing.expectEqual(3, copy.score);
}

const Holder = struct {
    data: ?zilua.Table = null,
};

const holders = struct {
    fn make() Holder {
        return .{};
    }

    fn length(t: zilua.Table) usize {
        return t.len();
    }
};

test "Lua-owned values release the handles in their fields" {
    const lua = try open();
    defer lua.deinit();
    lua.setGlobal("make", holders.make);
    const churn =
        \\for i = 1, 200 do
        \\  local h = make()
        \\  h.data = { i }
        \\  h.data = { i, i } -- releases the first table's reference
        \\end
    ;

    try run(lua, "warmup = make(); warmup.data = {}; warmup = nil");
    lua.collectGarbage();
    try run(lua, "x = 0");
    const before = helpers.registryTables(lua);
    try run(lua, churn);
    lua.collectGarbage();
    lua.collectGarbage();
    // Luau releases at the next call from Zig (its finalizers cannot).
    try run(lua, "x = 1");
    try testing.expectEqual(before, helpers.registryTables(lua));
}

test "handle parameters are released after the call" {
    const lua = try open();
    defer lua.deinit();
    lua.setGlobal("length", holders.length);
    try run(lua, "length({ 1 })");
    const before = helpers.registryTables(lua);
    try run(lua, "for i = 1, 500 do assert(length({ 1, 2 }) == 2) end");
    try testing.expectEqual(before, helpers.registryTables(lua));
}
