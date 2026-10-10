//! A small cooperative scheduler for Lua coroutines that wait, the usual
//! shape of game scripting:
//!
//!     var scheduler: zilua.Scheduler = .init(lua, gpa);
//!     defer scheduler.deinit();
//!     scheduler.registerWait("wait"); // wait(seconds) in Lua
//!     scheduler.registerSpawn("spawn"); // spawn(function) in Lua
//!     try scheduler.spawn(main_script, .{});
//!     while (running) scheduler.update(seconds_since_start);
//!
//! A task is a coroutine. When it yields a number it sleeps for that many
//! seconds of the time given to `update`; yielding nothing (or nil) waits for
//! the next update. A task ends when its function returns or fails.
//!
//! Tasks can also wait for Zig work done through `std.Io`: a bound function
//! starts it with `startJob` and yields the job, and the task resumes with
//! the job's result once it is done (see `startJob`).
//!
//! A task can run under limits, like a sandbox call: `spawnLimited` takes
//! them (`sandbox.limits`, say), and a task spawned by code that runs under
//! limits (a sandbox call, a limited task) inherits them.

const std = @import("std");
const api = @import("../runtime/api.zig");
const convert = @import("../binding/convert.zig");
const State = @import("State.zig");
const Sandbox = @import("Sandbox.zig");
const ref = @import("ref.zig");
const thread = @import("thread.zig");

const Scheduler = @This();

state: State,
gpa: std.mem.Allocator,
/// Needed for jobs (`startJob`).
io: ?std.Io = null,
tasks: std.ArrayList(Task) = .empty,
/// Jobs started and not yet handed back to their task.
jobs: std.ArrayList(*JobHeader) = .empty,
/// The time given to the last `update`, in seconds.
now: f64 = 0,
/// Called with the message (and traceback) of a task that failed, before
/// the task is dropped.
on_error: ?*const fn (state: State, message: []const u8) void = null,
/// Lua-owned cell through which `spawn` functions reach this scheduler;
/// `deinit` empties it, so scripts that still call them get an error.
spawn_handle: ?*?*Scheduler = null,
spawn_handle_ref: c_int = 0,

const Task = struct {
    thread: thread.Thread,
    wake: Wake,
    /// Applied every time the task runs.
    limits: ?Sandbox.Limits,
};

const Wake = union(enum) {
    /// Run again once `update` reaches this time.
    at: f64,
    /// Run again once this job is done, with its result.
    job: *JobHeader,
};

pub fn init(state: State, gpa: std.mem.Allocator) Scheduler {
    return .{ .state = state, .gpa = gpa };
}

/// Drops every task. Jobs still running are canceled and awaited. Lua
/// functions from `registerSpawn` raise an error from now on.
pub fn deinit(self: *Scheduler) void {
    const L = self.state.L;
    if (self.spawn_handle) |handle| {
        handle.* = null;
        api.unref(L, api.registry_index, self.spawn_handle_ref);
    }
    if (of(self.state) == self) {
        api.pushNil(L);
        api.rawSetP(L, api.registry_index, &registry_key);
    }
    for (self.tasks.items) |task| task.thread.deinit();
    self.tasks.deinit(self.gpa);
    for (self.jobs.items) |job| {
        job.cancel(job);
        job.destroy(job, self.gpa);
    }
    self.jobs.deinit(self.gpa);
}

/// Number of tasks that have not finished.
pub fn count(self: *const Scheduler) usize {
    return self.tasks.items.len;
}

/// Starts `func` with the elements of the tuple `args` as a new task and
/// runs it until it first waits. It runs under the limits of the code that
/// spawns it, if that runs under any (a sandbox call, a limited task).
pub fn spawn(self: *Scheduler, func: ref.Function, args: anytype) error{OutOfMemory}!void {
    return self.spawnLimited(func, args, self.state.activeLimits());
}

/// Like `spawn`, with `limits` applied every time the task runs, as for a
/// call into a sandbox: each run until the task waits again may use that
/// many instructions and bytes. Tasks it spawns inherit them.
///
///     try scheduler.spawnLimited(level, .{}, sandbox.limits);
pub fn spawnLimited(self: *Scheduler, func: ref.Function, args: anytype, limits: ?Sandbox.Limits) error{OutOfMemory}!void {
    const t = self.state.newThread(func);
    const co = t.state.L;
    if (!api.checkStack(co, convert.resultCount(@TypeOf(args)) + 4)) {
        t.deinit();
        return error.OutOfMemory;
    }
    const wake = self.step(t, convert.pushMulti(co, args), limits) orelse {
        t.deinit();
        return;
    };
    // Appended after running: the task may have spawned tasks of its own.
    self.tasks.append(self.gpa, .{ .thread = t, .wake = wake, .limits = limits }) catch |err| {
        t.deinit();
        return err;
    };
}

/// Advances the clock to `now` (seconds) and resumes every task whose wait
/// is over or whose job is done. Tasks spawned during the update first run
/// again on the next one.
pub fn update(self: *Scheduler, now: f64) void {
    self.now = now;
    var i: usize = 0;
    var remaining = self.tasks.items.len;
    while (remaining > 0) : (remaining -= 1) {
        const task = self.tasks.items[i];
        const co = task.thread.state.L;
        const nargs: c_int = switch (task.wake) {
            .at => |at| if (at <= now) 0 else {
                i += 1;
                continue;
            },
            .job => |job| blk: {
                if (!job.done.load(.acquire)) {
                    i += 1;
                    continue;
                }
                const n = job.finish(job, co);
                self.forgetJob(job);
                break :blk n;
            },
        };
        // Index, not pointer: running the task may grow the list.
        if (self.step(task.thread, nargs, task.limits)) |wake| {
            self.tasks.items[i].wake = wake;
            i += 1;
        } else {
            task.thread.deinit();
            _ = self.tasks.orderedRemove(i);
        }
    }
}

/// Resumes a task with `nargs` values pushed onto its stack, under its
/// `limits`, and works out what it waits for next. Returns null when it is
/// finished.
fn step(self: *Scheduler, t: thread.Thread, nargs: c_int, limits: ?Sandbox.Limits) ?Wake {
    const co = t.state.L;
    const saved = if (limits) |l| self.state.applyLimits(l.memory, l.instructions) else null;
    const resumed = t.resumeRaw(nargs);
    if (saved) |s| self.state.restoreLimits(s);
    const result = resumed catch |err| {
        self.report(self.state.errorMessage(), err);
        return null;
    };
    defer api.pop(co, result.nresults);
    if (result.status == .ok) return null;
    if (result.nresults == 0) return .{ .at = self.now };

    const first = -result.nresults;
    switch (api.typeOf(co, first)) {
        .nil => return .{ .at = self.now },
        .number => {
            // NaN would never compare as due: report it instead.
            const seconds = api.toNumber(co, first).?;
            if (!std.math.isNan(seconds)) return .{ .at = self.now + seconds };
        },
        .light_userdata => {
            const ptr = api.toUserdata(co, first);
            for (self.jobs.items) |job| {
                if (@as(?*anyopaque, job) != ptr) continue;
                // A script can get hold of a job (by calling the function
                // that starts it in a coroutine of its own) and yield it from
                // several tasks. Only one may wait: the job is freed once it
                // has handed its result over.
                if (job.claimed) {
                    self.report("task yielded a job that another task is already waiting for", null);
                    return null;
                }
                job.claimed = true;
                return .{ .job = job };
            }
        },
        else => {},
    }
    self.report("task yielded something other than seconds to wait or a job", null);
    return null;
}

fn report(self: *Scheduler, message: []const u8, err: ?State.Error) void {
    const on_error = self.on_error orelse return;
    const text = if (err != null and message.len == 0) @errorName(err.?) else message;
    on_error(self.state, text);
}

/// Defines the global function `name(seconds)` for tasks to wait with. It is
/// `coroutine.yield` with a clearer name; scripts may use either.
pub fn registerWait(self: *const Scheduler, name: [:0]const u8) void {
    self.state.setGlobal(name, wait);
}

fn wait(seconds: ?f64) thread.Yield(?f64) {
    return thread.yield(seconds);
}

/// Defines the global function `name(func)` that starts `func` as a task.
/// Also makes the scheduler reachable from bound functions (`of`). The
/// scheduler must stay at the same address while the state can use it.
pub fn registerSpawn(self: *Scheduler, name: [:0]const u8) void {
    self.attach();
    const L = self.state.L;
    if (self.spawn_handle) |handle| {
        _ = api.rawGetI(L, api.registry_index, self.spawn_handle_ref);
        std.debug.assert(handle.* == self);
    } else {
        const handle: *?*Scheduler = @ptrCast(@alignCast(api.newUserdata(L, @sizeOf(?*Scheduler))));
        handle.* = self;
        api.pushValue(L, -1);
        self.spawn_handle_ref = api.ref(L, api.registry_index);
        self.spawn_handle = handle;
    }
    api.pushCClosureNamed(L, spawnFromLua, 1, name.ptr);
    api.setGlobal(L, name.ptr);
}

fn spawnFromLua(L_: ?*api.lua_State) callconv(.c) c_int {
    const L = L_.?;
    const handle: *?*Scheduler = @ptrCast(@alignCast(api.toUserdata(L, api.upvalueIndex(1)).?));
    const self = handle.* orelse return api.raiseF(L, "the scheduler behind this function is gone");
    if (api.typeOf(L, 1) != .function) return api.raiseArgError(L, 1, "function expected");
    const func = ref.Function.fromStack(State.fromLua(L), 1);
    const result = self.spawn(func, .{});
    func.deinit();
    // Raised only now, with no Zig defer pending.
    result catch return api.raiseF(L, "not enough memory");
    return 0;
}

var registry_key: u8 = 0;

/// Makes this scheduler what `of` returns for its state. It must stay at
/// the same address while the state can use it.
pub fn attach(self: *Scheduler) void {
    api.pushLightUserdata(self.state.L, self);
    api.rawSetP(self.state.L, api.registry_index, &registry_key);
}

/// The scheduler attached to the state, for bound functions that start jobs.
pub fn of(state: State) ?*Scheduler {
    _ = api.rawGetP(state.L, api.registry_index, &registry_key);
    defer api.pop(state.L, 1);
    return @ptrCast(@alignCast(api.toUserdata(state.L, -1)));
}

// ---------------------------------------------------------------------------
// Jobs

/// Zig work started with `startJob`. Yield it from a bound function
/// (`return zilua.yield(job)`) to suspend the calling task until it is done.
pub const Job = struct {
    ptr: *JobHeader,

    pub const zilua_special = {};
    pub const zilua_light_userdata = {};
};

const JobHeader = struct {
    done: std.atomic.Value(bool) = .init(false),
    /// A task waits for this job (see `step`).
    claimed: bool = false,
    /// The `std.Io` the work runs on, kept even if `Scheduler.io` changes.
    io: std.Io,
    /// Awaits the work and pushes its result onto `L`; returns how many values.
    finish: *const fn (header: *JobHeader, L: *api.lua_State) c_int,
    cancel: *const fn (header: *JobHeader) void,
    destroy: *const fn (header: *JobHeader, gpa: std.mem.Allocator) void,
};

/// Runs `function(args...)` through the scheduler's `std.Io`: concurrently
/// when the Io supports it, otherwise possibly right away. The task that
/// yields the returned job resumes with the function's result as the
/// result of the bound function's call: its value(s), `zilua.Owned` results
/// freed after pushing, or `nil, "ErrorName"` for an error.
///
/// Fails with `error.NoSchedulerIo` while `io` is not set (the state's own
/// `std.Io`, from `State.setIo`, is not used here).
///
/// `function` runs on another thread and must not touch the Lua state.
/// Copy any Lua strings it needs into its arguments: they are not kept alive.
///
///     fn fetch(lua: zilua.State, n: i64) !zilua.Yield(zilua.Scheduler.Job) {
///         const scheduler = zilua.Scheduler.of(lua) orelse return lua.fail("no scheduler");
///         return zilua.yield(try scheduler.startJob(slowWork, .{n}));
///     }
pub fn startJob(self: *Scheduler, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) error{ OutOfMemory, NoSchedulerIo }!Job {
    const io = self.io orelse return error.NoSchedulerIo;
    const Impl = JobImpl(function);
    const impl = try self.gpa.create(Impl);
    errdefer self.gpa.destroy(impl);
    impl.* = .{
        .header = .{ .io = io, .finish = Impl.finish, .cancel = Impl.cancel, .destroy = Impl.destroy },
        .args = args,
    };
    try self.jobs.append(self.gpa, &impl.header);
    impl.future = io.concurrent(Impl.run, .{impl}) catch io.async(Impl.run, .{impl});
    return .{ .ptr = &impl.header };
}

fn forgetJob(self: *Scheduler, job: *JobHeader) void {
    for (self.jobs.items, 0..) |pending, i| {
        if (pending == job) {
            _ = self.jobs.swapRemove(i);
            break;
        }
    }
    job.destroy(job, self.gpa);
}

fn JobImpl(comptime function: anytype) type {
    const F = @TypeOf(function);
    const Result = @typeInfo(F).@"fn".return_type.?;
    return struct {
        header: JobHeader,
        args: std.meta.ArgsTuple(F),
        result: Result = undefined,
        future: std.Io.Future(void) = undefined,

        const Self = @This();

        fn run(self: *Self) void {
            self.result = @call(.auto, function, self.args);
            self.header.done.store(true, .release);
        }

        fn finish(header: *JobHeader, L: *api.lua_State) c_int {
            const self: *Self = @alignCast(@fieldParentPtr("header", header));
            self.future.await(header.io);
            if (@typeInfo(Result) == .error_union) {
                const value = self.result catch |err| {
                    if (!api.checkStack(L, 2)) return 0;
                    api.pushNil(L);
                    api.pushString(L, @errorName(err));
                    return 2;
                };
                return pushValue(L, value);
            }
            return pushValue(L, self.result);
        }

        /// Pushes the result onto the task's stack, which only has Lua's
        /// minimum of free slots. Without room the task gets no values.
        fn pushValue(L: *api.lua_State, value: anytype) c_int {
            const V = @TypeOf(value);
            if (comptime @typeInfo(V) == .@"struct" and @hasDecl(V, "zilua_owned")) {
                if (!api.checkStack(L, convert.resultCount(@TypeOf(value.value)) + 2)) {
                    convert.free(value.gpa, value.value);
                    return 0;
                }
                const n = convert.pushMulti(L, value.value);
                convert.free(value.gpa, value.value);
                return n;
            }
            if (!api.checkStack(L, convert.resultCount(V) + 2)) return 0;
            return convert.pushMulti(L, value);
        }

        fn cancel(header: *JobHeader) void {
            const self: *Self = @alignCast(@fieldParentPtr("header", header));
            self.future.cancel(header.io);
        }

        fn destroy(header: *JobHeader, gpa: std.mem.Allocator) void {
            const self: *Self = @alignCast(@fieldParentPtr("header", header));
            gpa.destroy(self);
        }
    };
}
