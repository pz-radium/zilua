//! Writing Lua C modules in Zig. In the root file of a shared library:
//!
//!     comptime {
//!         zilua.exportModule("geometry", @This());
//!     }
//!
//!     pub fn area(w: f64, h: f64) f64 { ... }
//!
//! exports `luaopen_geometry`, so that `require("geometry")` in a Lua host
//! returns a table with the public functions of the file. Build the library
//! with `-Dlink_lua=false`: the module then uses the host's Lua instead of
//! linking its own. Bound functions work as usual; a `zilua.State`
//! parameter refers to the host's state.

const api = @import("../runtime/api.zig");
const usertype = @import("../binding/usertype.zig");

/// Exports `luaopen_<name>` returning a table with the public functions of
/// `M`. Call it in a `comptime` block.
pub fn exportModule(comptime name: []const u8, comptime M: type) void {
    @export(openFunction(M), .{ .name = "luaopen_" ++ name });
}

/// The `luaopen_*` function for `M`, for linking a module into a program
/// directly (for example through `package.preload`).
pub fn openFunction(comptime M: type) api.CFunction {
    return &struct {
        fn open(L: ?*api.lua_State) callconv(.c) c_int {
            usertype.pushFunctionTable(L.?, M);
            return 1;
        }
    }.open;
}
