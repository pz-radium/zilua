const std = @import("std");
const Lang = @import("src/runtime/lang.zig").Lang;
const lua_build = @import("build/lua.zig");
const luajit_build = @import("build/luajit.zig");
const luau_build = @import("build/luau.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lang = b.option(Lang, "lang", "Lua runtime to build against (default: lua54)") orelse .lua54;
    const api_check = b.option(bool, "api_check", "Make Lua assert on C API misuse (default: on in debug)") orelse
        (optimize == .debug);
    const link_lua = b.option(bool, "link_lua", "Link the Lua runtime into the zilua module; false for Lua C modules, " ++
        "which use their host's Lua (default: true)") orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "lang", @tagName(lang));

    const zilua = createZilua(b, options, target, optimize, .public);

    // Lua C modules resolve Lua's symbols in the host process, so the module
    // example always uses a zilua that does not link Lua.
    const unlinked = if (link_lua) createZilua(b, options, target, optimize, .private) else zilua;
    addModuleExample(b, unlinked, target, optimize);
    if (!link_lua) return;

    const lua_options: lua_build.Options = .{
        .target = target,
        .optimize = optimize,
        .api_check = api_check,
    };
    const lua = switch (lang) {
        .luajit => luajit_build.addLibrary(b, lua_options),
        .luau => luau_build.addLibrary(b, lua_options),
        .lua51, .lua52, .lua53, .lua54, .lua55 => lua_build.addLibrary(b, lang, lua_options),
    } orelse return; // lazy dependency not fetched yet
    zilua.linkLibrary(lua);

    const tests = b.addTest(.{ .root_module = zilua });
    const test_step = b.step("test", "Run the zilua tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const examples_step = b.step("examples", "Build the examples");
    inline for (.{ "basic", "scheduler" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zilua", .module = zilua }},
            }),
        });
        examples_step.dependOn(&exe.step);
        const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
        run_step.dependOn(&b.addRunArtifact(exe).step);
    }
}

const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = @typeInfo(@FieldType(std.Build.Module.CreateOptions, "optimize")).optional.child;

fn createZilua(
    b: *std.Build,
    options: *std.Build.Step.Options,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    visibility: enum { public, private },
) *std.Build.Module {
    const create_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/zilua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };
    const module = switch (visibility) {
        .public => b.addModule("zilua", create_options),
        .private => b.createModule(create_options),
    };
    module.addOptions("zilua_options", options);
    return module;
}

/// `zig build module`: examples/module.zig as a shared library that Lua
/// loads with `require("vec")`. Lua's symbols stay undefined until the host
/// loads the library, which Windows DLLs do not allow without an import
/// library for the host's Lua DLL, so this targets Linux, the BSDs and macOS.
fn addModuleExample(b: *std.Build, zilua: *std.Build.Module, target: ResolvedTarget, optimize: OptimizeMode) void {
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "vec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/module.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zilua", .module = zilua }},
        }),
    });
    lib.linker_allow_shlib_undefined = true;
    const step = b.step("module", "Build examples/module.zig as a Lua C module (Linux, BSD, macOS)");
    step.dependOn(&b.addInstallArtifact(lib, .{}).step);
}
