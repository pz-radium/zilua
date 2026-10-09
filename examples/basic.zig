//! A short tour of zilua. Run with `zig build run-basic`.

const std = @import("std");
const zilua = @import("zilua");

const Vec2 = struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn length(self: Vec2) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn __add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

const Player = struct {
    name: []const u8,
    hp: i32,
    pos: Vec2,

    pub fn damage(self: *Player, amount: i32) void {
        self.hp = @max(0, self.hp - amount);
    }

    pub fn isAlive(self: *const Player) bool {
        return self.hp > 0;
    }
};

fn log(message: []const u8) void {
    std.debug.print("[lua] {s}\n", .{message});
}

const script =
    \\log("hello from " .. _VERSION)
    \\
    \\-- `player` is a reference to the Zig variable: changes are visible in Zig.
    \\player:damage(30)
    \\player.pos.x = player.pos.x + 5
    \\player.pos = player.pos + Vec2.init(1, 1)
    \\log(player.name .. " has " .. player.hp .. " hp at x = " .. player.pos.x)
    \\
    \\function on_tick(dt)
    \\  return dt * 2, player:isAlive()
    \\end
;

pub fn main(init: std.process.Init) !void {
    const lua = try zilua.State.init(init.gpa, .{});
    defer lua.deinit();

    var player: Player = .{ .name = "ziggy", .hp = 100, .pos = .init(0, 0) };
    lua.setGlobal("log", log);
    lua.setGlobal("player", &player);
    lua.registerType(Vec2);

    lua.doString(script) catch |err| {
        std.debug.print("lua error: {s}\n", .{lua.errorMessage()});
        return err;
    };

    const doubled, const alive = try lua.call(struct { f64, bool }, "on_tick", .{0.5});
    std.debug.print("on_tick returned {d} and {}\n", .{ doubled, alive });
    std.debug.print("in Zig: hp = {d}, pos = ({d}, {d})\n", .{ player.hp, player.pos.x, player.pos.y });
}
