//! Encoding lookup.
//!
//! lexbor exposes the WHATWG Encoding Standard through a data table plus
//! per-encoding decode/encode callback pairs. This module provides the lookup
//! half (name -> encoding data); the raw decode/encode entry points are always
//! reachable through `sys.c.lxb_encoding_*`.

const std = @import("std");
const c = @import("sys/root.zig").c;
const conv = @import("internal/convert.zig");

/// A resolved WHATWG encoding.
pub const Encoding = struct {
    data: [*c]const c.lxb_encoding_data_t,

    pub fn raw(self: Encoding) [*c]const c.lxb_encoding_data_t {
        return self.data;
    }
};

/// Looks up an encoding by label (e.g. `"utf-8"`, `"latin1"`, `"shift_jis"`).
///
/// Returns null when the label is not a WHATWG encoding label.
pub fn byName(label: []const u8) ?Encoding {
    const data = c.lxb_encoding_data_by_name(conv.ptr(label), label.len);
    if (data == null) return null;
    return .{ .data = data };
}

/// The stable WHATWG name of an encoding.
pub fn name(encoding: Encoding) []const u8 {
    return conv.span(encoding.data.*.name);
}

test "resolves common WHATWG encoding labels" {
    const utf8 = byName("utf-8") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.ascii.eqlIgnoreCase("utf-8", name(utf8)));

    // Labels are case-insensitive and alias to the canonical name.
    const latin1 = byName("latin1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.ascii.eqlIgnoreCase("windows-1252", name(latin1)));

    // Lookup is case-insensitive on the input label too.
    try std.testing.expect(byName("UTF-8") != null);
    try std.testing.expect(byName("Shift_JIS") != null);

    try std.testing.expect(byName("definitely-not-an-encoding") == null);
}
