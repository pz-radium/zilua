//! Re-runs Lua files when they change on disk: the hot reload loop.
//!
//!     var reloader: zilua.Reloader = .init(lua, gpa, std.Io.Dir.cwd());
//!     defer reloader.deinit();
//!     try reloader.watch(io, "scripts/main.lua"); // runs it once
//!     // every frame, or on a timer:
//!     _ = reloader.poll(io) catch |err| report(err, lua.errorMessage());
//!
//! Running a file again redefines what it defines and leaves every other
//! global alone, so state kept elsewhere survives (`state = state or {}` is
//! the usual idiom). After a successful reload zilua calls the global
//! function named by `hook` with the file's path, if there is one.
//! For modules loaded with `require`, see `State.reloadModule`.

const std = @import("std");
const api = @import("../runtime/api.zig");
const State = @import("State.zig");

const Reloader = @This();

state: State,
gpa: std.mem.Allocator,
/// Paths are relative to this directory.
dir: std.Io.Dir,
files: std.ArrayList(File) = .empty,
/// Global function called after a reload, with the file path. Null: none.
hook: ?[:0]const u8 = "on_reload",

const File = struct {
    path: []u8,
    /// "@path", for error messages and tracebacks.
    chunkname: [:0]u8,
    /// Modification time and size when last loaded.
    mtime: i96,
    size: u64,
};

pub const Error = State.Error || std.Io.Dir.StatFileError || std.Io.Dir.ReadFileAllocError;

pub fn init(state: State, gpa: std.mem.Allocator, dir: std.Io.Dir) Reloader {
    return .{ .state = state, .gpa = gpa, .dir = dir };
}

pub fn deinit(self: *Reloader) void {
    for (self.files.items) |file| {
        self.gpa.free(file.path);
        self.gpa.free(file.chunkname);
    }
    self.files.deinit(self.gpa);
}

/// Runs the file at `path` and watches it. The file stays watched even if
/// this first run fails, so that fixing it reloads it.
pub fn watch(self: *Reloader, io: std.Io, path: []const u8) Error!void {
    {
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        const chunkname = try std.mem.concatWithSentinel(self.gpa, u8, &.{ "@", path }, 0);
        errdefer self.gpa.free(chunkname);
        try self.files.append(self.gpa, .{ .path = owned, .chunkname = chunkname, .mtime = 0, .size = 0 });
    }
    // The list owns both strings now, even if this first run fails.
    try self.load(io, self.files.items.len - 1);
}

/// Reloads the watched files that changed since they were last loaded and
/// returns how many it reloaded. Stops at the first failure: a file that
/// fails to compile defines nothing, so the previous version stays in place.
pub fn poll(self: *Reloader, io: std.Io) Error!usize {
    var reloaded: usize = 0;
    // Indices, not pointers: Lua code may watch more files while it runs.
    for (0..self.files.items.len) |i| {
        const file = self.files.items[i];
        const stat = try self.dir.statFile(io, file.path, .{});
        if (stat.mtime.nanoseconds == file.mtime and stat.size == file.size) continue;
        try self.load(io, i);
        reloaded += 1;
        try self.callHook(self.files.items[i].path);
    }
    return reloaded;
}

/// Runs every watched file again, changed or not.
pub fn reloadAll(self: *Reloader, io: std.Io) Error!void {
    for (0..self.files.items.len) |i| {
        try self.load(io, i);
        try self.callHook(self.files.items[i].path);
    }
}

fn load(self: *Reloader, io: std.Io, index: usize) Error!void {
    const path = self.files.items[index].path;
    const stat = try self.dir.statFile(io, path, .{});
    // Recorded before running, so a failing version is not retried until
    // the file changes again.
    self.files.items[index].mtime = stat.mtime.nanoseconds;
    self.files.items[index].size = stat.size;
    const source = try self.dir.readFileAlloc(io, path, self.gpa, .unlimited);
    defer self.gpa.free(source);
    try self.state.doStringNamed(source, self.files.items[index].chunkname);
}

fn callHook(self: *Reloader, path: []const u8) State.Error!void {
    const hook = self.hook orelse return;
    const is_function = api.getGlobal(self.state.L, hook.ptr) == .function;
    api.pop(self.state.L, 1);
    if (is_function) try self.state.call(void, hook, .{path});
}
