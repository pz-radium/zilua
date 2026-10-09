# zilua

[![CI](https://github.com/pz-radium/zilua/actions/workflows/ci.yml/badge.svg)](https://github.com/pz-radium/zilua/actions/workflows/ci.yml)

Zig ↔ Lua bindings generated at comptime. Give zilua a Zig function or
struct and it builds the Lua side from the type information: no binding code
to write, no generator to run. The same API works on Lua 5.1 to 5.5, LuaJIT
and Luau; the runtime is chosen at build time.

```zig
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

fn add(a: i64, b: i64) i64 {
    return a + b;
}

pub fn main(init: std.process.Init) !void {
    const lua = try zilua.State.init(init.gpa, .{});
    defer lua.deinit();

    lua.setGlobal("add", add);
    lua.registerType(Vec2);
    try lua.doString(
        \\local v = Vec2.init(3, 4) + Vec2.init(1, 1)
        \\print(add(1, 2), v:length(), v.x)
    );

    const n = try lua.call(i64, "add", .{ 40, 2 }); // 42
    std.debug.print("{d}\n", .{n});
}
```

| | |
|---|---|
| Bindings | functions, structs with methods, fields and metamethods, enums, tagged unions, optionals, slices, tuples |
| Runtimes | Lua 5.1, 5.2, 5.3, 5.4, 5.5, LuaJIT, Luau behind one API, differences resolved at comptime |
| Memory | every Lua allocation goes through your `std.mem.Allocator`; clear ownership for values and handles |
| Errors | Lua errors come back as Zig errors with the message and a traceback, Zig errors become Lua errors, bound functions return before Lua raises so their `defer`s run |
| Scripting | coroutines, a scheduler, `std.Io` jobs, sandboxes with memory and instruction limits, hot reload |
| Modules | write Lua C modules in Zig and load them with `require` |

## Install

Zig 0.17.0 is required. Lua does not need to be installed: zilua compiles
the selected runtime from source, and downloads only that one.

```sh
zig fetch --save git+https://github.com/pz-radium/zilua
```

```zig
// build.zig
const zilua = b.dependency("zilua", .{
    .target = target,
    .optimize = optimize,
    .lang = .lua54,
});
exe.root_module.addImport("zilua", zilua.module("zilua"));
```

| Option | Default | Meaning |
|---|---|---|
| `lang` | `lua54` | `lua51`, `lua52`, `lua53`, `lua54`, `lua55`, `luajit` or `luau` |
| `api_check` | on in debug builds | compile Lua with `LUA_USE_APICHECK`, so that C API misuse asserts instead of corrupting memory |
| `link_lua` | `true` | `false` builds the module without a runtime, for Lua C modules |

## Runtimes

| `lang` | Runtime | Source |
|---|---|---|
| `lua51` | Lua 5.1.5 | lua.org |
| `lua52` | Lua 5.2.4 | lua.org |
| `lua53` | Lua 5.3.6 | lua.org |
| `lua54` | Lua 5.4.9 | lua.org |
| `lua55` | Lua 5.5.1 | lua.org |
| `luajit` | LuaJIT 2.1, x86_64, aarch64 and x86 | pinned commit of the v2.1 branch |
| `luau` | Luau 0.741 | release tag |

zilua hides the differences between the C APIs. The languages themselves
still differ:

- Luau has no `collectgarbage` (use `lua.collectGarbage()` from Zig), reports
  "invalid argument" instead of "bad argument", and `typeof` returns the
  usertype name. Source is compiled with `luau_compile` before loading.
- LuaJIT is built with the JIT compiler and FFI. Its errors unwind with the
  system unwinder, which needs unwind tables (Zig emits them by default on
  the targets that need them).
- Lua 5.1, 5.2, LuaJIT and Luau have no integer subtype: integers above 2^53
  lose precision, and argument errors say "number expected".
- On Lua 5.1, error messages come without a traceback.

To update a runtime, point its entry in `build.zig.zon` at the new release.
`zig fetch --save=<name>` replaces the URL and hash and keeps the entry lazy:

```sh
zig fetch --save=lua54 https://www.lua.org/ftp/lua-5.4.X.tar.gz
zig fetch --save=luajit https://github.com/LuaJIT/LuaJIT/archive/<commit>.tar.gz
zig fetch --save=luau https://github.com/luau-lang/luau/archive/refs/tags/<version>.tar.gz
```

## Guide

### Functions

Any non-generic Zig function can be called from Lua. Arguments are checked
and converted in order, and the result is pushed back:

```zig
fn divmod(a: i64, b: i64) struct { i64, i64 } { // tuple: several results
    return .{ @divFloor(a, b), @mod(a, b) };
}

fn greet(name: []const u8, loud: ?bool) []const u8 { ... } // ?T: optional argument

lua.setGlobal("divmod", divmod); // local q, r = divmod(7, 2)
```

A wrong argument raises the usual Lua error, for example
`bad argument #2 to 'divmod' (integer expected, got string)` on Lua 5.4.

These parameter types are filled in by zilua instead of read from Lua:

| Parameter | Receives |
|---|---|
| `zilua.State` | the calling state (or coroutine) |
| `std.mem.Allocator` | the state's allocator |
| `std.Io` | the `std.Io` given to `lua.setIo(io)` |
| `zilua.Args`, last | the remaining arguments, for variadic functions |

Return `lua.fail("message")` to raise a Lua error with your own message, and
`zilua.Owned(T)` to hand over memory that zilua frees once it is pushed:

```zig
fn sum(args: zilua.Args) !f64 { // sum(1, 2, 3)
    var total: f64 = 0;
    for (0..args.len()) |i| total += try args.get(f64, i);
    return total;
}

fn shout(gpa: std.mem.Allocator, text: []const u8) !zilua.Owned([]u8) {
    const out = try std.ascii.allocUpperString(gpa, text);
    return .{ .value = out, .gpa = gpa };
}
```

To call back into Lua and continue in Zig with the results, return
`zilua.CallThen`. On Lua 5.2 to 5.5 the Lua function may yield in between:

```zig
fn apply(f: zilua.Function, x: i64) zilua.CallThen(addOne, struct { i64 }) {
    return .{ .func = f, .args = .{x} }; // apply(fn, 5) == fn(5) + 1
}

fn addOne(result: i64) i64 {
    return result + 1;
}
```

### Structs

A struct reaching Lua becomes a userdata. Its metatable is generated from the
type the first time:

- public functions are methods (`v:length()`) and, after
  `lua.registerType(T)`, also functions of a global table (`Vec2.init(1, 2)`)
- fields are read and assigned by name, with type checks (`v.x = 3`)
- `__add`, `__eq`, `__lt`, `__len`, `__call`, `__concat`, ... become metamethods
- `T.zilua_name` sets the name Lua sees
- `deinit` is never callable from Lua

Fields and functions whose types zilua cannot convert are skipped, not
reported as compile errors.

### Values

| Zig | Lua |
|---|---|
| `bool` | boolean; reading follows Lua truthiness |
| integers | integer (5.3+) or number; reading checks range and integrality |
| floats | number |
| `[]const u8`, `[:0]const u8` | string |
| `?T` | `nil` or `T` |
| enum | tag name (an integer for non-exhaustive enums); reading accepts names or integers |
| tagged union | `{ circle = 2 }`, or `true` as the payload of void tags |
| struct `T` | userdata owned by Lua (a copy) |
| `*T`, `*const T` | userdata referring to the Zig object, read-only for `*const` |
| tuple, array, slice | sequence |
| `zilua.asTable(value)` | table of the struct's fields |
| `zilua.Table`, `Function`, `Thread`, `Ref` | handles that keep a Lua value alive |

A struct can also be read from a Lua table, field by field. A missing field
takes its default value, or `null` if it is optional; otherwise the read
fails with `error.MissingField`. Structs with string or slice fields can be
read from a table only with the `*Alloc` functions, which copy them.

### Memory and lifetimes

- `State.init(gpa, .{})` routes every Lua allocation through `gpa`, so
  `std.testing.allocator` catches leaks in Lua code as well.
- A value pushed by value belongs to Lua. When it is collected, zilua calls
  `pub fn __gc(self: *T) void` if the type declares it, otherwise
  `pub fn deinit(self: *T) void`. A type whose `deinit` needs more arguments
  cannot be pushed by value: push a pointer, or declare `__gc`.
- A value pushed by pointer stays Zig's and must outlive its use from Lua.
- A struct field that is itself a struct is returned as a reference into the
  parent, and keeps the parent alive.
- Strings and pointers read from Lua point into Lua memory. Arguments of
  bound functions are safe for the whole call; elsewhere use the `*Alloc`
  variants (`getGlobalAlloc`, `callAlloc`, `Table.getAlloc`, ...), which copy,
  and release the copy with `zilua.free(gpa, value)`.
- Handles are released with `deinit`. Handle parameters of bound functions
  are released after the call; `clone()` one to keep it.

### Errors

- `doString`, `call`, `Function.call`, ... run in protected mode and return
  `error.Runtime`, `error.Syntax`, ... with the message and a traceback in
  `lua.errorMessage()`.
- A Zig error returned by a bound function becomes a Lua error that scripts
  can `pcall`.
- Lua raises errors with `longjmp`, which would skip Zig `defer`s. zilua lets
  bound functions return first and raises afterwards. Code that uses the raw
  `zilua.api` layer inside a bound function has to do the same. The one
  exception is running out of memory inside a Lua API call that a bound
  function makes itself: that error still unwinds through the function.

### Coroutines

```zig
const co = lua.newThread(func);
defer co.deinit();
switch (try co.run(i64, .{10})) {
    .yielded => |v| ..., // coroutine.yield(v)
    .returned => |v| ..., // the function returned v
}
```

A bound function yields by returning `zilua.yield(values)`. The values given
to the next `run` become its results in Lua:

```zig
fn ask(question: i64) zilua.Yield(i64) {
    return zilua.yield(question * 2); // local answer = ask(21)
}
```

`zilua.Scheduler` runs coroutines that wait, the usual shape of game scripts
(see [examples/scheduler.zig](examples/scheduler.zig)):

```zig
var scheduler: zilua.Scheduler = .init(lua, gpa);
defer scheduler.deinit();
scheduler.registerWait("wait"); // wait(seconds) in Lua
scheduler.registerSpawn("spawn"); // spawn(function) in Lua
try scheduler.spawn(level_script, .{});
while (running) scheduler.update(seconds_since_start);
```

### Async work with std.Io

A task can wait for Zig work run through `std.Io`. It resumes with the
work's result, or `nil, "ErrorName"`:

```zig
scheduler.io = io; // the std.Io that runs the work
scheduler.attach(); // so that Scheduler.of finds it (registerSpawn does this too)

fn fetch(lua: zilua.State, id: i64) !zilua.Yield(zilua.Scheduler.Job) {
    const scheduler = zilua.Scheduler.of(lua) orelse return lua.fail("no scheduler");
    return zilua.yield(try scheduler.startJob(loadRecord, .{id}));
}
// in a task: local record = fetch(42)
```

The work may run on another thread: it must not touch the Lua state, and
must own the strings it gets from Lua.

### Sandboxes

```zig
const sandbox = try lua.newSandbox(.{
    .limits = .{ .memory = 1 << 20, .instructions = 1_000_000 }, // per call
});
defer sandbox.deinit();
try sandbox.set("log", log);
try sandbox.doString(untrusted_source);
try sandbox.call(void, "on_event", .{event});
```

- A sandbox gets copies of the safe libraries. `io`, `debug`, `package`,
  `require`, `load`, `dofile`, `print` and most of `os` are absent (give it
  what it needs with `set`), and globals a script defines stay inside the
  sandbox.
- Precompiled chunks are rejected.
- Over the memory limit, allocations fail with "not enough memory". Over the
  instruction limit, every following instruction raises, so `pcall` cannot
  keep a runaway loop alive. LuaJIT's JIT compiler is off while an
  instruction limit is set.
- On Luau the library copies are read-only, `.luau_fast_builtins = true`
  enables Luau's safe-environment fast paths, and `lua.freezeGlobals()`
  makes the shared globals read-only.

### Hot reload

```zig
var reloader: zilua.Reloader = .init(lua, gpa, std.Io.Dir.cwd());
defer reloader.deinit();
try reloader.watch(io, "scripts/main.lua"); // runs it once
// in the main loop:
_ = reloader.poll(io) catch |err| report(err, lua.errorMessage());
```

A file that fails to compile changes nothing, so the previous version keeps
running. After a reload zilua calls the global `on_reload(path)`, if a script
defines one. `lua.reloadModule(name)` reloads a `require`d module in place
(not on Luau, which has no `require`).

### Lua C modules

Build with `link_lua = false`, so that the module uses the Lua of the
process that loads it:

```zig
// build.zig
const zilua = b.dependency("zilua", .{
    .target = target,
    .optimize = optimize,
    .lang = .lua54, // the runtime of the interpreter that loads the module
    .link_lua = false,
});
const lib = b.addLibrary(.{
    .linkage = .dynamic,
    .name = "vec",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/vec.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zilua", .module = zilua.module("zilua") }},
    }),
});
lib.linker_allow_shlib_undefined = true; // Lua's symbols come from the host
b.installArtifact(lib);
```

```zig
// src/vec.zig: local vec = require("vec")
const zilua = @import("zilua");

comptime {
    zilua.exportModule("vec", @This()); // exports luaopen_vec
}

pub fn length(x: f64, y: f64) f64 {
    return @sqrt(x * x + y * y);
}
```

Bound functions taking a `zilua.State` work in modules too.

## Limitations

- LuaJIT is not available on 32-bit ARM.
- `CallThen` cannot yield on Lua 5.1, LuaJIT and Luau.
- Lua C modules on Windows need an import library for the host's Lua DLL,
  which zilua does not set up.
- Coroutines run by a `Scheduler` use the state's limits, not a sandbox's.

## Development

```sh
zig build test -Dlang=lua54 --summary all   # or lua51 lua52 lua53 lua55 luajit luau
zig build run-basic                         # examples/basic.zig
zig build run-scheduler                     # examples/scheduler.zig
zig build module                            # examples/module.zig, for Linux, BSD, macOS
```

32-bit builds run on 64-bit Windows with `-Dtarget=x86-windows`. See
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

MIT, see [LICENSE](LICENSE). Lua, LuaJIT and Luau are distributed under
their own MIT licenses.
