# Changelog

All notable changes to zilua. Versions follow [Semantic Versioning](https://semver.org);
before 1.0, a minor version may break the API.

## Unreleased

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
