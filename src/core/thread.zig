//! Lua coroutines driven from Zig.
//!
//!     const co = lua.newThread(func);
//!     defer co.deinit();
//!     switch (try co.run(i64, .{})) {
//!         .yielded => |v| ...,   // coroutine.yield(v), or a bound function returned zilua.yield(...)
//!         .returned => |v| ..., // the function returned v; the coroutine is dead
//!     }

const std = @import("std");
const api = @import("../runtime/api.zig");
const convert = @import("../binding/convert.zig");
const State = @import("State.zig");
const ref = @import("ref.zig");

/// What a coroutine handed back from `Thread.run`.
pub fn RunResult(comptime R: type) type {
    return union(enum) {
        /// The coroutine yielded these values and can be run again.
        yielded: R,
        /// The coroutine's function returned these values and is finished.
        returned: R,
    };
}

/// Returned by a bound Zig function to yield from the coroutine that called
/// it: `return zilua.yield(.{ a, b })`. Create with `yield`.
pub fn Yield(comptime T: type) type {
    return struct {
        values: T,

        pub const zilua_yield = {};
    };
}

/// Yields `values` (one value, or a tuple for several) to whoever resumed
/// the coroutine. When the coroutine is resumed, the values passed to it
/// become the results of the bound function's call.
pub fn yield(values: anytype) Yield(@TypeOf(values)) {
    return .{ .values = values };
}

pub fn isYield(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zilua_yield");
}

/// A handle to a Lua coroutine. Keeps it alive until `deinit`.
pub const Thread = struct {
    /// A handle whose `L` is the coroutine itself.
    state: State,
    ref: ref.Ref,

    pub const Status = enum {
        /// Created but never run.
        ready,
        /// Yielded and waiting to be run again.
        suspended,
        /// Returned or failed.
        dead,
    };

    /// References the coroutine at `idx` of `state`'s stack.
    pub fn fromStack(state: State, idx: c_int) Thread {
        const co = api.toThread(state.L, idx).?;
        return .{ .state = .{ .L = co, .ctx = state.ctx }, .ref = .fromStack(state, idx) };
    }

    pub fn deinit(self: Thread) void {
        self.ref.deinit();
    }

    pub fn push(self: Thread, L: *api.lua_State) void {
        self.ref.push(L);
    }

    /// Meaningful from outside the coroutine only: while it runs (from a
    /// function it called) it reports `ready`.
    pub fn status(self: Thread) Status {
        return switch (api.threadStatus(self.state.L)) {
            .yield => .suspended,
            .ok => if (api.getTop(self.state.L) > 0) .ready else .dead,
            else => .dead,
        };
    }

    /// Starts or resumes the coroutine with the elements of the tuple `args`
    /// and converts what it yields or returns to `R` (as for `State.call`).
    /// Errors raised inside the coroutine kill it and are returned here, with
    /// the message (and a traceback) in `errorMessage()`.
    pub fn run(self: Thread, comptime R: type, args: anytype) State.Error!RunResult(R) {
        comptime convert.ensureOwned(R, "Thread.run");
        const co = self.state.L;
        const needed = comptime convert.resultCount(R);
        if (!api.checkStack(co, convert.resultCount(@TypeOf(args)) + needed + 4)) return error.StackOverflow;

        const nargs = convert.pushMulti(co, args);
        const result = try self.resumeRaw(nargs);

        // Pad missing results with nil so every index read below exists.
        var count = result.nresults;
        while (count < needed) : (count += 1) api.pushNil(co);
        const top = api.getTop(co);
        defer api.setTop(co, top - count);
        const values = try convert.toMulti(R, co, top - count + 1);
        return if (result.status == .yield) .{ .yielded = values } else .{ .returned = values };
    }

    /// Resumes the coroutine with `nargs` values already pushed onto its
    /// stack, and leaves what it yielded or returned there: `nresults`
    /// values on top, for the caller to read and pop. Errors are handled as
    /// in `run`.
    pub fn resumeRaw(self: Thread, nargs: c_int) State.Error!api.ResumeResult {
        const co = self.state.L;
        self.state.enterCall();
        defer self.state.leaveCall();
        self.state.hookThread(co);
        const result = api.resumeThread(co, self.state.ctx.main, nargs);
        return switch (result.status) {
            .ok, .yield => result,
            else => self.state.captureThreadError(co, result.status),
        };
    }

    /// A second, independent handle to the same coroutine.
    pub fn clone(self: Thread) Thread {
        return .{ .state = self.state, .ref = self.ref.clone() };
    }
};
