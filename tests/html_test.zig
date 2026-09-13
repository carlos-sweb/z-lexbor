//! HTML parsing, document structure and serialization tests.

const std = @import("std");
const lexbor = @import("z_lexbor");
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

fn serialize(doc: *const harness.Doc, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try lexbor.html.serializeDocument(doc.document, &w);
    return std.Io.Writer.buffered(&w);
}

test "parser creates, initializes and destroys" {
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();
    try std.testing.expect(parser.raw() != null);

    // create() + init() separately is equivalent.
    var manual = try lexbor.html.Parser.create();
    defer manual.deinit();
    try manual.init();
    try std.testing.expect(manual.raw() != null);
}

test "parsing an empty document still yields a full tree" {
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("");
    const root = doc.rootNode().?;
    try std.testing.expectEqualStrings("html", root.asElement().?.localName());
    try std.testing.expect(root.asElement().?.firstChild() != null);
}

test "parsing normalizes a fragment into a complete document" {
    const gpa = std.testing.allocator;

    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<div id=\"x\">hi</div>");

    const buf = try gpa.alloc(u8, 256);
    defer gpa.free(buf);

    var w = std.Io.Writer.fixed(buf);
    try lexbor.html.serializeDocument(doc, &w);

    try std.testing.expectEqualStrings(
        "<html><head></head><body><div id=\"x\">hi</div></body></html>",
        std.Io.Writer.buffered(&w),
    );
}

test "serialization round-trips a full document" {
    var doc = try harness.Doc.init("<div id=\"x\"><p>Hello <b>world</b></p></div>");
    defer doc.deinit();

    var buf: [256]u8 = undefined;
    const out = try serialize(&doc, &buf);
    try std.testing.expectEqualStrings(
        "<html><head></head><body><div id=\"x\"><p>Hello <b>world</b></p></div></body></html>",
        out,
    );
}

test "serialization is stable: parse -> serialize -> parse -> serialize" {
    const gpa = std.testing.allocator;

    var parser1 = try lexbor.html.Parser.createInit();
    defer parser1.deinit();
    const doc1 = try parser1.parse(fixtures.page);

    const buf1 = try gpa.alloc(u8, 8192);
    defer gpa.free(buf1);
    var w1 = std.Io.Writer.fixed(buf1);
    try lexbor.html.serializeDocument(doc1, &w1);
    const first = std.Io.Writer.buffered(&w1);

    var parser2 = try lexbor.html.Parser.createInit();
    defer parser2.deinit();
    const doc2 = try parser2.parse(first);

    const buf2 = try gpa.alloc(u8, 8192);
    defer gpa.free(buf2);
    var w2 = std.Io.Writer.fixed(buf2);
    try lexbor.html.serializeDocument(doc2, &w2);
    const second = std.Io.Writer.buffered(&w2);

    try std.testing.expectEqualStrings(first, second);
}

test "document title is extracted" {
    var doc = try harness.Doc.init("<title>My Page</title><p>x</p>");
    defer doc.deinit();

    try std.testing.expectEqualStrings("My Page", doc.document.title().?);
}

test "document without a title returns null" {
    var doc = try harness.Doc.init("<p>no title here</p>");
    defer doc.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), doc.document.title());
}

test "doctype, comments and raw-text elements survive parsing" {
    var doc = try harness.Doc.init(fixtures.mixed_page);
    defer doc.deinit();

    var saw_comment = false;
    var saw_script = false;
    var saw_style = false;

    var it = doc.root().descendants();
    while (it.next()) |node| {
        switch (node.nodeType() orelse continue) {
            .comment => saw_comment = true,
            .element => {
                const el = node.asElement().?;
                if (std.mem.eql(u8, el.localName(), "script")) saw_script = true;
                if (std.mem.eql(u8, el.localName(), "style")) saw_style = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_comment);
    try std.testing.expect(saw_script);
    try std.testing.expect(saw_style);
}

test "script and style contents are preserved verbatim" {
    var doc = try harness.Doc.init(fixtures.mixed_page);
    defer doc.deinit();

    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 4096);
    defer gpa.free(buf);

    const out = try serialize(&doc, buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "var x = 1 < 2 && \"a\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".a > b { color: red }") != null);
}

test "unicode content is preserved through parse and serialize" {
    var doc = try harness.Doc.init(fixtures.unicode_page);
    defer doc.deinit();

    const el = (try doc.first("#u")).?.asElement().?;
    try std.testing.expectEqualStrings("caf\u{e9} \u{1f600} \u{4e2d}\u{6587} \u{fc}", el.textContent());

    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 1024);
    defer gpa.free(buf);
    const out = try serialize(&doc, buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "caf\u{e9}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{1f600}") != null);
}

test "character references are decoded" {
    var doc = try harness.Doc.init("<p id=p>a &amp; b &lt;c&gt; &#65;</p>");
    defer doc.deinit();

    const p = (try doc.first("#p")).?.asElement().?;
    try std.testing.expectEqualStrings("a & b <c> A", p.textContent());
}

test "malformed input still produces a usable tree" {
    const broken = [_][]const u8{
        "<div><p>unclosed",
        "</div>",
        "<b><i>mismatched</b></i>",
        "<p><p><p>",
        "plain text without tags",
        "<<<>>>",
        "<div class=>",
        "<div ='x'>",
    };

    for (broken) |input| {
        var doc = try harness.Doc.init(input);
        defer doc.deinit();

        try std.testing.expect(doc.rootNode() != null);
        try std.testing.expectEqualStrings("html", doc.root().asElement().?.localName());
    }
}

test "serialization of a detached subtree works without a document" {
    var doc = try harness.Doc.init("<div><p id=only>solo</p></div>");
    defer doc.deinit();

    const p = (try doc.first("#only")).?;

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try lexbor.html.serialize(p, &w);

    try std.testing.expectEqualStrings("<p id=\"only\">solo</p>", std.Io.Writer.buffered(&w));
}

test "STRESS: many sequential parses on one parser stay independent" {
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var html_buf: [64]u8 = undefined;
        var want_buf: [16]u8 = undefined;

        const html = try std.fmt.bufPrint(&html_buf, "<p>{d}</p>", .{i});
        const want = try std.fmt.bufPrint(&want_buf, "{d}", .{i});

        const doc = try parser.parse(html);

        var found = false;
        var it = doc.rootNode().?.descendants();
        while (it.next()) |node| {
            if (node.asElement()) |el| {
                if (std.mem.eql(u8, el.localName(), "p")) {
                    try std.testing.expectEqualStrings(want, el.textContent());
                    found = true;
                    break;
                }
            }
        }
        try std.testing.expect(found);
    }
}
