//! Lua runtimes zilua can be built against.
//!
//! This file is imported both by `build.zig` (for the `-Dlang` option) and by
//! the library itself, so it must not import anything but `std`.

pub const Lang = enum {
    lua51,
    lua52,
    lua53,
    lua54,
    lua55,
    luajit,
    luau,

    /// Runtimes with a native integer subtype (`math.type(1) == "integer"`).
    pub fn hasIntegers(self: Lang) bool {
        return switch (self) {
            .lua53, .lua54, .lua55 => true,
            .lua51, .lua52, .luajit, .luau => false,
        };
    }

    /// Runtimes whose globals live behind the `LUA_GLOBALSINDEX` pseudo-index
    /// and whose upvalue indices are relative to it (the Lua 5.1 API family).
    pub fn usesGlobalsIndex(self: Lang) bool {
        return switch (self) {
            .lua51, .luajit, .luau => true,
            .lua52, .lua53, .lua54, .lua55 => false,
        };
    }

    /// Whether zilua can build this runtime yet.
    pub fn isSupported(self: Lang) bool {
        return switch (self) {
            .lua51, .lua52, .lua53, .lua54, .lua55, .luajit, .luau => true,
        };
    }
};
