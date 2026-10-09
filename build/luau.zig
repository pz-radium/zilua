//! Builds the Luau VM and compiler (C++17) from a release tarball.
//!
//! Luau's C API has C++ linkage unless built with `LUA_API=extern "C"`, which
//! in turn requires `LUA_USE_LONGJMP=1` (errors then unwind with longjmp like
//! PUC Lua, instead of C++ exceptions). This mirrors the LUAU_EXTERN_C option
//! of Luau's CMakeLists.txt.

const std = @import("std");
const Options = @import("lua.zig").Options;

/// Returns null while the source tarball has not been fetched yet.
pub fn addLibrary(b: *std.Build, options: Options) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("luau", .{}) orelse return null;

    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    inline for (.{ "Common/include", "Ast/include", "Bytecode/include", "Compiler/include", "VM/include", "VM/src" }) |dir| {
        mod.addIncludePath(dep.path(dir));
    }
    mod.addCMacro("LUA_API", "extern \"C\"");
    mod.addCMacro("LUACODE_API", "extern \"C\"");
    mod.addCMacro("LUA_USE_LONGJMP", "1");
    if (options.api_check) mod.addCMacro("LUAU_ENABLE_ASSERT", "1");

    mod.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &files,
        .flags = &.{"-std=c++17"},
    });

    return b.addLibrary(.{
        .linkage = .static,
        .name = "lua",
        .root_module = mod,
    });
}

/// The sources of the Luau.Common, Luau.Ast, Luau.Bytecode, Luau.Compiler and
/// Luau.VM targets in Sources.cmake.
const files = [_][]const u8{
    "Common/src/BytecodeWire.cpp",
    "Common/src/StringUtils.cpp",
    "Common/src/TimeTrace.cpp",

    "Ast/src/Allocator.cpp",
    "Ast/src/Ast.cpp",
    "Ast/src/Confusables.cpp",
    "Ast/src/Cst.cpp",
    "Ast/src/Lexer.cpp",
    "Ast/src/Location.cpp",
    "Ast/src/Parser.cpp",
    "Ast/src/PrettyPrinter.cpp",

    "Bytecode/src/BytecodeBuilder.cpp",
    "Bytecode/src/BytecodeDump.cpp",
    "Bytecode/src/BytecodeGraph.cpp",
    "Bytecode/src/Sccp.cpp",

    "Compiler/src/Compiler.cpp",
    "Compiler/src/Builtins.cpp",
    "Compiler/src/BuiltinFolding.cpp",
    "Compiler/src/ConstantFolding.cpp",
    "Compiler/src/CostModel.cpp",
    "Compiler/src/TableShape.cpp",
    "Compiler/src/Types.cpp",
    "Compiler/src/ValueTracking.cpp",
    "Compiler/src/lcode.cpp",

    "VM/src/lapi.cpp",
    "VM/src/laux.cpp",
    "VM/src/lbaselib.cpp",
    "VM/src/lbitlib.cpp",
    "VM/src/lbuffer.cpp",
    "VM/src/lbuflib.cpp",
    "VM/src/lbuiltins.cpp",
    "VM/src/lcorolib.cpp",
    "VM/src/ldblib.cpp",
    "VM/src/ldebug.cpp",
    "VM/src/ldo.cpp",
    "VM/src/lfunc.cpp",
    "VM/src/lgc.cpp",
    "VM/src/lgcdebug.cpp",
    "VM/src/linit.cpp",
    "VM/src/lmathlib.cpp",
    "VM/src/lmem.cpp",
    "VM/src/lnumprint.cpp",
    "VM/src/lobject.cpp",
    "VM/src/loslib.cpp",
    "VM/src/lperf.cpp",
    "VM/src/lstate.cpp",
    "VM/src/lstring.cpp",
    "VM/src/lstrlib.cpp",
    "VM/src/ltable.cpp",
    "VM/src/ltablib.cpp",
    "VM/src/ltm.cpp",
    "VM/src/ludata.cpp",
    "VM/src/lutf8lib.cpp",
    "VM/src/lveclib.cpp",
    "VM/src/lintlib.cpp",
    "VM/src/lvmexecute.cpp",
    "VM/src/lclass.cpp",
    "VM/src/lclasslib.cpp",
    "VM/src/lvector.cpp",
    "VM/src/lvmload.cpp",
    "VM/src/lvmutils.cpp",
};
