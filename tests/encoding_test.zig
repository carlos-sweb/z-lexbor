//! WHATWG encoding lookup tests.

const std = @import("std");
const lexbor = @import("z_lexbor");
const encoding = lexbor.encoding;

test "resolves the encodings a parser actually needs" {
    const cases = [_]struct { label: []const u8, canonical: []const u8 }{
        .{ .label = "utf-8", .canonical = "utf-8" },
        .{ .label = "UTF-8", .canonical = "utf-8" },
        .{ .label = "latin1", .canonical = "windows-1252" },
        .{ .label = "iso-8859-1", .canonical = "windows-1252" },
        .{ .label = "ascii", .canonical = "windows-1252" },
        .{ .label = "utf-16le", .canonical = "utf-16le" },
        .{ .label = "utf-16be", .canonical = "utf-16be" },
        .{ .label = "shift_jis", .canonical = "shift_jis" },
        .{ .label = "euc-kr", .canonical = "euc-kr" },
        .{ .label = "gbk", .canonical = "gbk" },
        .{ .label = "big5", .canonical = "big5" },
        .{ .label = "koi8-r", .canonical = "koi8-r" },
    };

    for (cases) |case| {
        const enc = encoding.byName(case.label) orelse {
            std.debug.print("encoding not found: {s}\n", .{case.label});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(std.ascii.eqlIgnoreCase(case.canonical, encoding.name(enc)));
    }
}

test "label lookup is case-insensitive" {
    const variants = [_][]const u8{ "utf-8", "UTF-8", "Utf-8", "uTf-8" };
    for (variants) |label| {
        const enc = encoding.byName(label) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.ascii.eqlIgnoreCase("utf-8", encoding.name(enc)));
    }
}

test "unknown labels return null instead of erroring" {
    const unknown = [_][]const u8{
        "definitely-not-an-encoding",
        "utf-9",
        "banana",
        "  utf-8  ",
        "utf 8",
    };

    for (unknown) |label| {
        try std.testing.expectEqual(@as(?encoding.Encoding, null), encoding.byName(label));
    }
}

test "BREAK: empty and pathological labels never crash" {
    const empty = encoding.byName("");
    try std.testing.expectEqual(@as(?encoding.Encoding, null), empty);

    // A label far longer than any real one.
    const gpa = std.testing.allocator;
    const long = try gpa.alloc(u8, 100_000);
    defer gpa.free(long);
    @memset(long, 'x');

    try std.testing.expectEqual(@as(?encoding.Encoding, null), encoding.byName(long));
}

test "BREAK: labels containing NUL or high bytes never crash" {
    const nasty = [_][]const u8{
        "\x00",
        "utf\x00-8",
        "\xff\xfe",
        "utf-8\xff",
    };

    for (nasty) |label| {
        // Must return something or null, never trap.
        _ = encoding.byName(label);
    }
}

test "raw() exposes the underlying lexbor encoding data" {
    const enc = encoding.byName("utf-8") orelse return error.TestUnexpectedResult;
    try std.testing.expect(enc.raw() != null);
}
