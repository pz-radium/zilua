# Changelog

All notable changes to zilua. Versions follow [Semantic Versioning](https://semver.org);
before 1.0, a minor version may break the API.

## Unreleased

### Security

Two reviews of the whole library since 0.2.0. Everyone on it should upgrade:
these let a script reach freed memory, release a host resource twice, or run
past a sandbox's instruction limit.

- A `*T` a bound function returned that pointed into one of its arguments
  (`pub fn scaled(self: *T, k: f64) *T { ...; return self }`, the chaining
  setter) was handed to Lua with nothing keeping that argument alive. Such a
  reference now keeps it alive, and dies with it.
- Reading a field whose type wraps something a finalizer releases (`?Item`,
  `[]Item`, a union holding one) gave Lua an owned copy, so `Item.deinit`
  ran on memory the host still used. Those fields are refused now, for
  reading as well as assigning.
- A tagged union parameter with a string or pointer payload pointed into the
  stack slot the conversion had already popped. Unions with such payloads
  now need the `*Alloc` variants, like tuples and arrays.
- Reading a table that refers to itself into a type that refers to itself
  (`struct { children: []@This() }`) recursed until the Lua stack was
  overrun. Nesting is bounded (`zilua.max_depth`, `error.TooDeep`).
- Once the instruction limit was exceeded inside a coroutine, only that
  coroutine kept raising at every instruction: PUC Lua hooks belong to each
  thread, so a script could catch the error on the main thread and keep
  going. The limit also reaches coroutines running a call from Zig now.
- A value of a type with a finalizer could be built from a Lua table, which
  let a script choose what gets released (a file descriptor, a texture id),
  and could be read as an owned result (`getGlobal`, `call`), whose copy
  shared what the original releases. Both are refused.
- Resuming a coroutine that was running, or that had resumed another, was
  reported by clearing the stack of its live frame (5.1 and LuaJIT do that
  in `lua_resume` itself), unrooting the values it was working with.
- Nested resumes from Zig each started the runtime's own C call count over,
  so the bound on them multiplied with the recursion a script does in
  between. The count carries over now (through `lua_setlevel` on 5.1);
  LuaJIT, which cannot, has a lower bound of its own.
- Handles (`Table`, `Function`, ...) inside a parameter read from a table
  were never released, leaving a registry reference per call.
- `*anyopaque` parameters took any userdata, including one belonging to
  another library; they take light userdata only.

### Fixed

- A memory limit a script had filled up made zilua's own work for the host
  (pushing arguments, reading results, taking references, the message
  handler, a full collection) fail with an error raised outside any
  protected call, which ends the process. That work runs with the limit
  lifted now, and what allocates before a protected call starts runs inside
  one.
- A bound function that returns `zilua.Owned`, or that takes a handle,
  pushes its result in protected mode: a memory error there used to longjmp
  past the code that frees the memory, or releases the references taken for
  the parameters, and leak them.
- Building the traceback of a failed coroutine ran unprotected with no
  memory limit at all; on Luau, which shows every level, a stack overflow
  could turn into hundreds of megabytes.
- An allocation failure while a usertype's metatable was first built left a
  half-filled metatable registered for good (no finalizer, no lock).
- `restoreLimits` left the step hook firing at every instruction for the
  rest of an outer limited call.
- Releasing a `Table`, `Function` or `Thread` handle twice now panics in
  safe builds instead of quietly handing one registry slot to two handles.
- `Thread.status` reports `.running` for a coroutine that is running or has
  resumed another, which `Thread.run` refuses, instead of `.ready`.
- A `Scheduler.update` called from inside a task (or from `on_error`) is
  reported and ignored, instead of working from indices the outer one has
  moved.
- A task that yields the light userdata of a job that has already finished
  is no longer matched with a later job at the same address.
- `Scheduler.spawnLimited` no longer leaves a started job behind if it then
  runs out of memory.
- `Reloader.watch` freed the path of a file whose first run failed while
  still watching it, and `Reloader` now reads at most `max_file_size`
  (16 MiB) per file.
- A string with an embedded zero is refused where a `[:0]const u8` is
  expected, instead of being cut short on the Zig side.
- `doFile` on Lua 5.1 and Luau could raise outside protected mode, leaking
  the file it had read, when out of memory; it reads the file in one pass
  now.
- The State API reads and writes globals raw, so an `__index`/`__newindex`
  on the globals table (a "strict" module) no longer runs outside protected
  mode.
- A Lua C module first called from a coroutine on Lua 5.1 or LuaJIT keeps
  that coroutine alive, since its context runs on it.
- `collectGarbage` no longer aborts when a `__gc` metamethod raises (5.2,
  5.3).
- Scheduler jobs keep the `std.Io` they started on and reserve stack space
  for their results, and a task waiting NaN seconds is reported.
- `getUserValue` on 5.1 and LuaJIT returned the globals table for a userdata
  that never had one; `setUserValue` took values those runtimes cannot
  store.
- `rawLen` saturates instead of trapping on a 32-bit target, and `gcCount`
  no longer trips on the -1 that 5.4 and 5.5 return while collecting.
- Luau: a load that fails for lack of memory is reported as such, and the
  compiled bytecode is freed; `callWithContinuation` drops the values below
  the call in one pass instead of one by one.
- Lua 5.5 seeds its string hashes with `luaL_makeseed`, the clock-and-address
  seed Lua makes for itself, instead of one address.
- Lua 5.1: refusing a precompiled chunk in `doFile` no longer pushes its
  message while the file is still held.

### Breaking

- `zilua.ConvertError` has a new `TooDeep` error.
- Tagged unions with string, slice or pointer payloads, and values of types
  with a finalizer, are no longer read as owned results: use the `*Alloc`
  variants, or read a `*T`.
- Reading or assigning a usertype field whose type wraps a finalized value
  raises.
- Handles read with `convert.to`, including those inside a value and those
  from `zilua.Args.get`, belong to the caller: release them with
  `zilua.releaseHandles`.
- `Thread.Status` has a new `running` variant.
- On Luau, a `callThen` continuation that itself yields or uses `callThen`
  is a compile error.
- `*anyopaque` parameters take light userdata only.

## 0.2.0 - 2026-10-09

### Security

Everyone on 0.1.0 should upgrade: these issues let a script corrupt memory
or escape a sandbox's limits.

- Usertype metatables were reachable from Lua, so a script could call
  `__gc` itself and keep using the finalized value. Metatables are now
  locked (`__metatable`), and finalized values are refused everywhere.
- The `Scheduler` freed a job after handing its result to the first task
  waiting for it, even if a script had made a second task wait for it too.
  A job now has one waiting task at most.
- A `spawn` function registered by a `Scheduler` kept a pointer to it after
  `deinit`. It now raises "the scheduler behind this function is gone".
- `doFile` on Lua 5.1 loaded precompiled chunks, which 5.1 does not verify.
  Every runtime now refuses them.
- Sandboxed code could set `__gc` metamethods on tables (Lua 5.2 and later),
  which ran later, outside the sandbox's limits. Sandboxes now refuse them.
- Reading a slice from a table allocated for `#t` elements before checking
  them, and `#t` can be huge for a table with few elements. Slices are now
  read only from sequences without holes, checked before allocating.
- The memory limit check could overflow on 32-bit targets when Lua asked
  for close to 4 GiB.
- Turning an error into `errorMessage()` could run into the memory limit the
  script had just hit, and raise again outside protected mode.

### Breaking

- `getmetatable()` on a usertype value returns its type name.
- Slices read from Lua tables must not contain `nil` before their end.
- Sandboxed `setmetatable` refuses metatables with `__gc`.
- Pushing the same pointer twice gives the same userdata.
- `zilua.ConvertError` has a new `Dead` error.
- `Scheduler.spawn` runs the new task under the limits of the code that
  calls it, if any.

### Added

- `State.invalidate(ptr)` detaches Lua from a Zig object pushed by pointer:
  scripts that still hold it, or a field inside it, get "T no longer
  exists".
- `Scheduler.spawnLimited(func, args, limits)` runs a task under limits on
  every resume, and tasks spawned by limited code inherit them.
- `callThen` can yield on Luau, through Luau's C continuations.

### Fixed

- Coroutines resumed from Zig now count against the instruction limit even
  if they were created before it was set (PUC Lua hooks belong to each
  thread).

### Documentation

- The instruction limit counts Lua instructions, not time spent inside a C
  library call such as pattern matching.

## 0.1.0 - 2026-10-09

First release: Zig ↔ Lua bindings generated at comptime, with one API for
Lua 5.1, 5.2, 5.3, 5.4, 5.5, LuaJIT and Luau.
