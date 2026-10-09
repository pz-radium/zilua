//! A Lua C module written with zilua. `zig build module -Dtarget=...`
//! produces libvec.so (or .dylib); with it on package.cpath, Lua scripts can
//!
//!     local vec = require("vec")
//!     print(vec.length(3, 4), vec.normalize(3, 4))
//!
//! Build it for the same runtime (-Dlang) as the Lua that loads it.

const zilua = @import("zilua");

comptime {
    zilua.exportModule("vec", @This());
}

pub fn length(x: f64, y: f64) f64 {
    return @sqrt(x * x + y * y);
}

pub fn normalize(x: f64, y: f64) struct { f64, f64 } {
    const len = length(x, y);
    if (len == 0) return .{ 0, 0 };
    return .{ x / len, y / len };
}

/// Bound functions can still take the state; zilua attaches to the host's.
pub fn runtime(lua: zilua.State) []const u8 {
    _ = lua;
    return @tagName(zilua.lang);
}
