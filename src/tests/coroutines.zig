//! Coroutines driven from Zig, yielding from bound functions, the scheduler.

const std = @import("std");
const testing = std.testing;
const zilua = @import("../zilua.zig");
const helpers = @import("helpers.zig");
const open = helpers.open;
const run = helpers.run;
const expectContains = helpers.expectContains;

test "run a coroutine until it returns" {
    const lua = try open();
    defer lua.deinit();

    try run(lua,
        \\function counter(start)
        \\  local n = start
        \\  while n < start + 2 do
        \\    local step = coroutine.yield(n)
        \\    n = n + (step or 1)
        \\  end
        \\  return 99
        \\end
    );
    const counter = try lua.getGlobal(zilua.Function, "counter");
    defer counter.deinit();
    const co = lua.newThread(counter);
    defer co.deinit();

    try testing.expectEqual(.ready, co.status());
    try testing.expectEqual(10, (try co.run(i64, .{10})).yielded);
    try testing.expectEqual(.suspended, co.status());
    try testing.expectEqual(11, (try co.run(i64, .{})).yielded);
    try testing.expectEqual(99, (try co.run(i64, .{})).returned);
    try testing.expectEqual(.dead, co.status());
    try testing.expectEqual(0, lua.getTop());
}

const funcs = struct {
    fn ask(question: i64) zilua.Yield(i64) {
        return zilua.yield(question * 2);
    }
};

test "bound functions yield with zilua.yield" {
    const lua = try open();
    defer lua.deinit();

    lua.setGlobal("ask", funcs.ask);
    try run(lua,
        \\function task()
        \\  local answer = ask(21) -- yields 42; the value given to run comes back
        \\  return answer + 1
        \\end
    );
    const task = try lua.getGlobal(zilua.Function, "task");
    defer task.deinit();
    const co = lua.newThread(task);
    defer co.deinit();

    try testing.expectEqual(42, (try co.run(i64, .{})).yielded);
    try testing.expectEqual(101, (try co.run(i64, .{100})).returned);

    // Yielding outside a coroutine is an ordinary Lua error.
    try testing.expectError(error.Runtime, lua.doString("ask(1)"));
}

test "errors inside a coroutine are returned by run" {
    const lua = try open();
    defer lua.deinit();

    try run(lua, "function broken() coroutine.yield(1); error('broken here') end");
    const broken = try lua.getGlobal(zilua.Function, "broken");
    defer broken.deinit();
    const co = lua.newThread(broken);
    defer co.deinit();

    try testing.expectEqual(1, (try co.run(i64, .{})).yielded);
    try testing.expectError(error.Runtime, co.run(void, .{}));
    try expectContains(lua.errorMessage(), "broken here");
    if (zilua.lang != .luau) try expectContains(lua.errorMessage(), "stack traceback:");
    try testing.expectEqual(.dead, co.status());
}

test "coroutines created in Lua are Threads in Zig" {
    const lua = try open();
    defer lua.deinit();

    try run(lua, "co = coroutine.create(function(a) local b = coroutine.yield(a + 1) return b * 2 end)");
    const co = try lua.getGlobal(zilua.Thread, "co");
    defer co.deinit();
    try testing.expectEqual(2, (try co.run(i64, .{1})).yielded);
    try testing.expectEqual(10, (try co.run(i64, .{5})).returned);
}

test "Scheduler: wait and spawn" {
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.registerWait("wait");
    scheduler.registerSpawn("spawn");

    try run(lua,
        \\log = {}
        \\function main()
        \\  table.insert(log, "start")
        \\  spawn(function() wait(0.5) table.insert(log, "child") end)
        \\  wait(1)
        \\  table.insert(log, "end")
        \\end
    );
    const main = try lua.getGlobal(zilua.Function, "main");
    defer main.deinit();
    try scheduler.spawn(main, .{});
    try testing.expectEqual(2, scheduler.count());

    scheduler.update(0.6);
    try testing.expectEqual(1, scheduler.count());
    scheduler.update(1.0);
    try testing.expectEqual(0, scheduler.count());
    try run(lua, "assert(table.concat(log, ',') == 'start,child,end')");
}

test "Scheduler: failing tasks are reported and dropped" {
    const Errors = struct {
        var seen: u32 = 0;

        fn onError(state: zilua.State, message: []const u8) void {
            _ = state;
            if (helpers.contains(message, "oops")) seen += 1;
        }
    };
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.registerWait("wait");
    scheduler.on_error = Errors.onError;

    try run(lua, "function failing() wait() error('oops') end");
    const failing = try lua.getGlobal(zilua.Function, "failing");
    defer failing.deinit();
    try scheduler.spawn(failing, .{});
    try testing.expectEqual(1, scheduler.count());
    scheduler.update(0);
    try testing.expectEqual(0, scheduler.count());
    try testing.expectEqual(1, Errors.seen);
}

const jobs = struct {
    fn slowDouble(io: std.Io, x: i64) i64 {
        io.sleep(.fromMilliseconds(5), .awake) catch {};
        return x * 2;
    }

    fn failing() error{Nope}!i64 {
        return error.Nope;
    }

    fn compute(lua: zilua.State, x: i64) !zilua.Yield(zilua.Scheduler.Job) {
        const scheduler = zilua.Scheduler.of(lua) orelse return lua.fail("no scheduler");
        return zilua.yield(try scheduler.startJob(slowDouble, .{ testing.io, x }));
    }

    const Forty = blk: {
        var types: [40]type = undefined;
        for (&types) |*t| t.* = i64;
        const final = types;
        break :blk @Tuple(&final);
    };

    fn forty() Forty {
        var result: Forty = undefined;
        inline for (0..40) |i| result[i] = i;
        return result;
    }

    fn many(lua: zilua.State) !zilua.Yield(zilua.Scheduler.Job) {
        const scheduler = zilua.Scheduler.of(lua) orelse return lua.fail("no scheduler");
        return zilua.yield(try scheduler.startJob(forty, .{}));
    }

    fn computeFailing(lua: zilua.State) !zilua.Yield(zilua.Scheduler.Job) {
        const scheduler = zilua.Scheduler.of(lua) orelse return lua.fail("no scheduler");
        return zilua.yield(try scheduler.startJob(failing, .{}));
    }
};

test "Scheduler: jobs need Scheduler.io, not the state's std.Io" {
    const Errors = struct {
        var seen: u32 = 0;

        fn onError(state: zilua.State, message: []const u8) void {
            _ = state;
            if (helpers.contains(message, "set Scheduler.io first")) seen += 1;
        }
    };
    const lua = try open();
    defer lua.deinit();
    lua.setIo(testing.io);
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.attach();
    scheduler.on_error = Errors.onError;
    lua.setGlobal("compute", jobs.compute);

    try run(lua, "function task() compute(1) end");
    const task = try lua.getGlobal(zilua.Function, "task");
    defer task.deinit();
    try scheduler.spawn(task, .{});
    try testing.expectEqual(0, scheduler.count());
    try testing.expectEqual(1, Errors.seen);
}

test "Scheduler: tasks run under the limits they are given or inherit" {
    const Errors = struct {
        var instructions: u32 = 0;
        var memory: u32 = 0;

        fn onError(state: zilua.State, message: []const u8) void {
            _ = state;
            if (helpers.contains(message, "instruction limit exceeded")) instructions += 1;
            if (helpers.contains(message, "not enough memory")) memory += 1;
        }
    };
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.on_error = Errors.onError;
    scheduler.registerWait("wait");
    scheduler.registerSpawn("spawn");

    const sandbox = try lua.newSandbox(.{ .limits = .{ .memory = 1 << 20, .instructions = 100_000 } });
    defer sandbox.deinit();
    inline for (.{ "wait", "spawn" }) |name| {
        const f = try lua.getGlobal(zilua.Function, name);
        defer f.deinit();
        try sandbox.set(name, f);
    }
    // Each would finish without limits; under them only `short` does.
    try sandbox.doString(
        \\function busy() wait() for i = 1, 10000000 do end end
        \\function hog() wait() local t = {} for i = 1, 100000 do t[i] = string.rep("x", 1000) .. i end end
        \\function short() wait() local n = 0 for i = 1, 1000 do n = n + i end done = n end
        \\function spawner() spawn(busy) end
    );
    inline for (.{ "busy", "hog", "short" }) |name| {
        const f = try sandbox.get(zilua.Function, name);
        defer f.deinit();
        try scheduler.spawnLimited(f, .{}, sandbox.limits);
    }
    // Spawned by sandbox code, which runs under the sandbox's limits.
    try sandbox.call(void, "spawner", .{});
    try testing.expectEqual(4, scheduler.count());

    scheduler.update(0);
    try testing.expectEqual(0, scheduler.count());
    try testing.expectEqual(2, Errors.instructions);
    try testing.expectEqual(1, Errors.memory);
    try testing.expectEqual(500500, try sandbox.get(i64, "done"));
}

test "Scheduler: runaway nesting and bad waits are reported, not fatal" {
    const Errors = struct {
        var overflow: u32 = 0;
        var bad_wait: u32 = 0;

        fn onError(state: zilua.State, message: []const u8) void {
            _ = state;
            if (helpers.contains(message, "C stack overflow")) overflow += 1;
            if (helpers.contains(message, "seconds to wait")) bad_wait += 1;
        }
    };
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.on_error = Errors.onError;
    scheduler.registerWait("wait");
    scheduler.registerSpawn("spawn");

    // Each task spawns the next, which runs right away inside it.
    try run(lua, "function nest() spawn(nest) end");
    const nest = try lua.getGlobal(zilua.Function, "nest");
    defer nest.deinit();
    try scheduler.spawn(nest, .{});
    try testing.expectEqual(1, Errors.overflow);

    // NaN seconds would never be due.
    try run(lua, "function nan() wait(0 / 0) end");
    const nan = try lua.getGlobal(zilua.Function, "nan");
    defer nan.deinit();
    try scheduler.spawn(nan, .{});
    try testing.expectEqual(1, Errors.bad_wait);
    try testing.expectEqual(0, scheduler.count());
}

test "Scheduler: jobs keep their std.Io and room for many results" {
    const io = testing.io;
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.io = io;
    scheduler.attach();
    lua.setGlobal("many", jobs.many);

    try run(lua, "function task() count = select('#', many()) end");
    const task = try lua.getGlobal(zilua.Function, "task");
    defer task.deinit();
    try scheduler.spawn(task, .{});
    // The job finishes on the std.Io it started with.
    scheduler.io = null;
    var spins: usize = 0;
    while (scheduler.count() > 0 and spins < 5000) : (spins += 1) {
        scheduler.update(0);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(40, try lua.getGlobal(i64, "count"));
}

test "Scheduler: only one task can wait for a job" {
    const Errors = struct {
        var seen: u32 = 0;

        fn onError(state: zilua.State, message: []const u8) void {
            _ = state;
            if (helpers.contains(message, "already waiting")) seen += 1;
        }
    };
    const io = testing.io;
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.io = io;
    scheduler.on_error = Errors.onError;
    scheduler.registerSpawn("spawn");
    lua.setGlobal("compute", jobs.compute);

    // Run in a coroutine of the script's own, compute hands the job to the
    // script, which then yields it from two tasks.
    try run(lua,
        \\local job = coroutine.wrap(function() local j = compute(21) return j end)()
        \\spawn(function() result = coroutine.yield(job) end)
        \\spawn(function() coroutine.yield(job) end)
    );
    try testing.expectEqual(1, Errors.seen);
    try testing.expectEqual(1, scheduler.count());
    var spins: usize = 0;
    while (scheduler.count() > 0 and spins < 5000) : (spins += 1) {
        scheduler.update(0);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(42, try lua.getGlobal(i64, "result"));
}

test "Scheduler: spawn fails once its scheduler is gone" {
    const lua = try open();
    defer lua.deinit();
    {
        var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
        scheduler.registerSpawn("spawn");
        scheduler.deinit();
    }
    try testing.expectError(error.Runtime, lua.doString("spawn(function() end)"));
    try expectContains(lua.errorMessage(), "scheduler");
    try testing.expectEqual(null, zilua.Scheduler.of(lua));
}

test "Scheduler: tasks wait for std.Io jobs" {
    const io = testing.io;
    const lua = try open();
    defer lua.deinit();
    var scheduler: zilua.Scheduler = .init(lua, testing.allocator);
    defer scheduler.deinit();
    scheduler.io = io;
    scheduler.attach();
    lua.setGlobal("compute", jobs.compute);
    lua.setGlobal("computeFailing", jobs.computeFailing);

    try run(lua, "function task() result = compute(21); value, err = computeFailing() end");
    const task = try lua.getGlobal(zilua.Function, "task");
    defer task.deinit();
    try scheduler.spawn(task, .{});
    try testing.expectEqual(1, scheduler.count());

    var spins: usize = 0;
    while (scheduler.count() > 0 and spins < 5000) : (spins += 1) {
        scheduler.update(0);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(0, scheduler.count());
    try testing.expectEqual(42, try lua.getGlobal(i64, "result"));
    try run(lua, "assert(value == nil and err == 'Nope')");
}
