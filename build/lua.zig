//! Builds the PUC-Rio Lua runtimes (5.1 to 5.5) from the official source
//! tarballs declared as lazy dependencies in build.zig.zon.

const std = @import("std");
const Lang = @import("../src/runtime/lang.zig").Lang;

/// The optimize mode type, named through the build API so that this file
/// does not depend on where std declares it.
const OptimizeMode = @typeInfo(@FieldType(std.Build.Module.CreateOptions, "optimize")).optional.child;

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    /// Compile with LUA_USE_APICHECK so that Lua asserts on C API misuse.
    api_check: bool,
};

/// Adds a static library for `lang`. Returns null while its source tarball
/// has not been fetched yet; the build runner fetches it and runs build() again.
pub fn addLibrary(b: *std.Build, lang: Lang, options: Options) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency(@tagName(lang), .{}) orelse return null;

    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    mod.addIncludePath(dep.path("src"));

    switch (options.target.result.os.tag) {
        .linux => mod.addCMacro("LUA_USE_LINUX", "1"),
        .macos, .ios => if (lang == .lua51) {
            // 5.1's LUA_USE_MACOSX selects the long-removed NSModule (dyld) API.
            mod.addCMacro("LUA_USE_POSIX", "1");
            mod.addCMacro("LUA_USE_DLOPEN", "1");
            mod.addCMacro("LUA_DL_DLOPEN", "1");
        } else {
            mod.addCMacro("LUA_USE_MACOSX", "1");
        },
        .freebsd, .netbsd, .openbsd, .dragonfly => mod.addCMacro("LUA_USE_POSIX", "1"),
        // luaconf.h detects Windows by itself.
        else => {},
    }
    switch (lang) {
        .lua52 => mod.addCMacro("LUA_COMPAT_ALL", "1"),
        .lua53 => mod.addCMacro("LUA_COMPAT_5_2", "1"),
        .lua54 => mod.addCMacro("LUA_COMPAT_5_3", "1"),
        else => {},
    }
    if (options.api_check) mod.addCMacro("LUA_USE_APICHECK", "1");

    mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = sourceFiles(lang),
        .flags = &.{
            "-std=gnu99",
            // Third-party code: older releases trip UBSan traps that the
            // Lua authors consider defined enough (e.g. in lstrlib.c).
            "-fno-sanitize=undefined",
        },
    });

    return b.addLibrary(.{
        .linkage = .static,
        .name = "lua",
        .root_module = mod,
    });
}

fn sourceFiles(lang: Lang) []const []const u8 {
    return switch (lang) {
        .lua51 => &lua51_files,
        .lua52 => &lua52_files,
        .lua53 => &lua53_files,
        .lua54, .lua55 => &lua54_files,
        .luajit, .luau => unreachable, // not built from the PUC sources
    };
}

// The library sources of each release: everything in src/ except the
// stand-alone interpreter (lua.c) and compiler (luac.c, print.c).

const lua51_files = [_][]const u8{
    "lapi.c",     "lcode.c",   "ldebug.c",  "ldo.c",      "ldump.c",
    "lfunc.c",    "lgc.c",     "llex.c",    "lmem.c",     "lobject.c",
    "lopcodes.c", "lparser.c", "lstate.c",  "lstring.c",  "ltable.c",
    "ltm.c",      "lundump.c", "lvm.c",     "lzio.c",     "lauxlib.c",
    "lbaselib.c", "ldblib.c",  "liolib.c",  "lmathlib.c", "loslib.c",
    "ltablib.c",  "lstrlib.c", "loadlib.c", "linit.c",
};

const lua52_files = [_][]const u8{
    "lapi.c",    "lcode.c",    "lctype.c",  "ldebug.c",   "ldo.c",
    "ldump.c",   "lfunc.c",    "lgc.c",     "llex.c",     "lmem.c",
    "lobject.c", "lopcodes.c", "lparser.c", "lstate.c",   "lstring.c",
    "ltable.c",  "ltm.c",      "lundump.c", "lvm.c",      "lzio.c",
    "lauxlib.c", "lbaselib.c", "lbitlib.c", "lcorolib.c", "ldblib.c",
    "liolib.c",  "lmathlib.c", "loslib.c",  "lstrlib.c",  "ltablib.c",
    "loadlib.c", "linit.c",
};

const lua53_files = lua52_files ++ [_][]const u8{"lutf8lib.c"};

/// Also the file list of 5.5.
const lua54_files = [_][]const u8{
    "lapi.c",     "lcode.c",    "lctype.c",   "ldebug.c",  "ldo.c",
    "ldump.c",    "lfunc.c",    "lgc.c",      "llex.c",    "lmem.c",
    "lobject.c",  "lopcodes.c", "lparser.c",  "lstate.c",  "lstring.c",
    "ltable.c",   "ltm.c",      "lundump.c",  "lvm.c",     "lzio.c",
    "lauxlib.c",  "lbaselib.c", "lcorolib.c", "ldblib.c",  "liolib.c",
    "lmathlib.c", "loadlib.c",  "loslib.c",   "lstrlib.c", "ltablib.c",
    "lutf8lib.c", "linit.c",
};
