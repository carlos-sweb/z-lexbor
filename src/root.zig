//! z-lexbor — Zig bindings and idiomatic wrapper for the lexbor HTML engine.
//!
//! Two layers are provided:
//!
//!   * `sys` — the complete raw C API, translated 1:1 from lexbor v3.0.1.
//!     Anything lexbor can do is reachable here, even before a dedicated
//!     wrapper module exists.
//!   * wrapper modules (`html`, `dom`, `css`, `selectors`, `url`, `encoding`,
//!     `status`) — RAII types, Zig slices, error sets and `std.Io` integration
//!     built on top of `sys`.

pub const sys = @import("sys/root.zig");

/// lexbor status codes and their Zig error mapping.
pub const status = @import("status.zig");

/// DOM views, iterators and attribute access.
pub const dom = @import("dom.zig");

/// HTML parser and document wrapper.
pub const html = @import("html.zig");

/// CSS parser (selector lists).
pub const css = @import("css.zig");

/// CSS selector matching (`querySelector`).
pub const selectors = @import("selectors.zig");

/// Conversion and callback helpers shared by the wrapper modules.
pub const internal = struct {
    pub const convert = @import("internal/convert.zig");
    pub const callback = @import("internal/callback.zig");
};

/// Raw success/error values and the `Status`/`Error` types, re-exported for
/// convenience.
pub const Status = status.Status;
pub const Error = status.Error;

test {
    @import("std").testing.refAllDecls(@This());
    _ = status;
    _ = internal.convert;
    _ = internal.callback;
    _ = dom;
    _ = html;
    _ = css;
    _ = selectors;
}
