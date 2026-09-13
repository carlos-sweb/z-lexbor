//! Conversions between lexbor's C string conventions and Zig slices.
//!
//! lexbor never uses NUL-terminated strings for content: it passes a
//! `lxb_char_t *` plus a length, or a `lexbor_str_t` pair. These helpers turn
//! those into slices that can be passed straight to Zig code.
//!
//! The returned slices **borrow** lexbor-owned memory. They stay valid only as
//! long as the owning lexbor object lives (in practice: until the parser or
//! document that produced them is destroyed).

const std = @import("std");
const c = @import("../sys/root.zig").c;

/// Views `len` bytes at `data` as a slice.
///
/// A null pointer (or a zero length) yields an empty slice instead of trapping,
/// because lexbor uses `{NULL, 0}` for absent strings.
pub fn slice(data: [*c]const c.lxb_char_t, len: usize) []const u8 {
    if (data == null or len == 0) return &.{};
    return data[0..len];
}

/// Mutable counterpart of `slice`.
pub fn sliceMut(data: [*c]c.lxb_char_t, len: usize) []u8 {
    if (data == null or len == 0) return &.{};
    return data[0..len];
}

/// Views a NUL-terminated C string. Returns an empty slice when `data` is null.
pub fn span(data: [*c]const c.lxb_char_t) []const u8 {
    if (data == null) return &.{};
    return std.mem.span(@as([*:0]const c.lxb_char_t, @ptrCast(data)));
}

/// Views a `lexbor_str_t`. The slice is not NUL-terminated.
pub fn str(value: c.lexbor_str_t) []const u8 {
    return slice(value.data, value.length);
}

/// Reinterprets a Zig byte slice as lexbor's `lxb_char_t` pointer.
pub fn ptr(bytes: []const u8) [*c]const c.lxb_char_t {
    return @ptrCast(bytes.ptr);
}

/// Mutable counterpart of `ptr`.
pub fn ptrMut(bytes: []u8) [*c]c.lxb_char_t {
    return @ptrCast(bytes.ptr);
}

test "slice tolerates null and zero length" {
    try std.testing.expectEqual(@as(usize, 0), slice(null, 0).len);
    try std.testing.expectEqual(@as(usize, 0), slice(null, 7).len);

    const bytes = "hello";
    try std.testing.expectEqualStrings("hello", slice(bytes.ptr, bytes.len));
    try std.testing.expectEqualStrings("", slice(bytes.ptr, 0));
}

test "span reads NUL-terminated strings" {
    try std.testing.expectEqualStrings("", span(null));
    try std.testing.expectEqualStrings("abc", span("abc"));
}

test "str views a lexbor_str_t" {
    var bytes = [_]u8{ 'a', 'b', 'c', 0 };
    const value = c.lexbor_str_t{ .data = &bytes, .length = 3 };
    try std.testing.expectEqualStrings("abc", str(value));
}

test "ptr round-trips through slice" {
    const bytes = "roundtrip";
    try std.testing.expectEqualStrings(bytes, slice(ptr(bytes), bytes.len));
}
