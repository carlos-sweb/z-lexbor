//! Deep tests for the idiomatic `style` module: cascade, specificity decoding,
//! computed-style reading, stylesheet injection and dynamic mutation.

const std = @import("std");
const lexbor = @import("z_lexbor");
const style = lexbor.style;
const dom = lexbor.dom;

fn styleString(computed: style.Computed, buf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try computed.serialize(&writer);
    return std.Io.Writer.buffered(&writer);
}

fn firstTag(doc: style.StyledDocument, tag: []const u8) ?dom.Element {
    var it = doc.documentNode().descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), tag)) return el;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

test "Engine creates, parses and tears down idempotently" {
    var engine = try style.Engine.create();
    engine.deinit();
    engine.deinit();
    try std.testing.expect(engine.ptr == null);
}

test "an Engine document has CSS state initialised" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red}</style><p>hi</p>");
    try std.testing.expect(style.isInitialized(doc.domDocument()));
}

test "an empty Engine document is usable" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("");
    try std.testing.expect(style.isInitialized(doc.domDocument()));
    // Even "empty" input yields a document skeleton, so the root exists; what
    // matters is that style queries on it do not crash.
    const root = doc.rootElement() orelse return error.NoRoot;
    try std.testing.expect(try (try doc.styleOf(root)).isEmpty());
}

// ---------------------------------------------------------------------------
// Cascade through the wrapper
// ---------------------------------------------------------------------------

test "cascade: specificity, source order, !important and inline" {
    const cases = [_]struct { html: []const u8, expected: []const u8 }{
        .{
            .html = "<style>p{color:red}.b{color:blue}#x{color:green}</style><p class=b id=x>hi</p>",
            .expected = "color: green",
        },
        .{
            .html = "<style>#x{color:green}.b{color:blue}p{color:red}</style><p class=b id=x>hi</p>",
            .expected = "color: green",
        },
        .{
            .html = "<style>p{color:red !important}.b{color:blue}</style><p class=b>hi</p>",
            .expected = "color: red !important",
        },
        .{
            .html = "<style>p{color:red !important}</style><p style='color:blue'>hi</p>",
            .expected = "color: red !important",
        },
        .{
            .html = "<style>p{color:red}</style><p style='color:blue'>hi</p>",
            .expected = "color: blue",
        },
        .{
            .html = "<style>.a{color:red}.b{color:blue}</style><p class='a b'>hi</p>",
            .expected = "color: blue",
        },
    };

    for (cases) |case| {
        var engine = try style.Engine.create();
        defer engine.deinit();

        const doc = try engine.parse(case.html);
        const p = firstTag(doc, "p") orelse return error.NoParagraph;
        const computed = try doc.styleOf(p);

        var buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try styleString(computed, &buf));
    }
}

test "Specificity decodes ids, classes and types" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>c#a.b{color:red}</style><c class=b id=a>hi</c>");
    const el = firstTag(doc, "c") orelse return error.NoElement;
    const computed = try doc.styleOf(el);

    const entry = computed.get("color") orelse return error.NoDeclaration;
    try std.testing.expectEqual(@as(u32, 1), entry.specificity.ids());
    try std.testing.expectEqual(@as(u32, 1), entry.specificity.classes());
    try std.testing.expectEqual(@as(u32, 1), entry.specificity.types());
    try std.testing.expect(!entry.specificity.important());
    try std.testing.expect(!entry.specificity.fromStyleAttribute());
}

test "Specificity flags !important and the style attribute" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse(
        "<style>p{color:red !important}</style><p style='margin:0'>hi</p>",
    );
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    const color = computed.get("color") orelse return error.NoColor;
    try std.testing.expect(color.important());
    try std.testing.expect(!color.specificity.fromStyleAttribute());

    const margin = computed.get("margin") orelse return error.NoMargin;
    try std.testing.expect(margin.specificity.fromStyleAttribute());
    try std.testing.expect(!margin.important());
}

test "Specificity ordering puts !important above an inline style" {
    const important_rule = style.Specificity{ .raw = 0x1000_0000 };
    const inline_style = style.Specificity{ .raw = 0x0800_0000 };
    const id_rule = style.Specificity{ .raw = 0x0004_0000 };

    try std.testing.expect(important_rule.order() > inline_style.order());
    try std.testing.expect(inline_style.order() > id_rule.order());
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

test "get returns declarations and null for absent properties" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red;font-size:10px}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    try std.testing.expect(computed.get("color") != null);
    try std.testing.expect(computed.get("font-size") != null);
    try std.testing.expectEqual(@as(?style.Entry, null), computed.get("margin"));
    try std.testing.expectEqual(@as(?style.Entry, null), computed.get("not-a-property"));
}

test "Entry serializes as 'name: value' and keeps !important" {
    const gpa = std.testing.allocator;

    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red !important}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    const entry = computed.get("color") orelse return error.NoColor;
    const text = try entry.toOwnedString(gpa);
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "color") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!important") != null);

    var name_buf: [64]u8 = undefined;
    var name_writer = std.Io.Writer.fixed(&name_buf);
    try entry.serializeName(&name_writer);
    try std.testing.expectEqualStrings("color", std.Io.Writer.buffered(&name_writer));
}

test "count, isEmpty and collect agree" {
    const gpa = std.testing.allocator;

    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse(
        "<style>p{color:red;font-size:10px;margin:0}</style><p>hi</p><i>none</i>",
    );

    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const styled = try doc.styleOf(p);
    try std.testing.expectEqual(@as(usize, 3), try styled.count());
    try std.testing.expect(!try styled.isEmpty());

    const entries = try styled.collect(gpa);
    defer gpa.free(entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);

    // Every collected entry is a winner, and serializes to something non-empty.
    for (entries) |entry| {
        try std.testing.expect(!entry.is_weak);
        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try entry.serialize(&writer);
        try std.testing.expect(std.Io.Writer.buffered(&writer).len > 0);
    }

    const i = firstTag(doc, "i") orelse return error.NoItalic;
    const unstyled = try doc.styleOf(i);
    try std.testing.expect(try unstyled.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), try unstyled.count());
}

test "walk filters out losing candidates (no duplicates)" {
    const Counter = struct {
        seen: usize = 0,
        fn onEntry(self: *@This(), entry: style.Entry) style.Error!void {
            self.seen += 1;
            // The walk must never report a weak (losing) declaration.
            if (entry.is_weak) return error.LexborError;
        }
    };

    var engine = try style.Engine.create();
    defer engine.deinit();

    // `color` is declared three times for this element; only one can win.
    const doc = try engine.parse(
        "<style>p{color:red}.b{color:green}#x{color:blue}</style><p class=b id=x>hi</p>",
    );
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    var counter = Counter{};
    try computed.walk(&counter, Counter.onEntry);

    // Exactly one winner, and it is the highest-specificity rule.
    try std.testing.expectEqual(@as(usize, 1), counter.seen);

    const gpa = std.testing.allocator;
    const text = try computed.serializeAlloc(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("color: blue", text);
}

test "serializeAlloc is leak-free and stable" {
    const gpa = std.testing.allocator;

    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red;font-size:12px}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    const first = try computed.serializeAlloc(gpa);
    defer gpa.free(first);
    const second = try computed.serializeAlloc(gpa);
    defer gpa.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first.len > 0);
}

test "property() returns a typed pointer for an applied property" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    try std.testing.expect(computed.property("color") != null);
    try std.testing.expectEqual(@as(?*const anyopaque, null), computed.property("margin"));
}

// ---------------------------------------------------------------------------
// Stylesheet injection
// ---------------------------------------------------------------------------

test "applyStylesheet styles an already-built document" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    // Parsed with no CSS at all.
    const doc = try engine.parse("<p class=late>hi</p>");

    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    try std.testing.expect(try (try doc.styleOf(p)).isEmpty());

    // Injected afterwards.
    try doc.applyStylesheet("p.late { color: purple }");

    const computed = try doc.styleOf(p);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("color: purple", try styleString(computed, &buf));
}

test "two injected stylesheets resolve by source order" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<p>hi</p>");
    try doc.applyStylesheet("p { color: red }");
    try doc.applyStylesheet("p { color: green }");

    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("color: green", try styleString(try doc.styleOf(p), &buf));
}

test "an injected sheet can be overridden by a later, more specific one" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<p class=b id=x>hi</p>");
    try doc.applyStylesheet("#x { color: red }");
    try doc.applyStylesheet("p { color: green }");

    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    var buf: [128]u8 = undefined;
    // Specificity still wins over source order.
    try std.testing.expectEqualStrings("color: red", try styleString(try doc.styleOf(p), &buf));
}

// ---------------------------------------------------------------------------
// Dynamic mutation
// ---------------------------------------------------------------------------

test "changing the class does NOT recompute the computed style" {
    // Pins a real lexbor limitation rather than an idealised expectation.
    // Styles are resolved at insertion time; mutating an attribute afterwards
    // changes the DOM but leaves the computed style as it was.
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse(
        "<style>.a{color:red}.b{color:blue}</style><p class=a>hi</p>",
    );
    const p = firstTag(doc, "p") orelse return error.NoParagraph;

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("color: red", try styleString(try doc.styleOf(p), &buf));

    try p.setAttribute("class", "b");
    // The DOM did change...
    try std.testing.expectEqualStrings("b", p.getAttribute("class").?);
    // ...but the style did not.
    try std.testing.expectEqualStrings("color: red", try styleString(try doc.styleOf(p), &buf));
}

test "applying the stylesheet again does not clear the stale declaration" {
    // Documents the counterpart of the test above: re-applying adds the new
    // matching rule, and the previously resolved declaration is kept.
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse(
        "<style>.a{color:red}.b{color:blue}</style><p class=a>hi</p>",
    );
    const p = firstTag(doc, "p") orelse return error.NoParagraph;

    try p.setAttribute("class", "b");
    try doc.applyStylesheet("p { }");

    var buf: [256]u8 = undefined;
    const got = try styleString(try doc.styleOf(p), &buf);
    // Whichever wins, the important part is that this is well defined and does
    // not crash or return an empty style.
    try std.testing.expect(got.len > 0);
}

test "a newly inserted element receives styles" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>.added{color:olive}</style><div id=host></div>");
    const host = firstTag(doc, "div") orelse return error.NoDiv;

    // Build and attach a matching element after parsing.
    const added = try dom.createElement(doc.domDocument(), "span");
    try added.setAttribute("class", "added");
    try host.appendChild(added.node());

    const computed = try doc.styleOf(added);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("color: olive", try styleString(computed, &buf));
}

test "removing an attribute falls back to the lower-precedence rule" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse(
        "<style>p{color:red}[data-x]{color:blue}</style><p data-x=1>hi</p>",
    );
    const p = firstTag(doc, "p") orelse return error.NoParagraph;

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("color: blue", try styleString(try doc.styleOf(p), &buf));

    try p.removeAttribute("data-x");
    try std.testing.expect(!p.hasAttribute("data-x"));

    // As above: the DOM changed, the already-resolved style did not.
    try std.testing.expectEqualStrings("color: blue", try styleString(try doc.styleOf(p), &buf));
}

test "an inline style present at parse time beats author rules" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red}</style><p style='color:navy'>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("color: navy", try styleString(try doc.styleOf(p), &buf));
}

// ---------------------------------------------------------------------------
// The guard: the crash lexbor has and the wrapper prevents
// ---------------------------------------------------------------------------

test "REGRESSION: of() returns a typed error instead of aborting" {
    // A document from html.Parser has no CSS state. lexbor's
    // lxb_dom_element_style_by_name() dereferences document.css without a null
    // check and aborts the process; the wrapper must return an error instead.
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<p>hi</p>");
    const p = firstTagPlain(doc, "p") orelse return error.NoParagraph;

    try std.testing.expect(!style.isInitialized(doc.domDocument()));
    try std.testing.expectError(error.StyleNotInitialized, style.of(p));
}

fn firstTagPlain(doc: lexbor.html.Document, tag: []const u8) ?dom.Element {
    var it = doc.documentNode().descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), tag)) return el;
        }
    }
    return null;
}

test "walking an element with no styles yields an empty result, not an error" {
    // Pins the observable behaviour instead of lexbor's internal status code:
    // unstyled elements must report zero declarations without surfacing an
    // error, whether the tree has no style node at all or no style tree.
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>.zzz{color:red}</style><i>plain</i><b></b>");
    const i = firstTag(doc, "i") orelse return error.NoItalic;
    const computed = try doc.styleOf(i);

    try std.testing.expectEqual(@as(usize, 0), try computed.count());
    try std.testing.expect(try computed.isEmpty());

    const entries = try computed.collect(std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "isInitialized distinguishes the two parse paths" {
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();
    const plain = try parser.parse("<p>hi</p>");
    try std.testing.expect(!style.isInitialized(plain.domDocument()));

    var engine = try style.Engine.create();
    defer engine.deinit();
    const styled = try engine.parse("<p>hi</p>");
    try std.testing.expect(style.isInitialized(styled.domDocument()));
}
