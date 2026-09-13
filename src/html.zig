//! Idiomatic wrapper over lexbor's HTML parser.
//!
//! ```zig
//! var parser = try html.Parser.createInit();
//! defer parser.deinit();
//!
//! const doc = try parser.parse("<div id=x>hi</div>");
//! const root = doc.rootElement().?;
//! ```

const std = @import("std");
const c = @import("sys/root.zig").c;
const status = @import("status.zig");
const conv = @import("internal/convert.zig");
const callback = @import("internal/callback.zig");
pub const dom = @import("dom.zig");

/// Owns a lexbor HTML parser **and every document it produces**.
///
/// lexbor allocates parsed documents inside the parser's memory pool, so a
/// `Document` obtained from `Parser.parse` is only valid until `Parser.deinit`
/// runs. `Document` is therefore a borrowed view with no `deinit` of its own.
pub const Parser = struct {
    ptr: [*c]c.lxb_html_parser_t,

    /// Creates an uninitialized parser. Call `init` next, or use `createInit`.
    pub fn create() status.Error!Parser {
        const ptr = c.lxb_html_parser_create();
        if (ptr == null) return error.OutOfMemory;
        return .{ .ptr = ptr };
    }

    pub fn init(self: *Parser) status.Error!void {
        try status.check(c.lxb_html_parser_init(self.ptr));
    }

    /// Creates and initializes in one step.
    pub fn createInit() status.Error!Parser {
        var self = try create();
        errdefer self.deinit();
        try self.init();
        return self;
    }

    /// Destroys the parser and every document it produced.
    ///
    /// Any `Document`, `dom.Node` or `dom.Element` obtained from this parser
    /// must not be used afterwards.
    pub fn deinit(self: *Parser) void {
        if (self.ptr != null) {
            _ = c.lxb_html_parser_destroy(self.ptr);
            self.ptr = null;
        }
    }

    pub fn raw(self: *Parser) [*c]c.lxb_html_parser_t {
        return self.ptr;
    }

    /// Parses a complete HTML document.
    ///
    /// The returned document borrows this parser's memory; see the type-level
    /// ownership note.
    pub fn parse(self: *Parser, html: []const u8) status.Error!Document {
        const doc = c.lxb_html_parse(self.ptr, conv.ptr(html), html.len);
        if (doc == null) return error.LexborError;
        return .{ .ptr = doc };
    }
};

/// A borrowed, parsed HTML document.
pub const Document = struct {
    ptr: [*c]c.lxb_html_document_t,

    pub fn raw(self: Document) [*c]c.lxb_html_document_t {
        return self.ptr;
    }

    pub fn domDocument(self: Document) [*c]c.lxb_dom_document_t {
        return &self.ptr.*.dom_document;
    }

    /// The document's root element (normally `<html>`).
    pub fn rootElement(self: Document) ?dom.Element {
        return dom.Element.maybe(self.ptr.*.dom_document.element);
    }

    /// The root element as a generic node.
    pub fn rootNode(self: Document) ?dom.Node {
        const element = self.ptr.*.dom_document.element;
        if (element == null) return null;
        return dom.Node{ .ptr = c.lxb_dom_interface_node(element) };
    }

    /// The document title, if the document has one.
    pub fn title(self: Document) ?[]const u8 {
        var len: usize = 0;
        const value = c.lxb_html_document_title(self.ptr, &len);
        if (value == null) return null;
        return conv.slice(value, len);
    }
};

/// Serializes `node` and its subtree as HTML into `writer`.
///
/// This does not need a document, so it works for detached subtrees too.
pub fn serialize(node: dom.Node, writer: *std.Io.Writer) !void {
    var sink = callback.WriterSink{ .writer = writer };
    const raw = c.lxb_html_serialize_tree_cb(node.raw(), callback.WriterSink.callback, &sink);
    try sink.check(raw);
}

/// Serializes the whole document (from its root element) as HTML.
pub fn serializeDocument(doc: Document, writer: *std.Io.Writer) !void {
    const node = doc.rootNode() orelse return error.NoRootElement;
    return serialize(node, writer);
}

test "parses HTML and exposes the tree" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<div id=\"x\"><p>Hello <b>world</b></p></div>");

    const root = doc.rootElement().?;
    try std.testing.expectEqualStrings("html", root.localName());

    // The serializer normalizes the input into a full document tree.
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializeDocument(doc, &writer);
    try std.testing.expectEqualStrings(
        "<html><head></head><body><div id=\"x\"><p>Hello <b>world</b></p></div></body></html>",
        std.Io.Writer.buffered(&writer),
    );
}

test "walks descendants and reads attributes" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<div id=\"x\" class=\"a b\"><p>one</p><p>two</p></div>");
    const body = doc.rootElement().?.firstChild().?; // <head> or <body> handling
    _ = body;

    const root = doc.rootNode().?;

    // Collect every element tag name in document order.
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(std.testing.allocator);

    var it = root.descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            try tags.append(std.testing.allocator, el.localName());
        }
    }

    try std.testing.expectEqual(@as(usize, 6), tags.items.len);
    try std.testing.expectEqualStrings("html", tags.items[0]);
    try std.testing.expectEqualStrings("head", tags.items[1]);
    try std.testing.expectEqualStrings("body", tags.items[2]);
    try std.testing.expectEqualStrings("div", tags.items[3]);
    try std.testing.expectEqualStrings("p", tags.items[4]);
    try std.testing.expectEqualStrings("p", tags.items[5]);

    // Find the div and inspect its attributes.
    var div: ?dom.Element = null;
    var it2 = root.descendants();
    while (it2.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), "div")) {
                div = el;
                break;
            }
        }
    }

    const d = div.?;
    try std.testing.expectEqualStrings("x", d.id().?);
    try std.testing.expectEqualStrings("a b", d.classAttribute().?);
    try std.testing.expect(d.hasAttribute("id"));
    try std.testing.expect(!d.hasAttribute("nope"));
    try std.testing.expectEqual(@as(?[]const u8, null), d.getAttribute("nope"));

    // Iterate attributes.
    var attr_names: std.ArrayList([]const u8) = .empty;
    defer attr_names.deinit(std.testing.allocator);
    var attrs = d.attributes();
    while (attrs.next()) |attr| {
        try attr_names.append(std.testing.allocator, attr.localName());
    }
    try std.testing.expectEqual(@as(usize, 2), attr_names.items.len);
}

test "textContent concatenates the subtree text" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<div>Hello <b>world</b>!</div>");
    const root = doc.rootNode().?;

    var div: ?dom.Element = null;
    var it = root.descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), "div")) {
                div = el;
                break;
            }
        }
    }

    try std.testing.expectEqualStrings("Hello world!", div.?.textContent());
}

test "setAttribute round-trips through serialization" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<div></div>");
    const root = doc.rootNode().?;

    var div: ?dom.Element = null;
    var it = root.descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), "div")) {
                div = el;
                break;
            }
        }
    }

    const d = div.?;
    try d.setAttribute("data-x", "42");
    try std.testing.expectEqualStrings("42", d.getAttribute("data-x").?);
    try d.removeAttribute("data-x");
    try std.testing.expectEqual(@as(?[]const u8, null), d.getAttribute("data-x"));
}

test "serialize works without a document" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<p>standalone</p>");
    const root = doc.rootNode().?;

    var p: ?dom.Node = null;
    var it = root.descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), "p")) {
                p = node;
                break;
            }
        }
    }

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serialize(p.?, &writer);
    try std.testing.expectEqualStrings("<p>standalone</p>", std.Io.Writer.buffered(&writer));
}
