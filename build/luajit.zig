//! Builds LuaJIT 2.1 from the rolling-release source tarball.
//!
//! Unlike PUC Lua, LuaJIT generates code at build time with two host tools:
//! 1. `minilua`, a small Lua, runs DynASM on `vm_<arch>.dasc` to produce
//!    `buildvm_arch.h`, and turns `luajit_rolling.h` into `luajit.h`.
//! 2. `buildvm` emits the interpreter (`lj_vm`) and the bytecode, fast
//!    function, library, recorder and fold tables.
//! The step order follows ziglua's build script (MIT) and LuaJIT's Makefile.

const std = @import("std");
const Options = @import("lua.zig").Options;

const Arch = enum { x64, arm64, x86 };

/// Returns null while the source tarball has not been fetched yet.
pub fn addLibrary(b: *std.Build, options: Options) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("luajit", .{}) orelse return null;
    const target = options.target.result;
    const arch: Arch = switch (target.cpu.arch) {
        .x86_64 => .x64,
        .aarch64 => .arm64,
        .x86 => .x86,
        else => std.debug.panic("zilua: LuaJIT targets x86_64, aarch64 and x86, not {s}", .{@tagName(target.cpu.arch)}),
    };
    const host = b.graph.host;
    // buildvm lays out VM structures with the host's pointer size, so a
    // 32-bit target needs a 32-bit buildvm: the x86 flavor of the host,
    // which x86_64 hosts can run (statically linked musl on Linux).
    const buildvm_host = if (arch != .x86) host else switch (host.result.cpu.arch) {
        .x86_64, .x86 => b.resolveTargetQuery(.{
            .cpu_arch = .x86,
            .os_tag = host.result.os.tag,
            .abi = if (host.result.os.tag == .linux) .musl else null,
        }),
        else => std.debug.panic("zilua: building LuaJIT for x86 needs an x86 or x86_64 host", .{}),
    };

    // -- minilua --------------------------------------------------------------

    const minilua = b.addExecutable(.{
        .name = "minilua",
        .root_module = b.createModule(.{
            .target = host,
            .optimize = .safe,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    minilua.root_module.addCSourceFile(.{ .file = dep.path("src/host/minilua.c") });

    const dynasm = b.addRunArtifact(minilua);
    dynasm.addFileArg(dep.path("dynasm/dynasm.lua"));
    // No #line directives: their Windows paths contain backslashes that C
    // compilers read as escape sequences.
    dynasm.addArg("-L");
    // The flags LuaJIT's Makefile derives for little-endian targets with
    // JIT, FFI and a hardware FPU.
    dynasm.addArgs(&.{ "-D", "ENDIAN_LE", "-D", "JIT", "-D", "FFI", "-D", "FPU", "-D", "HFABI" });
    switch (arch) {
        .x64 => dynasm.addArgs(&.{ "-D", "P64", "-D", "VER=" }),
        .arm64 => dynasm.addArgs(&.{ "-D", "P64", "-D", "DUALNUM", "-D", "VER=80" }),
        .x86 => dynasm.addArgs(&.{ "-D", "VER=" }),
    }
    if (target.os.tag == .windows) dynasm.addArgs(&.{ "-D", "WIN" });
    dynasm.addArg("-o");
    const buildvm_arch_h = dynasm.addOutputFileArg("buildvm_arch.h");
    dynasm.addFileArg(dep.path(switch (arch) {
        .x64 => "src/vm_x64.dasc",
        .arm64 => "src/vm_arm64.dasc",
        .x86 => "src/vm_x86.dasc",
    }));

    const genversion = b.addRunArtifact(minilua);
    genversion.addFileArg(dep.path("src/host/genversion.lua"));
    genversion.addFileArg(dep.path("src/luajit_rolling.h"));
    genversion.addFileArg(dep.path(".relver"));
    const luajit_h = genversion.addOutputFileArg("luajit.h");

    // -- buildvm --------------------------------------------------------------

    const buildvm = b.addExecutable(.{
        .name = "buildvm",
        .root_module = b.createModule(.{
            .target = buildvm_host,
            .optimize = .safe,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    buildvm.root_module.addCSourceFiles(.{
        .root = dep.path("src/host"),
        .files = &.{ "buildvm.c", "buildvm_asm.c", "buildvm_peobj.c", "buildvm_lib.c", "buildvm_fold.c" },
        // Windows' x86 ABI aligns doubles to 8 bytes; a non-Windows buildvm
        // must do the same to agree on structure layouts.
        .flags = if (arch == .x86 and target.os.tag == .windows and host.result.os.tag != .windows)
            &.{"-malign-double"}
        else
            &.{},
    });
    // buildvm runs on the host but generates code for the target.
    buildvm.root_module.addCMacro("LUAJIT_TARGET", switch (arch) {
        .x64 => "LUAJIT_ARCH_X64",
        .arm64 => "LUAJIT_ARCH_ARM64",
        .x86 => "LUAJIT_ARCH_X86",
    });
    buildvm.root_module.addCMacro("LUAJIT_OS", switch (target.os.tag) {
        .windows => "LUAJIT_OS_WINDOWS",
        .linux => "LUAJIT_OS_LINUX",
        .macos, .ios => "LUAJIT_OS_OSX",
        .freebsd, .netbsd, .openbsd, .dragonfly => "LUAJIT_OS_BSD",
        else => "LUAJIT_OS_POSIX",
    });
    if (arch == .arm64) {
        buildvm.root_module.addCMacro("LJ_ARCH_HASFPU", "1");
        buildvm.root_module.addCMacro("LJ_ABI_SOFTFP", "0");
    }
    buildvm.root_module.addIncludePath(dep.path("src"));
    buildvm.root_module.addIncludePath(buildvm_arch_h.dirname());
    buildvm.root_module.addIncludePath(luajit_h.dirname());

    const bcdef_h = runBuildvm(b, buildvm, dep, "bcdef", "lj_bcdef.h", &lib_files);
    const ffdef_h = runBuildvm(b, buildvm, dep, "ffdef", "lj_ffdef.h", &lib_files);
    const libdef_h = runBuildvm(b, buildvm, dep, "libdef", "lj_libdef.h", &lib_files);
    const recdef_h = runBuildvm(b, buildvm, dep, "recdef", "lj_recdef.h", &lib_files);
    const folddef_h = runBuildvm(b, buildvm, dep, "folddef", "lj_folddef.h", &.{"lj_opt_fold.c"});
    const lj_vm = switch (target.os.tag) {
        // A COFF object with the SEH unwind data Windows needs.
        .windows => runBuildvm(b, buildvm, dep, "peobj", "lj_vm.o", &.{}),
        .macos, .ios => runBuildvm(b, buildvm, dep, "machasm", "lj_vm.S", &.{}),
        else => runBuildvm(b, buildvm, dep, "elfasm", "lj_vm.S", &.{}),
    };

    // -- the library ------------------------------------------------------------

    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .sanitize_c = .off,
        // Errors unwind through C frames with the system unwinder ("external
        // unwinding", LuaJIT's default where the ABI mandates unwind tables).
        .unwind_tables = .async,
    });
    mod.addIncludePath(dep.path("src"));
    inline for (.{ luajit_h, bcdef_h, ffdef_h, libdef_h, recdef_h, folddef_h }) |generated| {
        mod.addIncludePath(generated.dirname());
    }
    mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &(core_files ++ lib_files),
    });
    if (target.os.tag == .windows) {
        mod.addObjectFile(lj_vm);
    } else {
        mod.addAssemblyFile(lj_vm);
        // Windows always unwinds externally (SEH); elsewhere it is opt-in.
        mod.addCMacro("LUAJIT_UNWIND_EXTERNAL", "1");
        mod.linkSystemLibrary("unwind", .{});
    }
    if (options.api_check) mod.addCMacro("LUA_USE_APICHECK", "1");

    return b.addLibrary(.{
        .linkage = .static,
        .name = "lua",
        .root_module = mod,
    });
}

/// Runs `buildvm -m mode -o out inputs...` and returns the generated file.
fn runBuildvm(
    b: *std.Build,
    buildvm: *std.Build.Step.Compile,
    dep: *std.Build.Dependency,
    mode: []const u8,
    out: []const u8,
    inputs: []const []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(buildvm);
    run.addArgs(&.{ "-m", mode, "-o" });
    const output = run.addOutputFileArg(out);
    for (inputs) |input| {
        run.addFileArg(dep.path(b.fmt("src/{s}", .{input})));
    }
    return output;
}

/// The standard library modules, which buildvm also scans for its tables
/// (LJLIB_C in the Makefile).
const lib_files = [_][]const u8{
    "lib_base.c",  "lib_math.c", "lib_bit.c", "lib_string.c",
    "lib_table.c", "lib_io.c",   "lib_os.c",  "lib_package.c",
    "lib_debug.c", "lib_jit.c",  "lib_ffi.c", "lib_buffer.c",
};

/// LJCORE_O in the Makefile, minus the library modules above.
const core_files = [_][]const u8{
    "lj_assert.c",     "lj_gc.c",        "lj_err.c",      "lj_char.c",
    "lj_bc.c",         "lj_obj.c",       "lj_buf.c",      "lj_str.c",
    "lj_tab.c",        "lj_func.c",      "lj_udata.c",    "lj_meta.c",
    "lj_debug.c",      "lj_prng.c",      "lj_state.c",    "lj_dispatch.c",
    "lj_vmevent.c",    "lj_vmmath.c",    "lj_strscan.c",  "lj_strfmt.c",
    "lj_strfmt_num.c", "lj_serialize.c", "lj_api.c",      "lj_profile.c",
    "lj_lex.c",        "lj_parse.c",     "lj_bcread.c",   "lj_bcwrite.c",
    "lj_load.c",       "lj_ir.c",        "lj_opt_mem.c",  "lj_opt_fold.c",
    "lj_opt_narrow.c", "lj_opt_dce.c",   "lj_opt_loop.c", "lj_opt_split.c",
    "lj_opt_sink.c",   "lj_mcode.c",     "lj_snap.c",     "lj_record.c",
    "lj_crecord.c",    "lj_ffrecord.c",  "lj_asm.c",      "lj_trace.c",
    "lj_gdbjit.c",     "lj_ctype.c",     "lj_cdata.c",    "lj_cconv.c",
    "lj_ccall.c",      "lj_ccallback.c", "lj_carith.c",   "lj_clib.c",
    "lj_cparse.c",     "lj_lib.c",       "lj_alloc.c",    "lib_aux.c",
    "lib_init.c",
};
