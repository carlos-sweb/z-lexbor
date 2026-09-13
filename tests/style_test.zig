//! CSS cascade and computed-style tests.
//!
//! These pin the fact that lexbor is a CSS *engine*, not only a CSS parser: it
//! matches selectors against the parsed DOM, resolves the cascade, and stores
//! the result as a per-element computed style tree.
//!
//! The entry point is `lxb_engine_init()`, which enables style application on a
//! document before parsing. `html.Parser` (the plain DOM parser) does **not**
//! apply styles — see the note at the end of this file.

const std = @import("std");
const lexbor = @import("z_lexbor");
const c = lexbor.sys.c;

const ok: c.lxb_status_t = @intCast(c.LXB_STATUS_OK);

/// Parses with style application enabled.
const Engine = struct {
    ptr: [*c]c.lxb_engine_t,

    fn init() !Engine {
        const ptr = c.lxb_engine_create();
        if (ptr == null) return error.OutOfMemory;
        errdefer _ = c.lxb_engine_destroy(ptr);
        try lexbor.status.check(c.lxb_engine_init(ptr));
        return .{ .ptr = ptr };
    }

    fn deinit(self: *Engine) void {
        _ = c.lxb_engine_destroy(self.ptr);
        self.ptr = null;
    }

    fn parse(self: *Engine, html_source: []const u8) !void {
        try lexbor.status.check(c.lxb_engine_parse(
            self.ptr,
            html_source.ptr,
            html_source.len,
            0,
        ));
    }

    fn document(self: Engine) [*c]c.lxb_dom_document_t {
        return &self.ptr.*.document.*.dom_document;
    }

    /// The first element with the given tag name.
    fn firstElement(self: Engine, tag: []const u8) ?lexbor.dom.Element {
        const root = lexbor.dom.Node{
            .ptr = c.lxb_dom_interface_node(self.ptr.*.document.*.dom_document.element),
        };
        var it = root.descendants();
        while (it.next()) |node| {
            if (node.asElement()) |el| {
                if (std.mem.eql(u8, el.localName(), tag)) return el;
            }
        }
        return null;
    }
};

/// The computed style of the first `<p>`, serialized.
fn pStyle(html_source: []const u8, buf: []u8) ![]const u8 {
    var engine = try Engine.init();
    defer engine.deinit();
    try engine.parse(html_source);

    const p = engine.firstElement("p") orelse return error.NoParagraph;
    return serializeStyle(p, buf);
}

fn serializeStyle(element: lexbor.dom.Element, buf: []u8) ![]const u8 {
    var str = std.mem.zeroes(c.lexbor_str_t);
    try lexbor.status.check(c.lxb_dom_element_style_serialize_str(element.raw(), &str, 0));

    const n = @min(str.length, buf.len);
    @memcpy(buf[0..n], str.data[0..n]);
    return buf[0..n];
}

test "cascade: specificity orders id > class > type" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<style>p{color:red}.big{color:blue}#x{color:green}</style><p class=big id=x>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: green", got);
}

test "cascade: specificity beats source order" {
    var buf: [128]u8 = undefined;
    // The winning rule comes first, so only specificity can explain the result.
    const got = try pStyle(
        "<style>#x{color:green}.big{color:blue}p{color:red}</style><p class=big id=x>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: green", got);
}

test "cascade: !important beats higher specificity" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<style>p{color:red !important}.big{color:blue}</style><p class=big>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: red !important", got);
}

test "cascade: author !important beats an inline style" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<style>p{color:red !important}</style><p style='color:blue'>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: red !important", got);
}

test "cascade: an inline style beats author normal declarations" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<style>p{color:red}</style><p style='color:blue'>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: blue", got);
}

test "cascade: equal specificity is broken by source order" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<style>.a{color:red}.b{color:blue}</style><p class='a b'>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: blue", got);
}

test "cascade: attribute selector (b) beats type selector (c)" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<style>p{color:red}[data-x]{color:blue}</style><p data-x=1>hi</p>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: blue", got);
}

test "multiple matched rules accumulate into one computed style" {
    var engine = try Engine.init();
    defer engine.deinit();
    try engine.parse("<style>p{color:red}.big{font-size:12px}</style><p class=big>hi</p>");

    const p = engine.firstElement("p").?;
    var buf: [256]u8 = undefined;
    const got = try serializeStyle(p, &buf);

    // Both declarations are applied, regardless of which rule supplied them.
    try std.testing.expect(std.mem.indexOf(u8, got, "color: red") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "font-size: 12px") != null);
}

test "an element matching no rule gets no declarations" {
    var engine = try Engine.init();
    defer engine.deinit();
    try engine.parse("<style>p{color:red}</style><p>hi</p><span>plain</span>");

    const span = engine.firstElement("span").?;
    // `[*c]` pointers are already nullable in Zig.
    try std.testing.expect(c.lxb_dom_element_style_by_name(span.raw(), "color", 5) == null);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try serializeStyle(span, &buf));
}

test "a matched declaration is retrievable by property name" {
    var engine = try Engine.init();
    defer engine.deinit();
    try engine.parse("<style>p{color:red}</style><p>hi</p>");

    const p = engine.firstElement("p").?;
    try std.testing.expect(c.lxb_dom_element_style_by_name(p.raw(), "color", 5) != null);
    // A property that was never set is absent.
    try std.testing.expect(c.lxb_dom_element_style_by_name(p.raw(), "margin", 6) == null);
}

test "a <style> element in the body is applied too" {
    var buf: [128]u8 = undefined;
    const got = try pStyle(
        "<body><style>p{color:teal}</style><p>hi</p></body>",
        &buf,
    );
    try std.testing.expectEqualStrings("color: teal", got);
}

test "an empty stylesheet leaves elements unstyled" {
    var buf: [64]u8 = undefined;
    const got = try pStyle("<style></style><p>hi</p>", &buf);
    try std.testing.expectEqualStrings("", got);
}

test "a malformed stylesheet does not corrupt the document" {
    var engine = try Engine.init();
    defer engine.deinit();

    // Unterminated rule: lexbor must still produce a usable tree.
    try engine.parse("<style>p{color:red</style><p>hi</p>");

    const p = engine.firstElement("p") orelse return error.NoParagraph;
    try std.testing.expectEqualStrings("hi", p.textContent());
}

test "NOTE: style queries require lxb_style_init (lexbor does not check)" {
    // This is why the tests above use `lxb_engine` rather than `html.Parser`:
    // style application is opt-in through `lxb_style_init()`.
    //
    // The consequence is not merely "no styles". Without it, the document's
    // `css` field stays NULL, and lexbor's `lxb_dom_element_style_by_name()`
    // dereferences it without a null check
    // (`style/dom/interfaces/element.c:103` -> `lexbor_avl_search(doc->css->styles)`),
    // aborting the process. It is asserted here as a raw pointer check rather
    // than by calling the crashing function.
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<style>p{color:red}</style><p>hi</p>");

    // The plain parser leaves the CSS state uninitialised...
    try std.testing.expect(doc.domDocument().*.css == null);

    // ...while the engine path sets it up.
    var engine = try Engine.init();
    defer engine.deinit();
    try engine.parse("<style>p{color:red}</style><p>hi</p>");
    try std.testing.expect(engine.document().*.css != null);

    // The DOM itself is intact either way: the <style> text is still there.
    var selector_engine = try lexbor.selectors.Engine.createInit();
    defer selector_engine.deinit();

    const gpa = std.testing.allocator;
    var found = try selector_engine.queryAll(gpa, doc.rootNode().?, "p");
    defer found.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings("hi", found.items[0].textContent());
}
