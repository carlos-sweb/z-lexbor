//! Tests for the C-string <-> Zig-slice conversions.
//!
//! These helpers sit on the boundary where a wrong assumption turns into a
//! segfault rather than an error, so they get adversarial treatment too.

const std = @import("std");
const lexbor = @import("z_lexbor");
const c = lexbor.sys.c;
const conv = lexbor.internal.convert;

test "slice: length is authoritative" {
    const bytes = "hello world";
    try std.testing.expectEqualStrings("hello", conv.slice(bytes.ptr, 5));
    try std.testing.expectEqualStrings("hello world", conv.slice(bytes.ptr, bytes.len));
    try std.testing.expectEqualStrings("", conv.slice(bytes.ptr, 0));
}

test "slice: a null pointer never dereferences, whatever the length" {
    // lexbor represents an absent string as {NULL, 0}. A non-zero length with a
    // null pointer is a programming error upstream; masking it as empty is
    // deliberate -- dereferencing would crash the process instead.
    try std.testing.expectEqualStrings("", conv.slice(null, 0));
    try std.testing.expectEqualStrings("", conv.slice(null, 1));
    try std.testing.expectEqualStrings("", conv.slice(null, 1 << 20));
}

test "slice: preserves arbitrary bytes, including NUL and 0xFF" {
    const raw = [_]u8{ 0x00, 0xFF, 0x41, 0x00, 0x80 };
    const got = conv.slice(&raw, raw.len);
    try std.testing.expectEqualSlices(u8, &raw, got);
}

test "sliceMut: mirrors slice but stays writable" {
    var buf = [_]u8{ 'a', 'b', 'c' };
    const got = conv.sliceMut(&buf, buf.len);
    got[1] = 'Z';
    try std.testing.expectEqualStrings("aZc", &buf);
    try std.testing.expectEqual(@as(usize, 0), conv.sliceMut(null, 3).len);
}

test "span: reads NUL-terminated strings and tolerates null" {
    try std.testing.expectEqualStrings("", conv.span(null));
    try std.testing.expectEqualStrings("abc", conv.span("abc"));
    try std.testing.expectEqualStrings("", conv.span(""));

    // Stops at the first NUL.
    const raw = [_:0]u8{ 'x', 'y', 0, 'z' };
    try std.testing.expectEqualStrings("xy", conv.span(&raw));
}

test "str: views a lexbor_str_t without over-reading" {
    var bytes = [_]u8{ 'a', 'b', 'c', 'd', 0 };
    const value = c.lexbor_str_t{ .data = &bytes, .length = 3 };
    try std.testing.expectEqualStrings("abc", conv.str(value));

    const exact = c.lexbor_str_t{ .data = &bytes, .length = 4 };
    try std.testing.expectEqualStrings("abcd", conv.str(exact));

    const empty = c.lexbor_str_t{ .data = null, .length = 0 };
    try std.testing.expectEqualStrings("", conv.str(empty));
}

test "ptr/ptrMut round-trip through slice" {
    const bytes = "roundtrip";
    try std.testing.expectEqualStrings(bytes, conv.slice(conv.ptr(bytes), bytes.len));

    var mutable = [_]u8{ 'a', 'b' };
    const view = conv.sliceMut(conv.ptrMut(&mutable), mutable.len);
    view[0] = 'Z';
    try std.testing.expectEqualStrings("Zb", &mutable);
}

test "ptr of an empty slice is usable with length 0" {
    const empty: []const u8 = &.{};
    const p = conv.ptr(empty);
    // Must not crash even though there is nothing to point at.
    try std.testing.expectEqualStrings("", conv.slice(p, 0));
}

test "STRESS: conversions stay consistent over a large byte range" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 4096);
    defer gpa.free(buf);

    var i: usize = 0;
    while (i < buf.len) : (i += 1) buf[i] = @truncate(i *% 31 +% 7);

    var len: usize = 0;
    while (len <= buf.len) : (len += 37) {
        const got = conv.slice(buf.ptr, len);
        try std.testing.expectEqual(len, got.len);
        try std.testing.expectEqualSlices(u8, buf[0..len], got);
    }
}
