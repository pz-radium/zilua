//! Game-style scripting with coroutines, in a sandbox with an instruction
//! budget. Run with `zig build run-scheduler`.

const std = @import("std");
const zilua = @import("zilua");

fn log(message: []const u8) void {
    std.debug.print("[lua] {s}\n", .{message});
}

const script =
    \\-- Untrusted level script: it only sees what the host put in its sandbox.
    \\function door()
    \\  log("door: opening")
    \\  wait(1.0)
    \\  log("door: open")
    \\end
    \\
    \\function level()
    \\  log("level: start")
    \\  spawn(door)
    \\  for wave = 1, 3 do
    \\    log("level: wave " .. wave)
    \\    wait(0.5)
    \\  end
    \\  log("level: done")
    \\end
;

fn onError(state: zilua.State, message: []const u8) void {
    _ = state;
    std.debug.print("task failed: {s}\n", .{message});
}

pub fn main(init: std.process.Init) !void {
    const lua = try zilua.State.init(init.gpa, .{});
    defer lua.deinit();

    var scheduler: zilua.Scheduler = .init(lua, init.gpa);
    defer scheduler.deinit();
    scheduler.on_error = onError;
    // wait and spawn are globals; copy them into the sandbox below.
    scheduler.registerWait("wait");
    scheduler.registerSpawn("spawn");

    // Stop runaway scripts: about a million instructions and a megabyte each
    // time a task runs.
    const sandbox = try lua.newSandbox(.{ .limits = .{ .memory = 1 << 20, .instructions = 1_000_000 } });
    defer sandbox.deinit();
    try sandbox.set("log", log);
    inline for (.{ "wait", "spawn" }) |name| {
        const f = try lua.getGlobal(zilua.Function, name);
        defer f.deinit();
        try sandbox.set(name, f);
    }

    sandbox.doString(script) catch |err| {
        std.debug.print("script error: {s}\n", .{lua.errorMessage()});
        return err;
    };

    const level = try sandbox.get(zilua.Function, "level");
    defer level.deinit();
    // The sandbox's limits apply to the task, and to `door`, which it spawns.
    try scheduler.spawnLimited(level, .{}, sandbox.limits);

    // A fixed-step game loop.
    var time: f64 = 0;
    while (scheduler.count() > 0) : (time += 0.25) {
        scheduler.update(time);
    }
    std.debug.print("all tasks finished at t = {d}\n", .{scheduler.now});
}
