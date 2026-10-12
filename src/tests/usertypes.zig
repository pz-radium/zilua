//! Structs as userdata: methods, fields, metamethods, references, finalizers.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

const Vec2 = struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn length(self: Vec2) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn scale(self: *Vec2, k: f64) void {
        self.x *= k;
        self.y *= k;
    }

    pub fn __add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

test "usertype methods, fields and metamethods" {
    const lua = try open();
    defer lua.deinit();

    lua.registerType(Vec2);
    try run(lua,
        \\local v = Vec2.init(3, 4)
        \\len = v:length()
        \\v:scale(2)
        \\x = v.x
        \\v.y = 1
        \\y = v.y
        \\local w = v + Vec2.init(1, 1)
        \\wx = w.x
        \\assert(tostring(v):match("^([%w_]+): ") == "Vec2")
    );
    try testing.expectEqual(5.0, try lua.getGlobal(f64, "len"));
    try testing.expectEqual(6.0, try lua.getGlobal(f64, "x"));
    try testing.expectEqual(1.0, try lua.getGlobal(f64, "y"));
    try testing.expectEqual(7.0, try lua.getGlobal(f64, "wx"));

    try testing.expectError(error.Runtime, lua.doString("local v = Vec2.init(1, 2); v.z = 3"));
    try expectContains(lua.errorMessage(), "has no field 'z'");
    try testing.expectError(error.Runtime, lua.doString("local v = Vec2.init(1, 2); v.x = 'a'"));
    try expectContains(lua.errorMessage(), "bad value for field 'x'");
}

test "usertype values and references" {
    const lua = try open();
    defer lua.deinit();

    // By value: Lua owns a copy.
    lua.setGlobal("p", Vec2.init(1, 2));
    try run(lua, "p.x = 10");
    const p = try lua.getGlobal(Vec2, "p");
    try testing.expectEqual(10.0, p.x);

    // By pointer: Lua modifies the Zig object.
    var shared = Vec2.init(5, 5);
    lua.setGlobal("shared", &shared);
    try run(lua, "shared:scale(2); shared.y = 0");
    try testing.expectEqual(10.0, shared.x);
    try testing.expectEqual(0.0, shared.y);

    // By const pointer: read-only.
    const fixed = Vec2.init(1, 1);
    lua.setGlobal("fixed", &fixed);
    try run(lua, "fx = fixed.x");
    try testing.expectError(error.Runtime, lua.doString("fixed.x = 2"));
    try expectContains(lua.errorMessage(), "read-only");
    try testing.expectError(error.Runtime, lua.doString("fixed:scale(2)"));
}

test "nested struct fields are references into the parent" {
    const Body = struct {
        pos: Vec2,
        mass: f64,
    };
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("body", Body{ .pos = .init(0, 0), .mass = 1 });
    try run(lua, "pos = body.pos; pos.x = 3; body = nil");
    // Luau has no collectgarbage(), so collect from Zig.
    lua.collectGarbage();
    // pos keeps the body alive.
    try run(lua, "px = pos.x");
    try testing.expectEqual(3.0, try lua.getGlobal(f64, "px"));
}

test "deinit runs when Lua collects an owned value" {
    const Resource = struct {
        var finalized: u32 = 0;
        id: u32,

        pub fn deinit(self: *@This()) void {
            finalized += self.id;
        }
    };
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("r", Resource{ .id = 7 });
    try run(lua, "r = nil");
    lua.collectGarbage();
    lua.collectGarbage();
    try testing.expectEqual(7, Resource.finalized);
    // deinit is not callable from Lua, so it cannot run twice.
    lua.setGlobal("r2", Resource{ .id = 1 });
    try testing.expectError(error.Runtime, lua.doString("r2:deinit()"));
}

test "fields whose copies would share finalized resources cannot be assigned" {
    const Owner = struct {
        id: i64,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    const Holder = struct { owner: Owner, plain: Vec2 };
    const lua = try open();
    defer lua.deinit();

    var holder: Holder = .{ .owner = .{ .id = 1 }, .plain = .{ .x = 0, .y = 0 } };
    lua.setGlobal("holder", &holder);
    lua.setGlobal("other", Owner{ .id = 2 });
    lua.setGlobal("v", Vec2{ .x = 3, .y = 4 });
    // A copy of `other` would be deinit'd twice: refused.
    try testing.expectError(error.Runtime, lua.doString("holder.owner = other"));
    try expectContains(lua.errorMessage(), "cannot be set from Lua");
    try testing.expectEqual(1, holder.owner.id);
    // Plain values still copy.
    try run(lua, "holder.plain = v");
    try testing.expectEqual(3, holder.plain.x);
}

test "invalidate detaches Lua from a Zig object" {
    const Inner = struct { v: i64 };
    const Outer = struct {
        inner: Inner,
        hp: i64,

        pub const zilua_name = "Outer";

        pub fn get(self: *const @This()) i64 {
            return self.hp;
        }
    };
    const lua = try open();
    defer lua.deinit();

    var outer: Outer = .{ .inner = .{ .v = 1 }, .hp = 10 };
    lua.setGlobal("o", &outer);
    lua.setGlobal("same", &outer);
    try run(lua,
        \\inner = o.inner
        \\assert(inner.v == 1 and o:get() == 10)
        \\assert(rawequal(o, same)) -- one userdata per object
    );

    lua.invalidate(&outer);
    try testing.expectError(error.Runtime, lua.doString("return o.hp"));
    try expectContains(lua.errorMessage(), "Outer no longer exists");
    try testing.expectError(error.Runtime, lua.doString("return o:get()"));
    try expectContains(lua.errorMessage(), "Outer no longer exists");
    try testing.expectError(error.Runtime, lua.doString("o.hp = 1"));
    // References into the object die with it.
    try testing.expectError(error.Runtime, lua.doString("return inner.v"));
    try expectContains(lua.errorMessage(), "no longer exists");
    try run(lua, "assert(tostring(o) == 'Outer (no longer exists)')");

    // Pushing the object again gives Lua a new, live reference.
    lua.setGlobal("o", &outer);
    try run(lua, "assert(o:get() == 10 and not rawequal(o, same))");
}

test "metatables are locked and finalized values are unusable" {
    const Resource = struct {
        var finalized: u32 = 0;
        id: i64,

        pub const zilua_name = "Resource";

        pub fn get(self: *const @This()) i64 {
            return self.id;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            finalized += 1;
        }
    };
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("r", Resource{ .id = 5 });
    try run(lua, "assert(getmetatable(r) == 'Resource' and r:get() == 5)");
    if (zilua.lang == .luau) return; // no __gc, and no debug.getmetatable

    // Trusted code can still reach the metatable through the debug library.
    // A value finalized early is refused from then on, and finalized once.
    try run(lua,
        \\debug.getmetatable(r).__gc(r)
        \\assert(not pcall(function() return r:get() end))
    );
    try testing.expectEqual(1, Resource.finalized);
    try run(lua, "r = nil");
    lua.collectGarbage();
    try testing.expectEqual(1, Resource.finalized);
}

test "a reference a method returns stays tied to the value it points into" {
    const Chain = struct {
        var finalized: u32 = 0;
        x: f64,

        pub const zilua_name = "Chain";

        pub fn init(x: f64) @This() {
            return .{ .x = x };
        }

        /// The chaining setter: returns a pointer into its own userdata.
        pub fn scaled(self: *@This(), k: f64) *@This() {
            self.x *= k;
            return self;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            finalized += 1;
        }
    };
    const lua = try open();
    defer lua.deinit();

    lua.registerType(Chain);
    // Lua drops the value `ref` points into right away.
    try run(lua, "ref = Chain.init(2):scaled(3)");
    lua.collectGarbage();
    lua.collectGarbage();
    // The reference keeps it alive, so it is neither finalized nor freed.
    try testing.expectEqual(0, Chain.finalized);
    try run(lua, "assert(ref.x == 6)");
}

test "reading a field whose copy would need a second owner is refused" {
    const Item = struct {
        var finalized: u32 = 0;
        id: i64,

        pub fn deinit(self: *@This()) void {
            _ = self;
            finalized += 1;
        }
    };
    const Bag = struct {
        slot: ?Item,
        pair: [2]Item,
        plain: ?Vec2,
    };
    const lua = try open();
    defer lua.deinit();

    var bag: Bag = .{ .slot = .{ .id = 1 }, .pair = .{ .{ .id = 2 }, .{ .id = 3 } }, .plain = .init(1, 2) };
    lua.setGlobal("bag", &bag);
    try testing.expectError(error.Runtime, lua.doString("return bag.slot"));
    try expectContains(lua.errorMessage(), "cannot read Bag.slot from Lua");
    try testing.expectError(error.Runtime, lua.doString("return bag.pair"));
    // Fields that copy cleanly still do.
    try run(lua, "assert(bag.plain.x == 1)");
    lua.collectGarbage();
    lua.collectGarbage();
    try testing.expectEqual(0, Item.finalized);
}

test "a value with a finalizer cannot be built from a table" {
    const Handle = struct {
        fd: i64,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn number(self: @This()) i64 {
            return self.fd;
        }
    };
    const lua = try open();
    defer lua.deinit();

    lua.registerType(Handle);
    // A plain table is not a Handle, however much it looks like one.
    try testing.expectError(error.Runtime, lua.doString("return Handle.number({ fd = 7 })"));
    try expectContains(lua.errorMessage(), "Handle expected");
}
