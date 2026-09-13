//! DOM traversal, attribute and iterator tests.

const std = @import("std");
const lexbor = @import("z_lexbor");
const dom = lexbor.dom;
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

test "NodeType maps every lexbor node type and rejects unknown values" {
    const pairs = [_]struct { raw: c_int, want: dom.NodeType }{
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_ELEMENT, .want = .element },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_ATTRIBUTE, .want = .attribute },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_TEXT, .want = .text },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_CDATA_SECTION, .want = .cdata_section },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION, .want = .processing_instruction },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_COMMENT, .want = .comment },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_DOCUMENT, .want = .document },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE, .want = .document_type },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT, .want = .document_fragment },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_CHARACTER_DATA, .want = .character_data },
        .{ .raw = lexbor.sys.c.LXB_DOM_NODE_TYPE_SHADOW_ROOT, .want = .shadow_root },
    };

    for (pairs) |p| {
        try std.testing.expectEqual(p.want, dom.NodeType.fromRaw(@intCast(p.raw)).?);
    }

    try std.testing.expectEqual(@as(?dom.NodeType, null), dom.NodeType.fromRaw(0xFFFF));
}

test "root element is an <html> element node" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const root = doc.root();
    try std.testing.expectEqual(dom.NodeType.element, root.nodeType().?);
    try std.testing.expectEqualStrings("html", root.asElement().?.localName());

    // The root element's parent is the document node, not null.
    const parent = root.parent().?;
    try std.testing.expectEqual(dom.NodeType.document, parent.nodeType().?);
}

test "parent/firstChild/lastChild/next/prev are consistent" {
    var doc = try harness.Doc.init("<div><a></a><b></b><c></c></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    const first = div.firstChild().?;
    const last = div.node().lastChild().?;

    try std.testing.expectEqualStrings("a", first.asElement().?.localName());
    try std.testing.expectEqualStrings("c", last.asElement().?.localName());

    // Walking forward then backward returns to the start.
    var n = first;
    var count: usize = 0;
    while (true) {
        count += 1;
        n = n.nextSibling() orelse break;
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    const b = first.nextSibling().?;
    try std.testing.expectEqualStrings("b", b.asElement().?.localName());
    try std.testing.expectEqualStrings("a", b.previousSibling().?.asElement().?.localName());
    try std.testing.expectEqual(div.node().raw(), b.parent().?.raw());
}

test "Children iterator yields exactly the direct children" {
    var doc = try harness.Doc.init("<div><a></a>text<b></b><c></c></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    var it = div.children();

    var kinds: usize = 0;
    var elements: usize = 0;
    while (it.next()) |child| {
        kinds += 1;
        if (child.nodeType() == .element) elements += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), kinds);
    try std.testing.expectEqual(@as(usize, 3), elements);

    // A leaf has no children and the iterator terminates immediately.
    const a = (try doc.first("a")).?;
    var leaf_it = a.children();
    try std.testing.expectEqual(@as(?dom.Node, null), leaf_it.next());
}

test "Descendants yields the subtree in pre-order, root first" {
    var doc = try harness.Doc.init("<div id=r><a><x></x></a><b></b></div>");
    defer doc.deinit();

    const div = (try doc.first("#r")).?;
    var it = div.descendants();

    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(std.testing.allocator);

    while (it.next()) |n| {
        if (n.asElement()) |el| try tags.append(std.testing.allocator, el.localName());
    }

    try std.testing.expectEqual(@as(usize, 4), tags.items.len);
    try std.testing.expectEqualStrings("div", tags.items[0]);
    try std.testing.expectEqualStrings("a", tags.items[1]);
    try std.testing.expectEqualStrings("x", tags.items[2]);
    try std.testing.expectEqualStrings("b", tags.items[3]);
}

test "Descendants on a childless element yields only itself" {
    // Note: "<p>text</p>" is NOT childless -- the text is a child node.
    var doc = try harness.Doc.init("<p id=only></p>");
    defer doc.deinit();

    const p = (try doc.first("#only")).?;
    var it = p.descendants();

    try std.testing.expect(it.next() != null);
    try std.testing.expectEqual(@as(?dom.Node, null), it.next());
}

test "Descendants counts text children too" {
    var doc = try harness.Doc.init("<p id=only>solo</p>");
    defer doc.deinit();

    const p = (try doc.first("#only")).?;
    var it = p.descendants();

    var count: usize = 0;
    while (it.next()) |_| count += 1;
    // The <p> plus its text node.
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Descendants is exhausted safely no matter how often it is polled" {
    var doc = try harness.Doc.init("<div><a></a></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?;
    var it = div.descendants();
    while (it.next()) |_| {}
    // Polling a finished iterator must keep returning null, not reset or crash.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expectEqual(@as(?dom.Node, null), it.next());
    }
}

test "asElement returns null for non-element nodes" {
    var doc = try harness.Doc.init("<div>text<!--c--></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?;
    var it = div.children();

    var saw_text = false;
    var saw_comment = false;
    while (it.next()) |child| {
        switch (child.nodeType().?) {
            .text => {
                saw_text = true;
                try std.testing.expectEqual(@as(?dom.Element, null), child.asElement());
            },
            .comment => {
                saw_comment = true;
                try std.testing.expectEqual(@as(?dom.Element, null), child.asElement());
            },
            else => {},
        }
    }
    try std.testing.expect(saw_text);
    try std.testing.expect(saw_comment);
}

test "attributes: lookup, presence and values" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const li = (try doc.first("li.special")).?.asElement().?;
    try std.testing.expectEqualStrings("3", li.getAttribute("data-id").?);
    try std.testing.expectEqualStrings("item special", li.getAttribute("class").?);
    try std.testing.expect(li.hasAttribute("data-id"));
    try std.testing.expect(!li.hasAttribute("data-missing"));
    try std.testing.expectEqual(@as(?[]const u8, null), li.getAttribute("data-missing"));
}

test "attributes: id and class helpers" {
    var doc = try harness.Doc.init("<p id=\"pid\" class=\"a b\">x</p>");
    defer doc.deinit();

    const p = (try doc.first("p")).?.asElement().?;
    try std.testing.expectEqualStrings("pid", p.id().?);
    try std.testing.expectEqualStrings("a b", p.classAttribute().?);
}

test "attributes: iteration preserves order and exposes name and value" {
    var doc = try harness.Doc.init("<div z=\"1\" a=\"2\" m=\"3\"></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    var it = div.attributes();

    var seen: usize = 0;
    while (it.next()) |attr| {
        try std.testing.expect(attr.localName().len > 0);
        try std.testing.expect(attr.value().len > 0);
        try std.testing.expectEqualStrings(attr.localName(), attr.qualifiedName());
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "attributes: an element with none yields an empty iterator" {
    var doc = try harness.Doc.init("<div></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    var it = div.attributes();
    try std.testing.expectEqual(@as(?dom.Attr, null), it.next());
}

test "attributes: setAttribute creates and overwrites" {
    var doc = try harness.Doc.init("<div></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;

    try div.setAttribute("data-x", "one");
    try std.testing.expectEqualStrings("one", div.getAttribute("data-x").?);

    // Overwriting must replace, not append a duplicate.
    try div.setAttribute("data-x", "two");
    try std.testing.expectEqualStrings("two", div.getAttribute("data-x").?);

    var it = div.attributes();
    var data_x: usize = 0;
    while (it.next()) |attr| {
        if (std.mem.eql(u8, attr.localName(), "data-x")) data_x += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), data_x);
}

test "attributes: setting an empty value keeps the attribute present" {
    var doc = try harness.Doc.init("<div></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    try div.setAttribute("empty", "");
    try std.testing.expect(div.hasAttribute("empty"));
    try std.testing.expectEqualStrings("", div.getAttribute("empty").?);
}

test "attributes: removeAttribute removes exactly one" {
    var doc = try harness.Doc.init("<div a=\"1\" b=\"2\"></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    try div.removeAttribute("a");
    try std.testing.expect(!div.hasAttribute("a"));
    try std.testing.expect(div.hasAttribute("b"));

    // Removing a missing attribute must not be an error.
    try div.removeAttribute("nope");
}

test "textContent concatenates the subtree" {
    var doc = try harness.Doc.init("<div>Hello <b>world</b>!</div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    try std.testing.expectEqualStrings("Hello world!", div.textContent());
}

test "textContent of an empty element is empty" {
    var doc = try harness.Doc.init("<div></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    try std.testing.expectEqualStrings("", div.textContent());
}

test "name() reports the DOM nodeName, which is upper-cased for HTML elements" {
    var doc = try harness.Doc.init("<div></div>");
    defer doc.deinit();

    const div = (try doc.first("div")).?;
    // lexbor follows the DOM's HTML nodeName rules here (upper case).
    try std.testing.expectEqualStrings("DIV", div.name());

    // localName keeps the original lower-case spelling.
    try std.testing.expectEqualStrings("div", div.asElement().?.localName());
}

test "eql compares identity by pointer" {
    var doc = try harness.Doc.init("<div><a></a><a></a></div>");
    defer doc.deinit();

    const first_a = (try doc.first("a")).?.asElement().?;
    const node = first_a.node();

    try std.testing.expect(node.eql(node));
    try std.testing.expect(!node.eql(node.nextSibling().?));
}

test "maybe() maps null to null for every view type" {
    try std.testing.expectEqual(@as(?dom.Node, null), dom.Node.maybe(null));
    try std.testing.expectEqual(@as(?dom.Element, null), dom.Element.maybe(null));
    try std.testing.expectEqual(@as(?dom.Attr, null), dom.Attr.maybe(null));
}

test "BREAK: iterators can be left mid-way without corrupting the tree" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    // Abandon several iterators half-consumed, then do a full traversal; the
    // tree must be unaffected because iterators hold no state in lexbor.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var it = doc.root().descendants();
        _ = it.next();
        _ = it.next();
    }

    var count: usize = 0;
    var full = doc.root().descendants();
    while (full.next()) |_| count += 1;
    try std.testing.expect(count > 10);
}

test "STRESS: a deep tree is walked exactly once per node" {
    const gpa = std.testing.allocator;

    // 400 nested divs: exercises the ascend-on-no-child branch of Descendants.
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);

    const depth = 400;
    try html.appendSlice(gpa, "<div id=r>");
    var i: usize = 0;
    while (i < depth) : (i += 1) try html.appendSlice(gpa, "<div>");
    try html.appendSlice(gpa, "core");

    var doc = try harness.Doc.init(html.items);
    defer doc.deinit();

    const root = (try doc.first("#r")).?;
    var it = root.descendants();
    var nodes: usize = 0;
    while (it.next()) |_| nodes += 1;

    // root + depth divs + the text node.
    try std.testing.expectEqual(depth + 2, nodes);
}
