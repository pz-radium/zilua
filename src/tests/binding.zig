//! Bound-function extras: tagged unions, zilua.Args, injected parameters,
//! Owned results, std types left out, callThen.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

const Shape = union(enum) {
    circle: f64,
    rect: struct { f64, f64 },
    empty,
};

const funcs = struct {
    fn area(shape: Shape) f64 {
        return switch (shape) {
            .circle => |r| 3 * r * r,
            .rect => |r| r[0] * r[1],
            .empty => 0,
        };
    }

    fn sum(args: zilua.Args) !f64 {
        var total: f64 = 0;
        for (0..args.len()) |i| total += try args.get(f64, i);
        return total;
    }

    fn countRest(prefix: []const u8, rest: zilua.Args) usize {
        _ = prefix;
        return rest.len();
    }

    fn byteCount(gpa: std.mem.Allocator, text: []const u8) !usize {
        const copy = try gpa.dupe(u8, text);
        defer gpa.free(copy);
        return copy.len;
    }

    fn shout(gpa: std.mem.Allocator, text: []const u8) !zilua.Owned([]u8) {
        const out = try gpa.alloc(u8, text.len);
        for (out, text) |*dst, ch| dst.* = std.ascii.toUpper(ch);
        return .{ .value = out, .gpa = gpa };
    }

    fn withIo(io: std.Io) i64 {
        _ = io;
        return 7;
    }

    fn apply(f: zilua.Function, x: i64) zilua.CallThen(addOne, struct { i64 }) {
        return .{ .func = f, .args = .{x} };
    }

    fn addOne(result: i64) i64 {
        return result + 1;
    }
};

test "tagged unions are one-entry tables" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("area", funcs.area);
    try run(lua, "a = area({ circle = 1 }); b = area({ rect = { 2, 3 } }); c = area('empty')");
    try testing.expectEqual(3.0, try lua.getGlobal(f64, "a"));
    try testing.expectEqual(6.0, try lua.getGlobal(f64, "b"));
    try testing.expectEqual(0.0, try lua.getGlobal(f64, "c"));

    lua.setGlobal("shape", Shape{ .circle = 2 });
    lua.setGlobal("none", @as(Shape, .empty));
    try run(lua, "assert(shape.circle == 2 and none.empty == true)");
    try testing.expectEqual(Shape{ .circle = 2 }, try lua.getGlobal(Shape, "shape"));

    try testing.expectError(error.Runtime, lua.doString("area({ circle = 1, rect = { 1, 2 } })"));
    try testing.expectError(error.Runtime, lua.doString("area({ square = 1 })"));
    try expectContains(lua.errorMessage(), "invalid enum value");
}

test "*anyopaque parameters take light userdata only" {
    const Opaque = struct {
        fn check(p: *anyopaque) bool {
            _ = p;
            return true;
        }
    };
    const Box = struct { n: i64 };
    const lua = try open();
    defer lua.deinit();

    var x: u8 = 0;
    lua.setGlobal("check", Opaque.check);
    lua.setGlobal("handle", @as(*anyopaque, &x));
    lua.setGlobal("box", Box{ .n = 1 });
    try run(lua, "assert(check(handle))");
    try testing.expectError(error.Runtime, lua.doString("check(box)"));
}

test "zilua.Args takes any number of arguments" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("sum", funcs.sum);
    lua.setGlobal("countRest", funcs.countRest);
    try run(lua,
        \\assert(sum() == 0 and sum(1, 2, 3.5) == 6.5)
        \\assert(countRest("x") == 0 and countRest("x", 1, nil, 3) == 3)
    );
    try testing.expectError(error.Runtime, lua.doString("sum(1, 'a')"));
}

test "allocator and std.Io parameters are injected" {
    const lua = try open();
    defer lua.deinit();

    // The state's allocator is testing.allocator, which catches leaks.
    lua.setGlobal("byteCount", funcs.byteCount);
    lua.setGlobal("shout", funcs.shout);
    try run(lua, "assert(byteCount('hello') == 5 and shout('hey') == 'HEY')");

    lua.setGlobal("withIo", funcs.withIo);
    try testing.expectError(error.Runtime, lua.doString("withIo()"));
    try expectContains(lua.errorMessage(), "call State.setIo first");
    lua.setIo(testing.io);
    try run(lua, "assert(withIo() == 7)");
}

const Host = struct {
    gpa: std.mem.Allocator,
    count: u32 = 0,

    pub fn bump(self: *Host) void {
        self.count += 1;
    }

    pub fn write(self: Host, writer: *std.Io.Writer) void {
        _ = self;
        _ = writer;
    }
};

test "std types are left out of usertypes" {
    const lua = try open();
    defer lua.deinit();

    var host: Host = .{ .gpa = testing.allocator };
    lua.setGlobal("host", &host);
    try run(lua, "host:bump(); assert(host.gpa == nil and host.write == nil and host.count == 1)");
    try testing.expectEqual(1, host.count);
}

test "callThen continues in Zig with the results of a Lua call" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("apply", funcs.apply);
    try run(lua, "r = apply(function(v) return v * 2 end, 5)");
    try testing.expectEqual(11, try lua.getGlobal(i64, "r"));

    // The Lua function may yield on 5.2+ and Luau, which have continuations,
    // whether the bound function is a global or a method.
    lua.setGlobal("scaler", Scaler{ .factor = 3 });
    try run(lua,
        \\function task()
        \\  local a = apply(function(v) return coroutine.yield(v) end, 5)
        \\  local b = scaler:apply(function(v) return coroutine.yield(v) end, 2)
        \\  return a + b
        \\end
    );
    const task = try lua.getGlobal(zilua.Function, "task");
    defer task.deinit();
    const co = lua.newThread(task);
    defer co.deinit();
    switch (zilua.lang) {
        .lua52, .lua53, .lua54, .lua55, .luau => {
            try testing.expectEqual(5, (try co.run(i64, .{})).yielded);
            try testing.expectEqual(6, (try co.run(i64, .{20})).yielded);
            // (20 + 1) + (100 + 1)
            try testing.expectEqual(122, (try co.run(i64, .{100})).returned);
        },
        .lua51, .luajit => {
            try testing.expectError(error.Runtime, co.run(i64, .{}));
            try expectContains(lua.errorMessage(), "yield");
        },
    }
}

const Scaler = struct {
    factor: i64,

    pub fn apply(self: *const Scaler, f: zilua.Function, x: i64) zilua.CallThen(funcs.addOne, struct { i64 }) {
        return .{ .func = f, .args = .{x * self.factor} };
    }
};
