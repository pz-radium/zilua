# Contributing

## Workflow

- `main` is always green. Work on a branch (`fix/...`, `feat/...`, `docs/...`)
  and open a pull request against `main`.
- CI (`.github/workflows/ci.yml`) runs on every pull request and on pushes to
  `main`: the tests of all seven runtimes on Linux, macOS and Windows in debug
  and safe builds, the examples, 32-bit Windows, a Lua C module loaded by a
  real `lua5.4`, and `zig fmt --check`. A pull request merges once it passes.
- Keep commits focused, with a short imperative subject line
  ("Add Table.len for Luau", not "added stuff").
- Note changes users will notice under "Unreleased" in
  [CHANGELOG.md](CHANGELOG.md).

## Before pushing

```sh
zig fmt src build build.zig build.zig.zon examples
zig build test -Dlang=lua54 --summary all
zig build test -Dlang=lua51 --summary all
zig build test -Dlang=luajit --summary all
zig build test -Dlang=luau --summary all
```

Those four cover most runtime differences; CI runs the rest. Zig 0.17.0 is
required.

## Rules of the code base

- Only `src/runtime/api.zig` may branch on the runtime (`switch (lang)`).
  Everything else goes through `api.*`.
- Never raise a Lua error while a Zig frame with pending `defer`s is on the
  stack: Lua unwinds with `longjmp` (LuaJIT with the system unwinder), which
  skips them. Bound functions return normally, and only then does the
  trampoline raise (`fail` in `src/binding/bind.zig`).
- Sources use LF line endings (enforced by `.gitattributes`), no tabs, and
  spaces on both sides of binary operators.

## Tests

- Lua snippets in tests must run on every runtime: no `collectgarbage` (Luau
  lacks it; use `lua.collectGarbage()`), no `//` or `goto`. Tests that only
  apply to some runtimes go in `src/tests/runtimes.zig` and return
  `error.SkipZigTest` elsewhere.
- Never let Lua code `print` inside tests: stdout carries the test runner's
  protocol and the run hangs. Report failures with `error(...)` and run
  snippets through the `run` helper in `src/tests/helpers.zig`.
- If the build cache gets into a bad state, remove the whole `.zig-cache`
  directory, never single files inside it.
