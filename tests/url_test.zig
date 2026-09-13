//! WHATWG URL parsing and serialization tests.

const std = @import("std");
const lexbor = @import("z_lexbor");

fn serialize(url: lexbor.url.Url, buf: []u8, exclude_fragment: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try url.serialize(&w, exclude_fragment);
    return std.Io.Writer.buffered(&w);
}

test "absolute URLs round-trip" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const cases = [_][]const u8{
        "https://example.com/",
        "http://example.com/a/b/c",
        "https://example.com:8080/path",
        "https://example.com/path?query=1&x=2",
        "https://example.com/path#fragment",
        "https://user@example.com/path",
        "ftp://files.example.com/pub",
        "file:///tmp/x",
    };

    for (cases) |input| {
        const url = try parser.parse(null, input);
        var buf: [512]u8 = undefined;
        const out = try serialize(url, &buf, false);
        try std.testing.expectEqualStrings(input, out);
    }
}

test "exclude_fragment strips only the fragment" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const url = try parser.parse(null, "https://example.com/a?b=1#frag");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.com/a?b=1",
        try serialize(url, &buf, true),
    );
}

test "relative URLs resolve against a base" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const base = try parser.parse(null, "https://example.com/dir/page.html");

    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "other.html", .want = "https://example.com/dir/other.html" },
        .{ .input = "../up.html", .want = "https://example.com/up.html" },
        .{ .input = "/root.html", .want = "https://example.com/root.html" },
        .{ .input = "?q=1", .want = "https://example.com/dir/page.html?q=1" },
        .{ .input = "//other.host/x", .want = "https://other.host/x" },
        .{ .input = "https://absolute.example/y", .want = "https://absolute.example/y" },
    };

    for (cases) |case| {
        const url = try parser.parse(base, case.input);
        var buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings(case.want, try serialize(url, &buf, false));
    }
}

test "parseTo writes straight into a writer" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try parser.parseTo(null, "https://example.com/x", &w);
    try std.testing.expectEqualStrings("https://example.com/x", std.Io.Writer.buffered(&w));
}

test "default ports are normalized away" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const url = try parser.parse(null, "https://example.com:443/x");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/x", try serialize(url, &buf, false));
}

test "unicode hosts are IDNA-encoded" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const url = try parser.parse(null, "https://caf\u{e9}.example/\u{1f600}");
    var buf: [256]u8 = undefined;
    const out = try serialize(url, &buf, false);

    // The host must have been punycode-encoded.
    try std.testing.expect(std.mem.indexOf(u8, out, "xn--") != null);
}

test "BREAK: invalid URLs return an error instead of trapping" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const invalid = [_][]const u8{
        "not a url",
        "//",
        "http://",
        "https://",
        "",
        " ",
        ":",
        "::::",
    };

    for (invalid) |input| {
        if (parser.parse(null, input)) |url| {
            // Tolerant: it produced something, but it must be serializable.
            var buf: [256]u8 = undefined;
            _ = try serialize(url, &buf, false);
        } else |err| {
            try std.testing.expectEqual(error.LexborError, err);
        }
    }
}

test "BREAK: a very long URL does not overflow" {
    const gpa = std.testing.allocator;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);

    try input.appendSlice(gpa, "https://example.com/");
    var i: usize = 0;
    while (i < 20_000) : (i += 1) try input.append(gpa, 'a' + @as(u8, @intCast(i % 26)));

    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const url = try parser.parse(null, input.items);
    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    const out = try serialize(url, buf, false);
    try std.testing.expect(out.len >= input.items.len);
}

test "BREAK: strings full of separators and escapes" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    const nasty = [_][]const u8{
        "https://example.com/%%%",
        "https://example.com/../../../../etc/passwd",
        "https://example.com/#\\",
        "https://ex ample.com/",
        "https://example.com/\x00\x01\x02",
        "https://[::1]:8080/x",
        "https://example.com/?a=%00&b=%ff",
    };

    for (nasty) |input| {
        if (parser.parse(null, input)) |url| {
            var buf: [512]u8 = undefined;
            _ = try serialize(url, &buf, false);
        } else |err| {
            try std.testing.expectEqual(error.LexborError, err);
        }
    }
}

test "STRESS: 300 parses on one parser" {
    var parser = try lexbor.url.Parser.createInit();
    defer parser.deinit();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var input: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&input, "https://example.com/p{d}?q={d}", .{ i, i });

        const url = try parser.parse(null, s);
        var buf: [128]u8 = undefined;
        try std.testing.expectEqualStrings(s, try serialize(url, &buf, false));
    }
}
