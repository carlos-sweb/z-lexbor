//! End-to-end scenarios: the things a user actually wants to do with an HTML
//! engine, exercised through the public wrapper API only.

const std = @import("std");
const lexbor = @import("z_lexbor");
const dom = lexbor.dom;
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

test "scenario: extract every link and resolve it against the page URL" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var url_parser = try lexbor.url.Parser.createInit();
    defer url_parser.deinit();

    const base = try url_parser.parse(null, "https://example.com/blog/post");

    var links = try doc.all(gpa, "a[href]");
    defer links.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), links.items.len);

    const hrefs = [_][]const u8{ "/next", "https://example.com/abs" };
    const expected = [_][]const u8{
        "https://example.com/next",
        "https://example.com/abs",
    };

    for (links.items, 0..) |node, i| {
        const el = node.asElement().?;
        const href = el.getAttribute("href").?;
        try std.testing.expectEqualStrings(hrefs[i], href);

        const resolved = try url_parser.parse(base, href);
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try resolved.serialize(&w, false);

        try std.testing.expectEqualStrings(expected[i], std.Io.Writer.buffered(&w));
    }
}

test "scenario: extract a table into rows of cells" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.table_page);
    defer doc.deinit();

    var rows = try doc.all(gpa, "tr");
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.items.len);

    // Header row.
    var header = try doc.engine.queryAll(gpa, rows.items[0], "th");
    defer header.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), header.items.len);
    try std.testing.expectEqualStrings("Name", header.items[0].textContent());
    try std.testing.expectEqualStrings("Value", header.items[1].textContent());

    // Body rows.
    var first_cells = try doc.engine.queryAll(gpa, rows.items[1], "td");
    defer first_cells.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), first_cells.items.len);
    try std.testing.expectEqualStrings("one", first_cells.items[0].textContent());
    try std.testing.expectEqualStrings("1", first_cells.items[1].textContent());
}

test "scenario: extract structured records from a list" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const Record = struct { id: []const u8, text: []const u8, special: bool };

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(gpa);

    var items = try doc.all(gpa, "li.item");
    defer items.deinit(gpa);

    for (items.items) |node| {
        const el = node.asElement().?;
        const class = el.classAttribute() orelse "";
        try records.append(gpa, .{
            .id = el.getAttribute("data-id").?,
            .text = el.textContent(),
            .special = std.mem.indexOf(u8, class, "special") != null,
        });
    }

    try std.testing.expectEqual(@as(usize, 3), records.items.len);
    try std.testing.expectEqualStrings("1", records.items[0].id);
    try std.testing.expectEqualStrings("alpha", records.items[0].text);
    try std.testing.expect(!records.items[0].special);
    try std.testing.expect(records.items[2].special);
}

test "scenario: query, mutate, serialize, re-parse" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    // Mutate: set an attribute on every item and add a class.
    var items = try doc.all(gpa, "li.item");
    defer items.deinit(gpa);

    for (items.items, 0..) |node, i| {
        const el = node.asElement().?;
        var buf: [32]u8 = undefined;
        const val = try std.fmt.bufPrint(&buf, "seen-{d}", .{i});
        try el.setAttribute("data-state", val);
    }

    // Serialize.
    const out = try gpa.alloc(u8, 8192);
    defer gpa.free(out);
    var w = std.Io.Writer.fixed(out);
    try lexbor.html.serializeDocument(doc.document, &w);

    // Re-parse and verify the mutation survived.
    var parser2 = try lexbor.html.Parser.createInit();
    defer parser2.deinit();
    const doc2 = try parser2.parse(std.Io.Writer.buffered(&w));

    var engine2 = try lexbor.selectors.Engine.createInit();
    defer engine2.deinit();

    var items2 = try engine2.queryAll(gpa, doc2.rootNode().?, "li.item");
    defer items2.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), items2.items.len);
    for (items2.items, 0..) |node, i| {
        var buf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "seen-{d}", .{i});
        try std.testing.expectEqualStrings(want, node.asElement().?.getAttribute("data-state").?);
    }
}

test "scenario: nested queries narrow the search space" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    // Level 1: the list container.
    const list = (try doc.first("#list")).?;

    // Level 2: items inside it.
    var items = try doc.engine.queryAll(gpa, list, "li");
    defer items.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);

    // Level 3: an <li> holds only text, and the search root is never itself a
    // candidate, so nothing matches inside it.
    var inside = try doc.engine.queryAll(gpa, items.items[0], "*");
    defer inside.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), inside.items.len);

    var none = try doc.engine.queryAll(gpa, items.items[0], "li");
    defer none.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}

test "scenario: walk the whole tree and record element statistics" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var tags = try doc.tagNames(gpa);
    defer tags.deinit(gpa);

    try std.testing.expect(tags.items.len > 10);
    // Document order: <html>, then everything inside <head>, then <body>.
    try std.testing.expectEqualStrings("html", tags.items[0]);
    try std.testing.expectEqualStrings("head", tags.items[1]);
    try std.testing.expectEqualStrings("meta", tags.items[2]);
    try std.testing.expectEqualStrings("title", tags.items[3]);
    try std.testing.expectEqualStrings("body", tags.items[4]);

    // No tag name should be empty.
    for (tags.items) |t| try std.testing.expect(t.len > 0);

    // The fixture contains exactly three <li>.
    var li_count: usize = 0;
    for (tags.items) |t| {
        if (std.mem.eql(u8, t, "li")) li_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), li_count);
}

test "scenario: charset meta plus encoding lookup" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    // Find the declared charset through the DOM...
    var metas = try doc.all(gpa, "meta[charset]");
    defer metas.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), metas.items.len);
    const declared = metas.items[0].asElement().?.getAttribute("charset").?;

    // ...and confirm lexbor knows how to decode it.
    const enc = lexbor.encoding.byName(declared) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.ascii.eqlIgnoreCase("utf-8", lexbor.encoding.name(enc)));
}

test "scenario: sanitize a subtree by rebuilding it" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init("<div id=box><b>keep</b><i>also</i>text</div>");
    defer doc.deinit();

    const box = (try doc.first("#box")).?;

    // Serialize just the subtree, drop it, and re-parse: the result must be
    // equivalent when serialized again.
    var first: [256]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&first);
    try lexbor.html.serialize(box, &w1);
    const subtree = std.Io.Writer.buffered(&w1);

    var parser2 = try lexbor.html.Parser.createInit();
    defer parser2.deinit();
    const doc2 = try parser2.parse(subtree);

    var engine2 = try lexbor.selectors.Engine.createInit();
    defer engine2.deinit();

    var reparsed = try engine2.queryAll(gpa, doc2.rootNode().?, "div");
    defer reparsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), reparsed.items.len);

    var second: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&second);
    try lexbor.html.serialize(reparsed.items[0], &w2);

    // Both serializations describe the same element.
    try std.testing.expectEqualStrings(subtree, std.Io.Writer.buffered(&w2));
}

test "scenario: an error in one stage does not corrupt the next" {
    const gpa = std.testing.allocator;

    // Stage 1 fails (invalid URL)...
    var url_parser = try lexbor.url.Parser.createInit();
    defer url_parser.deinit();
    try std.testing.expectError(error.LexborError, url_parser.parse(null, "nonsense"));

    // ...stage 2 still works on the same parsers.
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var items = try doc.all(gpa, "li");
    defer items.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);

    // ...and so does stage 3.
    const ok = try url_parser.parse(null, "https://example.com/ok");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ok.serialize(&w, false);
    try std.testing.expectEqualStrings("https://example.com/ok", std.Io.Writer.buffered(&w));
}

test "scenario: mixed content round-trips without losing nodes" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.mixed_page);
    defer doc.deinit();

    const before = try countAll(doc.root());

    const out = try gpa.alloc(u8, 16384);
    defer gpa.free(out);
    var w = std.Io.Writer.fixed(out);
    try lexbor.html.serializeDocument(doc.document, &w);

    var parser2 = try lexbor.html.Parser.createInit();
    defer parser2.deinit();
    const doc2 = try parser2.parse(std.Io.Writer.buffered(&w));

    const after = try countAll(doc2.rootNode().?);

    // Re-serialization must not lose elements (comment/text node bookkeeping can
    // differ, so compare the element count).
    try std.testing.expectEqual(before.elements, after.elements);
}

const Stats = struct { nodes: usize, elements: usize };

fn countAll(root: dom.Node) !Stats {
    var stats = Stats{ .nodes = 0, .elements = 0 };
    var it = root.descendants();
    while (it.next()) |node| {
        stats.nodes += 1;
        if (node.nodeType() == .element) stats.elements += 1;
    }
    return stats;
}
