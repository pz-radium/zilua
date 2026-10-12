//! A Lua state together with the Zig allocator that backs it.
//!
//! `State` is a small handle (two pointers) passed by value. Only the handle
//! returned by `init` may be passed to `deinit`; the handles zilua gives to
//! bound functions refer to the same state (or one of its coroutines).

const std = @import("std");
const builtin = @import("builtin");
const api = @import("../runtime/api.zig");
const convert = @import("../binding/convert.zig");
const usertype = @import("../binding/usertype.zig");
const bind = @import("../binding/bind.zig");
const ref = @import("ref.zig");
const thread = @import("thread.zig");
const Sandbox = @import("Sandbox.zig");

const State = @This();

/// The thread this handle operates on.
L: *api.lua_State,
ctx: *Context,

pub const Error = error{
    /// A Lua runtime error. The message is in `errorMessage()`.
    Runtime,
    /// A syntax error while compiling a chunk.
    Syntax,
    OutOfMemory,
    /// An error while running the message handler.
    MessageHandler,
    /// An error in a `__gc` metamethod (Lua 5.2 and 5.3).
    GcMetamethod,
    /// A file could not be opened or read.
    File,
    /// The Lua stack cannot grow enough for the arguments.
    StackOverflow,
} || convert.Error;

pub const Options = struct {
    /// Open the standard libraries.
    open_libs: bool = true,
    /// Append a stack traceback to the messages of failed calls.
    traceback: bool = true,
};

/// Per-state data shared by every handle to the state.
pub const Context = struct {
    allocator: std.mem.Allocator,
    main: *api.lua_State,
    traceback: bool,
    /// Copy of the message of the last failed call, owned by `allocator`.
    err_buf: ?[]u8 = null,
    err_len: usize = 0,
    /// Bytes currently allocated by Lua, and the cap set by `setMemoryLimit`.
    memory_used: usize = 0,
    memory_limit: ?usize = null,
    /// Instructions run since the outermost call from Zig started, and the
    /// cap set by `setInstructionLimit`.
    instructions: u64 = 0,
    instruction_limit: ?u64 = null,
    /// Nesting of calls from Zig into Lua (see `enterCall`).
    depth: u32 = 0,
    /// The coroutine a `Thread.resumeRaw` is running, so that a resume made
    /// from inside it can tell the runtime where it comes from.
    running: ?*api.lua_State = null,
    /// The limit was exceeded and the hook now fires on every instruction.
    limit_tripped: bool = false,
    /// The budgets of the innermost call running under limits (a sandbox
    /// call, a limited `Scheduler` task), which the tasks it spawns inherit.
    active_limits: ?Sandbox.Limits = null,
    /// Given to bound functions that take a `std.Io` parameter.
    io: ?std.Io = null,
    /// References to release at the next call from Zig: Luau finalizers run
    /// during collection, when the Lua API is off limits.
    pending_unrefs: std.ArrayList(c_int) = .empty,
    /// The state was not created by `init` (a Lua C module's host): no
    /// allocator accounting, so no memory or instruction limits.
    foreign: bool = false,

    pub fn setErrorMessage(ctx: *Context, msg: []const u8) void {
        ctx.err_len = 0;
        if (ctx.err_buf == null or ctx.err_buf.?.len < msg.len) {
            if (ctx.err_buf) |old| ctx.allocator.free(old);
            // Out of memory just means no message.
            ctx.err_buf = ctx.allocator.alloc(u8, msg.len) catch null;
        }
        const buf = ctx.err_buf orelse return;
        @memcpy(buf[0..msg.len], msg);
        ctx.err_len = msg.len;
    }
};

/// Its address is the registry key under which the `Context` is stored.
var context_key: u8 = 0;

/// Creates a Lua state that allocates all its memory through `gpa`.
pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!State {
    const ctx = try gpa.create(Context);
    errdefer gpa.destroy(ctx);
    ctx.* = .{ .allocator = gpa, .main = undefined, .traceback = options.traceback };

    const L = api.newState(luaAlloc, ctx) orelse return error.OutOfMemory;
    ctx.main = L;
    api.atPanic(L, panicHandler);

    api.pushLightUserdata(L, ctx);
    api.rawSetP(L, api.registry_index, &context_key);
    api.initProtected(L);
    initMessageHandler(L);

    if (builtin.optimize == .debug) verifyAbi(L);
    if (options.open_libs) api.openLibs(L);
    return .{ .L = L, .ctx = ctx };
}

/// Closes the state, running pending finalizers, and frees all its memory.
pub fn deinit(self: State) void {
    const ctx = self.ctx;
    api.close(ctx.main);
    freeContext(ctx);
}

fn freeContext(ctx: *Context) void {
    if (ctx.err_buf) |buf| ctx.allocator.free(buf);
    ctx.pending_unrefs.deinit(ctx.allocator);
    ctx.allocator.destroy(ctx);
}

/// The handle for a `lua_State` (or one of its threads). States not created
/// by `init`, such as the host of a Lua C module built with zilua, get a
/// context on first use, allocated with the C allocator and freed when the
/// state closes.
pub fn fromLua(L: *api.lua_State) State {
    _ = api.rawGetP(L, api.registry_index, &context_key);
    const ptr = api.toUserdata(L, -1);
    api.pop(L, 1);
    const ctx: *Context = if (ptr) |p| @ptrCast(@alignCast(p)) else attachForeign(L);
    return .{ .L = L, .ctx = ctx };
}

var foreign_anchor_key: u8 = 0;
var foreign_main_key: u8 = 0;

fn attachForeign(L: *api.lua_State) *Context {
    const gpa = std.heap.c_allocator;
    const ctx = gpa.create(Context) catch @panic("zilua: out of memory");
    const main = api.mainThread(L);
    ctx.* = .{ .allocator = gpa, .main = main, .traceback = true, .foreign = true };
    if (main == L) {
        // Lua 5.1 and LuaJIT cannot name the main thread, so `L` may be a
        // coroutine: keep it alive for as long as the context uses it.
        _ = api.pushThread(L);
        api.rawSetP(L, api.registry_index, &foreign_main_key);
    }

    // A userdata anchored in the registry frees the context when the state
    // closes (Luau calls a destructor instead of __gc).
    const size = @sizeOf(*Context);
    const raw = if (comptime api.has_userdata_dtor) api.newUserdataDtor(L, size, foreignDtor) else api.newUserdata(L, size);
    const slot: **Context = @ptrCast(@alignCast(raw));
    slot.* = ctx;
    if (comptime !api.has_userdata_dtor) {
        api.createTable(L, 0, 1);
        api.pushCFunction(L, foreignGc);
        api.setField(L, -2, "__gc");
        api.setMetatable(L, -2);
    }
    api.rawSetP(L, api.registry_index, &foreign_anchor_key);

    api.pushLightUserdata(L, ctx);
    api.rawSetP(L, api.registry_index, &context_key);
    api.initProtected(L);
    initMessageHandler(L);
    return ctx;
}

fn foreignGc(L_: ?*api.lua_State) callconv(.c) c_int {
    const slot: **Context = @ptrCast(@alignCast(api.toUserdata(L_.?, 1).?));
    freeContext(slot.*);
    return 0;
}

fn foreignDtor(L: ?*api.lua_State, userdata: ?*anyopaque) callconv(.c) void {
    _ = L;
    const slot: **Context = @ptrCast(@alignCast(userdata.?));
    freeContext(slot.*);
}

/// Makes `io` available to bound functions that take a `std.Io` parameter.
pub fn setIo(self: State, new_io: std.Io) void {
    self.ctx.io = new_io;
}

pub fn io(self: State) ?std.Io {
    return self.ctx.io;
}

/// Releases reference `id` at the next call from Zig into Lua. For
/// finalizers that run when the Lua API cannot be used.
pub fn deferUnref(self: State, id: c_int) void {
    self.ctx.pending_unrefs.append(self.ctx.allocator, id) catch {}; // a leak, not a crash
}

/// A handle to the main thread of this state.
pub fn mainThread(self: State) State {
    return .{ .L = self.ctx.main, .ctx = self.ctx };
}

pub fn allocator(self: State) std.mem.Allocator {
    return self.ctx.allocator;
}

/// A stretch of work zilua does for the host outside any protected call:
/// pushing arguments, reading results, taking references. Lua turns a failed
/// allocation into an error, which outside protected mode panics, so the
/// memory limit a script may have filled up must not apply here. The
/// script's own code always runs with the limit back in place.
///
/// End it with `end`, or with `defer`: the only error that can still be
/// raised in between is a real out-of-memory, which ends the process anyway.
pub const HostWork = struct {
    ctx: *Context,
    memory_limit: ?usize,

    pub fn end(self: HostWork) void {
        self.ctx.memory_limit = self.memory_limit;
    }
};

pub fn beginHostWork(self: State) HostWork {
    const work: HostWork = .{ .ctx = self.ctx, .memory_limit = self.ctx.memory_limit };
    self.ctx.memory_limit = null;
    return work;
}

pub fn openLibs(self: State) void {
    api.openLibs(self.L);
}

// ---------------------------------------------------------------------------
// Running code

/// Compiles and runs `source`. On error the message is in `errorMessage()`.
pub fn doString(self: State, source: []const u8) Error!void {
    return self.doStringNamed(source, "=(load)");
}

/// Like `doString`, with the chunk name used in error messages and
/// tracebacks ("=name" for a literal name, "@path" for a file name).
pub fn doStringNamed(self: State, source: []const u8, chunkname: [:0]const u8) Error!void {
    const status = api.loadBuffer(self.L, source, chunkname.ptr, .text);
    if (status != .ok) return self.captureError(status);
    try self.pcallTop(0, 0);
}

pub fn doFile(self: State, path: [:0]const u8) Error!void {
    const status = api.loadFile(self.L, path.ptr, .text);
    if (status != .ok) return self.captureError(status);
    try self.pcallTop(0, 0);
}

/// Compiles `source` without running it.
pub fn loadString(self: State, source: []const u8, chunkname: [:0]const u8) Error!ref.Function {
    const status = api.loadBuffer(self.L, source, chunkname.ptr, .text);
    if (status != .ok) return self.captureError(status);
    const work = self.beginHostWork();
    defer work.end();
    defer api.pop(self.L, 1);
    return ref.Function.fromStack(self, -1);
}

/// Calls the global function `name` with the elements of the tuple `args`
/// and converts its results to `R` (`void`, one value, or a tuple for
/// several results).
pub fn call(self: State, comptime R: type, name: [:0]const u8, args: anytype) Error!R {
    const nargs = try self.prepareCall(R, args, Global{ .name = name });
    return self.callStack(R, nargs);
}

/// Pushes the function `callee` names and then `args`, with room reserved
/// for a call returning an `R` and the memory limit lifted: zilua's own work
/// for the host, outside any protected call (see `beginHostWork`). Returns
/// the number of arguments, for `callStack`.
///
/// `callee` is anything with a `push(L)` method: a `Global`, a `Function`
/// handle, a `Sandbox`'s member.
pub fn prepareCall(self: State, comptime R: type, args: anytype, callee: anytype) Error!c_int {
    const work = self.beginHostWork();
    defer work.end();
    try self.reserveCall(@TypeOf(args), R);
    callee.push(self.L);
    return convert.pushMulti(self.L, args);
}

/// A global function, as a `prepareCall` target.
pub const Global = struct {
    name: [:0]const u8,

    pub fn push(self: Global, L: *api.lua_State) void {
        _ = api.getGlobal(L, self.name.ptr);
    }
};

/// Makes sure the stack has room for a call with arguments `Args` and
/// results `R`. Outside of C functions Lua only guarantees 20 free slots.
pub fn reserveCall(self: State, comptime Args: type, comptime R: type) Error!void {
    const needed = comptime convert.resultCount(Args) + convert.resultCount(R) + 4;
    if (!api.checkStack(self.L, needed)) return error.StackOverflow;
}

/// Like `call`, with results read by `toAlloc`: strings and slices are
/// copied with `gpa`, so `R` may contain them. Free with `zilua.free`.
pub fn callAlloc(self: State, gpa: std.mem.Allocator, comptime R: type, name: [:0]const u8, args: anytype) Error!R {
    const nargs = try self.prepareCall(R, args, Global{ .name = name });
    return self.callStackAlloc(gpa, R, nargs);
}

pub fn callStackAlloc(self: State, gpa: std.mem.Allocator, comptime R: type, nargs: c_int) Error!R {
    return self.finishCall(gpa, R, nargs);
}

/// Calls the function pushed below `nargs` pushed arguments.
pub fn callStack(self: State, comptime R: type, nargs: c_int) Error!R {
    comptime convert.ensureOwned(R, "call");
    return self.finishCall(null, R, nargs);
}

/// Runs the prepared call and reads its results, which `gpa` makes owned.
fn finishCall(self: State, gpa: ?std.mem.Allocator, comptime R: type, nargs: c_int) Error!R {
    const base = api.getTop(self.L) - nargs - 1;
    try self.pcallTop(nargs, comptime convert.resultCount(R));
    defer api.setTop(self.L, base);
    // Reading the results is zilua's own work (see `beginHostWork`).
    const work = self.beginHostWork();
    defer work.end();
    return convert.readMulti(R, gpa, self.L, base + 1);
}

/// Calls the function below the top `nargs` values in protected mode. On
/// failure the function and arguments are popped and the message is saved.
fn pcallTop(self: State, nargs: c_int, nresults: c_int) Error!void {
    self.enterCall();
    defer self.leaveCall();
    const L = self.L;
    var msgh: c_int = 0;
    if (self.ctx.traceback) {
        msgh = api.getTop(L) - nargs;
        pushMessageHandler(L);
        api.insert(L, msgh);
    }
    const status = api.pcall(L, nargs, nresults, msgh);
    if (msgh != 0) api.remove(L, msgh);
    if (status != .ok) return self.captureError(status);
    if (comptime api.lang == .luau) {
        // Luau makes a call from a C function that has a continuation (a
        // bound function returning `CallThen`) yieldable, so this one may
        // have yielded rather than returned: there are no results to read.
        if (api.threadStatus(L) == .yield) {
            self.ctx.setErrorMessage("a Lua function yielded across a call from Zig");
            return error.Runtime;
        }
    }
}

/// Pops the error value on top of the stack, saves it as `errorMessage()`
/// and returns the matching error.
fn captureError(self: State, status: api.Status) Error {
    const L = self.L;
    // This runs outside protected mode, where an error would panic. The one
    // allocation it can make (turning a number into a string) must not fail
    // on a memory limit the script has just run into; nothing is restored by
    // defer, as a Lua error would skip it (only a real out-of-memory can
    // raise here).
    const limit = self.ctx.memory_limit;
    if (limit) |l| self.ctx.memory_limit = l +| error_headroom;
    var buf: [error_message_size]u8 = undefined;
    self.ctx.setErrorMessage(errorText(L, &buf));
    api.pop(L, 1);
    self.ctx.memory_limit = limit;
    return statusError(status);
}

/// The error object on top of `L` as text. Calling its `__tostring` would
/// run Lua code outside protected mode, so a value that is not a string
/// (or a number, which Lua converts) is only described. With `traceback` on
/// the message handler has already run `__tostring` for us.
fn errorText(L: *api.lua_State, buf: []u8) [:0]const u8 {
    return switch (api.typeOf(L, -1)) {
        .string, .number => std.mem.span(api.toCString(L, -1).?),
        else => std.fmt.bufPrintSentinel(buf, "(error object is a {s} value)", .{
            std.mem.span(api.typeName(L, -1)),
        }, 0) catch "(error object)",
    };
}

fn statusError(status: api.Status) Error {
    return switch (status) {
        .ok, .yield, .runtime => error.Runtime,
        .syntax => error.Syntax,
        .memory => error.OutOfMemory,
        .message_handler => error.MessageHandler,
        .gc_metamethod => error.GcMetamethod,
        .file => error.File,
    };
}

/// Like `captureError` for a coroutine that died with an error: the error
/// value is on top of `co`, and the message gets a traceback of `co`.
pub fn captureThreadError(self: State, co: *api.lua_State, status: api.Status) Error {
    const main = self.ctx.main;
    // Unprotected from here on: see `captureError`. The limit is raised by a
    // fixed amount rather than lifted: a coroutine that died of a stack
    // overflow has thousands of frames to report, and Luau's traceback shows
    // them all, so building it must not be able to use up all memory.
    const limit = self.ctx.memory_limit;
    if (limit) |l| self.ctx.memory_limit = l +| error_headroom;
    var buf: [error_message_size]u8 = undefined;
    const message = errorText(co, &buf);
    // The traceback allocates, so it runs protected: without it the plain
    // message is still reported.
    if (self.ctx.traceback and api.tracebackProtected(main, co, message.ptr, 0)) {
        self.ctx.setErrorMessage(api.toLString(main, -1).?);
        api.pop(main, 1);
    } else {
        self.ctx.setErrorMessage(message);
    }
    // The coroutine is dead; drop what is left on its stack. `Thread`
    // refuses to resume one that is executing, so this is for a host driving
    // coroutines itself: clearing a live frame's stack would unroot the
    // values it is working with.
    if (!api.isRunning(co)) api.setTop(co, 0);
    self.ctx.memory_limit = limit;
    return statusError(status);
}

/// How much memory building an error message may use on top of a limit the
/// script has run into.
const error_headroom = 1 << 20;

/// Room for describing an error object zilua cannot turn into text itself.
const error_message_size = 128;

/// Bookkeeping for calls from Zig into Lua. The instruction limit counts
/// from the start of the outermost one.
pub fn enterCall(self: State) void {
    if (self.ctx.depth == 0) {
        self.ctx.instructions = 0;
        if (self.ctx.pending_unrefs.items.len > 0) {
            var pending = self.ctx.pending_unrefs;
            self.ctx.pending_unrefs = .empty;
            for (pending.items) |id| api.unref(self.ctx.main, api.registry_index, id);
            pending.deinit(self.ctx.allocator);
        }
        if (self.ctx.limit_tripped) {
            self.ctx.limit_tripped = false;
            self.setStepHooks(true);
        }
    }
    self.ctx.depth += 1;
}

/// Installs or removes the step hook on the threads zilua runs code on: the
/// main one, and this handle's own if it is a coroutine. PUC Lua hooks
/// belong to each thread, so a coroutine running a call from Zig (a bound
/// function that took a `State`, a `Scheduler` task) needs its own.
fn setStepHooks(self: State, enabled: bool) void {
    self.installStepHook(self.ctx.main, enabled);
    if (self.L != self.ctx.main) self.installStepHook(self.L, enabled);
}

fn installStepHook(self: State, L: *api.lua_State, enabled: bool) void {
    api.setStepHook(L, if (enabled) &stepHook else null);
    if (enabled) api.setStepInterval(L, self.stepInterval());
}

pub fn leaveCall(self: State) void {
    self.ctx.depth -= 1;
}

/// Message of the last failed `doString`, `call`, ... Valid until the next failure.
pub fn errorMessage(self: State) []const u8 {
    const buf = self.ctx.err_buf orelse return "";
    return buf[0..self.ctx.err_len];
}

/// For bound functions: pushes `message` and returns `error.LuaError`,
/// which zilua raises as a Lua error once the function has returned.
///
///     if (hp < 0) return lua.fail("hp must not be negative");
pub fn fail(self: State, message: []const u8) error{LuaError} {
    api.pushString(self.L, message);
    return error.LuaError;
}

// ---------------------------------------------------------------------------
// Globals and types

/// Sets global `name` to `value`, converted with the rules in README.md.
/// Functions are wrapped automatically: `lua.setGlobal("add", add)`.
pub fn setGlobal(self: State, name: [:0]const u8, value: anytype) void {
    const work = self.beginHostWork();
    defer work.end();
    if (@typeInfo(@TypeOf(value)) == .@"fn") {
        // Named, so that Luau's error messages can mention the function.
        bind.push(self.L, value, name.ptr);
    } else {
        convert.push(self.L, value);
    }
    api.setGlobal(self.L, name.ptr);
}

/// Reads global `name` as a `T` that owns its memory: strings and slices
/// (also inside structs, arrays and unions) are copied with `gpa`, and
/// structs with string fields can be read from tables. Release the result
/// with `zilua.free(gpa, value)`.
pub fn getGlobalAlloc(self: State, gpa: std.mem.Allocator, comptime T: type, name: [:0]const u8) Error!T {
    return self.readGlobal(gpa, T, name);
}

/// Reads global `name` as a `T`.
pub fn getGlobal(self: State, comptime T: type, name: [:0]const u8) Error!T {
    comptime convert.ensureOwned(T, "getGlobal");
    return self.readGlobal(null, T, name);
}

fn readGlobal(self: State, gpa: ?std.mem.Allocator, comptime T: type, name: [:0]const u8) Error!T {
    const work = self.beginHostWork();
    defer work.end();
    _ = api.getGlobal(self.L, name.ptr);
    defer api.pop(self.L, 1);
    return convert.readAt(T, gpa, self.L, -1, 0);
}

/// Exposes the public functions of `T` as global table `displayName(T)`
/// (e.g. `Vec2.init(1, 2)` in Lua). Values of `T` work in Lua without this;
/// it is only needed to call `T`'s functions from Lua by name.
pub fn registerType(self: State, comptime T: type) void {
    usertype.register(self.L, T, usertype.displayName(T).ptr);
}

/// Detaches Lua from a Zig object that was pushed by pointer: every
/// reference Lua holds to `ptr.*`, or to struct fields inside it, stops
/// working, and scripts that use one get "T no longer exists". Call it
/// before freeing or moving an object whose pointer Lua may have kept:
///
///     const player = try gpa.create(Player);
///     lua.setGlobal("player", player);
///     ...
///     lua.invalidate(player);
///     gpa.destroy(player);
///
/// References handed out afterwards are new and live again, so invalidate
/// after the last push. One exception: a reference that only a finalizer
/// still holds (a `__gc` metamethod that captured it) may have been dropped
/// from zilua's lookup by then, and would not be found.
pub fn invalidate(self: State, ptr: anytype) void {
    const P = @typeInfo(@TypeOf(ptr));
    if (comptime P != .pointer or P.pointer.size != .one or !convert.isUsertype(P.pointer.child)) {
        @compileError("zilua: invalidate takes a pointer to a struct pushed to Lua, got " ++ @typeName(@TypeOf(ptr)));
    }
    usertype.invalidate(self.L, P.pointer.child, ptr);
}

pub fn globals(self: State) ref.Table {
    api.pushGlobalTable(self.L);
    defer api.pop(self.L, 1);
    return ref.Table.fromStack(self, -1);
}

pub fn createTable(self: State) ref.Table {
    api.newTable(self.L);
    defer api.pop(self.L, 1);
    return ref.Table.fromStack(self, -1);
}

// ---------------------------------------------------------------------------
// Stack access

pub fn push(self: State, value: anytype) void {
    convert.push(self.L, value);
}

/// Reads the value at `idx`. Slices and pointers point into Lua memory and
/// are valid while the value stays on the stack.
pub fn to(self: State, comptime T: type, idx: c_int) convert.Error!T {
    return convert.to(T, self.L, idx);
}

pub fn pop(self: State, n: c_int) void {
    api.pop(self.L, n);
}

pub fn getTop(self: State) c_int {
    return api.getTop(self.L);
}

// ---------------------------------------------------------------------------
// Garbage collector

pub fn collectGarbage(self: State) void {
    api.gcCollect(self.L);
}

/// Bytes currently allocated by Lua, as counted by zilua's allocator.
pub fn memoryUsed(self: State) usize {
    return self.ctx.memory_used;
}

// ---------------------------------------------------------------------------
// Coroutines

/// A new coroutine that will run `func` when first run. See `Thread`.
pub fn newThread(self: State, func: ref.Function) thread.Thread {
    const work = self.beginHostWork();
    defer work.end();
    const co = api.newThread(self.L);
    const t = thread.Thread.fromStack(self, -1);
    api.pop(self.L, 1);
    func.push(co);
    return t;
}

// ---------------------------------------------------------------------------
// Limits and sandboxing

/// Makes allocations fail once Lua would hold more than `limit` bytes (null:
/// no limit). Lua turns them into "not enough memory" errors, which scripts
/// can catch with pcall and zilua calls return as `error.OutOfMemory`.
///
/// The limit covers what Lua allocates for scripts, not what zilua allocates
/// to call them: pushing arguments and reading results happen with the limit
/// lifted (see `beginHostWork`), since Lua would turn a failure there into an
/// error raised outside any protected call.
pub fn setMemoryLimit(self: State, limit: ?usize) void {
    if (self.ctx.foreign) @panic("zilua: memory limits need a state created by State.init");
    self.ctx.memory_limit = limit;
}

/// Stops Lua code that runs more than about `limit` VM instructions within
/// one call from Zig (`doString`, `call`, `Function.call`, `Thread.run`, ...)
/// with an "instruction limit exceeded" error; null removes the limit.
/// Scripts cannot catch their way past it: the error repeats until control
/// returns to Zig.
///
/// The limit is a debug hook, so code that can reach `debug.sethook` can
/// remove it. Scripts that are not trusted belong in a `Sandbox`, whose
/// environment has no debug library.
///
/// Precision differs by runtime: PUC Lua and LuaJIT count in steps of 1000
/// instructions, Luau counts safepoints (loop iterations, calls, returns).
/// LuaJIT's JIT compiler is off while a limit is set, since compiled code
/// does not run hooks. Set the limit before creating coroutines.
pub fn setInstructionLimit(self: State, limit: ?u64) void {
    if (self.ctx.foreign) @panic("zilua: instruction limits need a state created by State.init");
    self.ctx.instruction_limit = limit;
    self.ctx.instructions = 0;
    self.ctx.limit_tripped = false;
    self.setStepHooks(limit != null);
}

fn stepHook(L: *api.lua_State) void {
    const ctx: *Context = @ptrCast(@alignCast(api.allocUserdata(L).?));
    ctx.instructions += api.step_instructions;
    const limit = ctx.instruction_limit orelse return;
    if (ctx.instructions <= limit) return;
    // From now on raise at every instruction, so that a pcall that catches
    // the error cannot keep a loop going: the next instruction after it
    // raises again, all the way out to Zig. PUC Lua hooks belong to each
    // thread, so this has to be set on every thread that runs over the
    // limit, not only on the first one to reach it.
    ctx.limit_tripped = true;
    api.setStepInterval(L, 1);
    // Raised from a hook with no Zig defer pending.
    _ = api.raiseF(L, "instruction limit exceeded");
}

/// An environment for untrusted scripts. See `Sandbox`.
pub fn newSandbox(self: State, options: Sandbox.Options) Error!Sandbox {
    return Sandbox.init(self, options);
}

/// Luau only: makes the global table and the standard libraries read-only
/// (`luaL_sandbox`), Luau's own protection for a shared environment, which
/// also turns on its fast paths for builtins. Call it after defining your
/// globals.
pub fn freezeGlobals(self: State) error{Unsupported}!void {
    if (comptime api.lang != .luau) return error.Unsupported;
    api.luauSandbox(self.L);
}

pub const SavedLimits = struct {
    memory: ?usize,
    instructions: ?u64,
    set_instructions: bool,
    active: ?Sandbox.Limits,
};

/// The budgets of the innermost call running under limits (see
/// `applyLimits`), or null outside of one.
pub fn activeLimits(self: State) ?Sandbox.Limits {
    return self.ctx.active_limits;
}

/// Makes the instruction limit, if there is one, count in coroutine `co`.
/// Coroutines only copy their creator's hook when created, so one made
/// before the limit was set would otherwise run unchecked.
pub fn hookThread(self: State, co: *api.lua_State) void {
    if (self.ctx.instruction_limit == null) return;
    api.hookThread(co, self.stepInterval());
}

/// How often the step hook should fire: at every instruction once a limit
/// has been exceeded, so that catching the error cannot buy more time.
fn stepInterval(self: State) c_int {
    return if (self.ctx.limit_tripped) 1 else @intCast(api.step_instructions);
}

/// Tightens the limits for one call (see `Sandbox`): at most `memory_budget`
/// more bytes and `instruction_budget` instructions. Undo with
/// `restoreLimits`.
pub fn applyLimits(self: State, memory_budget: ?usize, instruction_budget: ?u64) SavedLimits {
    const ctx = self.ctx;
    if (ctx.foreign and (memory_budget != null or instruction_budget != null)) {
        @panic("zilua: limits need a state created by State.init");
    }
    const saved: SavedLimits = .{
        .memory = ctx.memory_limit,
        .instructions = ctx.instruction_limit,
        .set_instructions = instruction_budget != null,
        .active = ctx.active_limits,
    };
    if (memory_budget != null or instruction_budget != null) {
        ctx.active_limits = .{ .memory = memory_budget, .instructions = instruction_budget };
    }
    if (memory_budget) |budget| ctx.memory_limit = tighter(usize, ctx.memory_limit, ctx.memory_used +| budget);
    if (instruction_budget) |budget| {
        // The count starts over with the outermost call from Zig.
        const start = if (ctx.depth == 0) 0 else ctx.instructions;
        ctx.instruction_limit = tighter(u64, ctx.instruction_limit, start +| budget);
        self.setStepHooks(true);
    }
    return saved;
}

pub fn restoreLimits(self: State, saved: SavedLimits) void {
    const ctx = self.ctx;
    ctx.memory_limit = saved.memory;
    ctx.active_limits = saved.active;
    if (saved.set_instructions) {
        ctx.instruction_limit = saved.instructions;
        ctx.limit_tripped = false;
        // Re-armed even when the outer limit stays: the inner one may have
        // been exceeded, which leaves the hook firing at every instruction,
        // and the outer one gets its own pace back (and trips again if it is
        // exceeded too).
        self.setStepHooks(saved.instructions != null);
    }
}

fn tighter(comptime T: type, current: ?T, new: T) T {
    return if (current) |c| @min(c, new) else new;
}

/// Compiles `source` (text only) and runs it with `env` as its global
/// environment.
pub fn doStringIn(self: State, env: ref.Table, source: []const u8) Error!void {
    return self.doStringInNamed(env, source, "=(load)");
}

pub fn doStringInNamed(self: State, env: ref.Table, source: []const u8, chunkname: [:0]const u8) Error!void {
    const status = api.loadBuffer(self.L, source, chunkname.ptr, .text);
    if (status != .ok) return self.captureError(status);
    env.push(self.L);
    api.setFunctionEnv(self.L, -2);
    try self.pcallTop(0, 0);
}

/// Compiles `source` with `env` as its global environment, without running it.
pub fn loadStringIn(self: State, env: ref.Table, source: []const u8, chunkname: [:0]const u8) Error!ref.Function {
    const status = api.loadBuffer(self.L, source, chunkname.ptr, .text);
    if (status != .ok) return self.captureError(status);
    env.push(self.L);
    api.setFunctionEnv(self.L, -2);
    defer api.pop(self.L, 1);
    return ref.Function.fromStack(self, -1);
}

// ---------------------------------------------------------------------------
// Hot reload

/// Loads module `name` again with `require` and copies its new fields into
/// the table that was loaded before, so code holding the old table sees the
/// new functions. On failure the old version stays loaded. Needs `require`,
/// so not available on Luau. See `Reloader` for plain script files.
pub fn reloadModule(self: State, name: [:0]const u8) Error!void {
    return self.runChunk(void, "=zilua.reload_module", @embedFile("reload_module.lua"), .{name});
}

/// Runs one of the Lua chunks embedded in zilua with `args`.
pub fn runChunk(self: State, comptime R: type, comptime name: [:0]const u8, comptime source: []const u8, args: anytype) Error!R {
    try self.reserveCall(@TypeOf(args), R);
    const status = api.loadBuffer(self.L, source, name.ptr, .text);
    if (status != .ok) return self.captureError(status);
    const nargs = convert.pushMulti(self.L, args);
    return self.callStack(R, nargs);
}

// ---------------------------------------------------------------------------
// Callbacks

/// Lua allocation function backed by the `std.mem.Allocator` of the context.
fn luaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const ctx: *Context = @ptrCast(@alignCast(ud.?));
    const gpa = ctx.allocator;
    // Lua expects malloc-like alignment for every block.
    const alignment: std.mem.Alignment = .@"16";
    const ret_addr = @returnAddress();

    // When ptr is null, osize encodes the kind of object, not a size.
    const old_size = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        if (ptr) |p| gpa.rawFree(@as([*]u8, @ptrCast(p))[0..osize], alignment, ret_addr);
        ctx.memory_used -= old_size;
        return null;
    }
    if (nsize > old_size) {
        if (ctx.memory_limit) |limit| {
            // Written so that nothing overflows, whatever size Lua asks for
            // (close to 4 GiB is possible on 32-bit targets).
            const grow = nsize - old_size;
            if (ctx.memory_used > limit or grow > limit - ctx.memory_used) return null;
        }
    }
    const new = reallocate(gpa, ptr, old_size, nsize, alignment, ret_addr) orelse return null;
    ctx.memory_used = ctx.memory_used - old_size + nsize;
    return @ptrCast(new);
}

fn reallocate(gpa: std.mem.Allocator, ptr: ?*anyopaque, old_size: usize, nsize: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const p = ptr orelse return gpa.rawAlloc(nsize, alignment, ret_addr);
    const old = @as([*]u8, @ptrCast(p))[0..old_size];
    if (gpa.rawRemap(old, alignment, nsize, ret_addr)) |new| return new;
    const new = gpa.rawAlloc(nsize, alignment, ret_addr) orelse return null;
    const keep = @min(old_size, nsize);
    @memcpy(new[0..keep], old[0..keep]);
    gpa.rawFree(old, alignment, ret_addr);
    return new;
}

fn panicHandler(L_: ?*api.lua_State) callconv(.c) c_int {
    const msg = api.toLString(L_.?, -1) orelse "(error object is not a string)";
    std.debug.panic("zilua: unprotected Lua error: {s}", .{msg});
}

/// Its address is the registry key of the cached message handler.
var message_handler_key: u8 = 0;

/// Creates the closure `pushMessageHandler` hands out. On 5.1, LuaJIT and
/// Luau a C closure is allocated, which must not happen just before a
/// protected call: a script that has filled the memory limit would make it
/// raise with nothing to catch the error.
fn initMessageHandler(L: *api.lua_State) void {
    api.pushCFunction(L, messageHandler);
    api.rawSetP(L, api.registry_index, &message_handler_key);
}

fn pushMessageHandler(L: *api.lua_State) void {
    if (api.rawGetP(L, api.registry_index, &message_handler_key) == .function) return;
    api.pop(L, 1);
    api.pushCFunction(L, messageHandler);
}

/// Message handler for protected calls: turns the error into a string and
/// appends a traceback.
fn messageHandler(L_: ?*api.lua_State) callconv(.c) c_int {
    const L = L_.?;
    const msg: [*:0]const u8 = switch (api.typeOf(L, 1)) {
        .string, .number => api.toCString(L, 1).?,
        else => api.pushFString(L, "(error object is a %s value)", api.typeName(L, 1)),
    };
    api.traceback(L, L, msg, 1);
    return 1;
}

fn checkVersionFn(L_: ?*api.lua_State) callconv(.c) c_int {
    api.checkVersion(L_.?);
    return 0;
}

/// Catches a runtime built with numeric types that differ from `c.zig`.
fn verifyAbi(L: *api.lua_State) void {
    api.pushCFunction(L, checkVersionFn);
    if (api.pcall(L, 0, 0, 0) != .ok) {
        const msg = api.toLString(L, -1) orelse "?";
        std.debug.panic("zilua: the linked Lua runtime does not match -Dlang={s}: {s}", .{ @tagName(api.lang), msg });
    }
}
