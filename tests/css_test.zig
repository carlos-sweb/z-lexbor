//! CSS parser (selector list) tests.

const std = @import("std");
const lexbor = @import("z_lexbor");

test "parses a single selector" {
    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    const list = try parser.parseSelectorList("div");
    try std.testing.expect(list.raw() != null);
}

test "parses a comma-separated selector list" {
    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    const list = try parser.parseSelectorList("div.a > p, #id, span[data-x]");
    try std.testing.expect(list.raw() != null);
}

test "parses every selector shape the engine supports" {
    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    const selectors = [_][]const u8{
        "*",
        "div",
        ".cls",
        "#id",
        "div.cls#id",
        "a b",
        "a > b",
        "a + b",
        "a ~ b",
        "li:first-child",
        "li:last-child",
        "li:nth-child(2n+1)",
        "li:not(.x)",
        "[attr]",
        "[attr=value]",
        "[attr~=value]",
        "[attr|=value]",
        "[attr^=value]",
        "[attr$=value]",
        "[attr*=value]",
        "svg|rect",
        "*|*",
        ":is(a, b)",
        ":where(a)",
    };

    for (selectors) |sel| {
        const list = parser.parseSelectorList(sel) catch |err| {
            std.debug.print("selector failed to parse: {s} ({s})\n", .{ sel, @errorName(err) });
            return err;
        };
        try std.testing.expect(list.raw() != null);
    }
}

test "a selector list can be parsed repeatedly on one parser" {
    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const sel = try std.fmt.bufPrint(&buf, "div.c{d}", .{i});
        const list = try parser.parseSelectorList(sel);
        try std.testing.expect(list.raw() != null);
    }
}

test "BREAK: garbage input never crashes the parser" {
    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    const garbage = [_][]const u8{
        "",
        " ",
        "!!!",
        ">>>",
        "[[[[",
        "))))",
        "::",
        "..",
        "##",
        "a,,b",
        ",,",
        "div >",
        "> div",
        ":not(",
        "[attr=",
        "\\",
        "\x00",
        "\xff\xfe",
    };

    for (garbage) |sel| {
        // Either the parser reports an error or it tolerates the input by
        // producing a (possibly partial) list -- but it must never trap.
        if (parser.parseSelectorList(sel)) |list| {
            try std.testing.expect(list.raw() != null);
        } else |err| {
            try std.testing.expectEqual(error.LexborError, err);
        }
    }
}

test "BREAK: a very long selector does not overflow anything" {
    const gpa = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // 2000 descendant combinators.
    try buf.appendSlice(gpa, "div");
    var i: usize = 0;
    while (i < 2000) : (i += 1) try buf.appendSlice(gpa, " div");

    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    if (parser.parseSelectorList(buf.items)) |list| {
        try std.testing.expect(list.raw() != null);
    } else |err| {
        try std.testing.expectEqual(error.LexborError, err);
    }
}

test "BREAK: deeply nested :not() is handled without crashing" {
    const gpa = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const depth = 64;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(gpa, ":not(");
    try buf.appendSlice(gpa, "div");
    i = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(gpa, ")");

    var parser = try lexbor.css.Parser.createInit();
    defer parser.deinit();

    if (parser.parseSelectorList(buf.items)) |list| {
        try std.testing.expect(list.raw() != null);
    } else |err| {
        try std.testing.expectEqual(error.LexborError, err);
    }
}
