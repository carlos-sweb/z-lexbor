//! Building a DOM from scratch, without parsing.
//!
//! This covers the path that `lxb_html_document_create()` opens: an empty
//! document whose tree is assembled by hand. It is a different code path from
//! parsing, and notably it does **not** populate `document.element`, so the
//! `rootElement` fallback is exercised here too.

const std = @import("std");
const lexbor = @import("z_lexbor");
const dom = lexbor.dom;
const html = lexbor.html;

fn serialize(document: html.OwnedDocument, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try document.serializeTo(&w);
    return std.Io.Writer.buffered(&w);
}

test "a fresh document is genuinely empty" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    try std.testing.expectEqual(@as(?dom.Element, null), document.rootElement());
    try std.testing.expectEqual(@as(?dom.Node, null), document.documentNode().firstChild());

    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NoRootElement, serialize(document, &buf));
}

test "builds the classic html/head/link/body/h1 tree from scratch" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");

    const head = try root.appendElement("head");
    const link = try head.appendElement("link");
    try link.setAttribute("rel", "stylesheet");
    try link.setAttribute("href", "style.css");

    const body = try root.appendElement("body");
    const h1 = try body.appendElement("h1");
    _ = try h1.appendText("Hello world");

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<html><head><link rel=\"stylesheet\" href=\"style.css\"></head>" ++
            "<body><h1>Hello world</h1></body></html>",
        try serialize(document, &buf),
    );
}

test "rootElement falls back to the first element child" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    // The parser caches the root in `document.element`; building by hand does
    // not, so this asserts the fallback actually works.
    // Access the raw field: this is the whole point of the fallback.
    try std.testing.expect(document.ptr.*.dom_document.element == null);

    const root = try document.appendElement("html");
    try std.testing.expectEqual(root.raw(), document.rootElement().?.raw());

    const home = document.rootElement().?;
    try std.testing.expectEqualStrings("html", home.localName());
}

test "created nodes are usable handles" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");
    try std.testing.expect(root.raw() != null);
    try std.testing.expectEqualStrings("html", root.localName());
    try std.testing.expectEqual(dom.NodeType.element, root.node().nodeType().?);
    try std.testing.expectEqual(root.node().raw(), document.rootElement().?.node().raw());
}

test "a detached element is created but not attached" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");

    const detached = try document.createElement("span");
    try std.testing.expectEqualStrings("span", detached.localName());
    // It exists, but nothing points at it yet.
    try std.testing.expectEqual(@as(?dom.Node, null), detached.node().parent());

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("<html></html>", try serialize(document, &buf));

    // Attaching it makes it visible.
    try root.appendChild(detached.node());
    try std.testing.expectEqualStrings("<html><span></span></html>", try serialize(document, &buf));
}

test "appendChild moves an existing node into the tree" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");
    const body = try root.appendElement("body");

    const text = try document.createTextNode("from another parent");
    try body.appendChild(text);

    try std.testing.expectEqualStrings("from another parent", body.textContent());

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<html><body>from another parent</body></html>",
        try serialize(document, &buf),
    );
}

test "text and element children keep document order" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("div");
    _ = try root.appendText("a");
    _ = try root.appendElement("b");
    _ = try root.appendText("c");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("<div>a<b></b>c</div>", try serialize(document, &buf));

    var children: usize = 0;
    var it = root.children();
    while (it.next()) |_| children += 1;
    try std.testing.expectEqual(@as(usize, 3), children);
}

test "attributes can be set, read and removed on built elements" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("a");
    try root.setAttribute("href", "/one");
    try std.testing.expectEqualStrings("/one", root.getAttribute("href").?);
    try std.testing.expect(root.hasAttribute("href"));

    try root.setAttribute("href", "/two");
    try std.testing.expectEqualStrings("/two", root.getAttribute("href").?);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("<a href=\"/two\"></a>", try serialize(document, &buf));

    try root.removeAttribute("href");
    try std.testing.expectEqual(@as(?[]const u8, null), root.getAttribute("href"));
}

test "an empty text node round-trips safely" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("p");
    _ = try root.appendText("");

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("<p></p>", try serialize(document, &buf));
}

test "teardown of a hand-built document is idempotent" {
    var document = try html.OwnedDocument.create();
    _ = try document.appendElement("html");
    document.deinit();
    document.deinit();
    try std.testing.expect(document.ptr == null);
}

test "selectors work on a hand-built document" {
    const gpa = std.testing.allocator;

    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");
    const body = try root.appendElement("body");

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const li = try body.appendElement("li");
        li.node().appendChildUnchecked(try document.createTextNode("item"));

        var buf: [16]u8 = undefined;
        try li.setAttribute("data-i", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    }

    var engine = try lexbor.selectors.Engine.createInit();
    defer engine.deinit();

    var found = try engine.queryAll(gpa, document.rootElement().?.node(), "li");
    defer found.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expectEqualStrings("item", found.items[1].textContent());
    try std.testing.expectEqualStrings("2", found.items[2].asElement().?.getAttribute("data-i").?);
}

test "a hand-built document serializes to something that parses back identically" {
    const gpa = std.testing.allocator;

    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");
    const head = try root.appendElement("head");
    _ = try head.appendElement("title");
    const body = try root.appendElement("body");
    const p = try body.appendElement("p");
    _ = try p.appendText("round trip");

    const first = try gpa.alloc(u8, 1024);
    defer gpa.free(first);
    const built = try serialize(document, first);

    var parser = try html.Parser.createInit();
    defer parser.deinit();
    const reparsed = try parser.parse(built);

    const second = try gpa.alloc(u8, 1024);
    defer gpa.free(second);
    var w = std.Io.Writer.fixed(second);
    try html.serializeDocument(reparsed, &w);

    // Parsing adds the implied <head>/<body> structure, so compare the trees
    // through the DOM rather than raw text.
    const reparsed_root = reparsed.rootElement().?;
    try std.testing.expectEqualStrings("html", reparsed_root.localName());

    var engine = try lexbor.selectors.Engine.createInit();
    defer engine.deinit();

    var ps = try engine.queryAll(gpa, reparsed_root.node(), "p");
    defer ps.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), ps.items.len);
    try std.testing.expectEqualStrings("round trip", ps.items[0].textContent());
}

test "BREAK: appending across documents silently moves the node" {
    var a = try html.OwnedDocument.create();
    defer a.deinit();
    var b = try html.OwnedDocument.create();
    defer b.deinit();

    const root_a = try a.appendElement("html");
    const root_b = try b.appendElement("html");

    // lexbor accepts a node from another document and *moves* it. No error is
    // raised, so this documents the real behaviour rather than assuming a
    // WRONG_DOCUMENT_ERR-style rejection.
    try root_b.appendChild(root_a.node());

    // Document `a` is left without a root...
    try std.testing.expectEqual(@as(?dom.Element, null), a.rootElement());
    var buf_a: [256]u8 = undefined;
    try std.testing.expectError(error.NoRootElement, serialize(a, &buf_a));

    // ...and document `b` still serializes, with the moved tree nested inside.
    var buf_b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<html><html></html></html>",
        try serialize(b, &buf_b),
    );
}

test "BREAK: an empty element name is rejected before lexbor sees it" {
    // Regression guard for a real lexbor defect: a zero-length name makes
    // lexbor_shs_entry_get_lower_static underflow (core/shs.c), aborting under
    // safety checks. The wrapper rejects it instead.
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    try std.testing.expectError(error.InvalidName, document.createElement(""));

    // The document is unharmed and still usable.
    const ok = try document.appendElement("html");
    try std.testing.expectEqualStrings("html", ok.localName());
}

test "BREAK: creating an element with a one-byte name never traps" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const names = [_][]const u8{ " ", "<", "\"", "-", "\x00", "\xc3" };
    for (names) |n| {
        const el = document.createElement(n) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        _ = el.localName();
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        lexbor.html.serialize(el.node(), &w) catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
        };
    }
}

test "BREAK: creating an element with a very long name never traps" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    var long_name: [4096]u8 = undefined;
    @memset(&long_name, 'a');

    const el = try document.createElement(&long_name);
    _ = el.localName();

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    lexbor.html.serialize(el.node(), &w) catch |err| {
        try std.testing.expectEqual(error.WriteFailed, err);
    };
}

test "STRESS: a wide, deep tree built by hand" {
    var document = try html.OwnedDocument.create();
    defer document.deinit();

    const root = try document.appendElement("html");
    const body = try root.appendElement("body");

    // 50 rows x 20 cells = 1000 elements.
    var row: usize = 0;
    while (row < 50) : (row += 1) {
        const tr = try body.appendElement("tr");
        var col: usize = 0;
        while (col < 20) : (col += 1) {
            const td = try tr.appendElement("td");
            _ = try td.appendText("x");
        }
    }

    var count: usize = 0;
    var it = document.rootElement().?.node().descendants();
    while (it.next()) |_| count += 1;

    // html + body + 50 tr + 1000 td + 1000 text nodes.
    try std.testing.expectEqual(2052, count);

    const gpa = std.testing.allocator;
    var engine = try lexbor.selectors.Engine.createInit();
    defer engine.deinit();

    var cells = try engine.queryAll(gpa, body.node(), "td");
    defer cells.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1000), cells.items.len);
}
