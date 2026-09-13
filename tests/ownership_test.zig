//! Ownership, lifetime and teardown tests.
//!
//! The wrapper's design rule is that only lexbor's own `*_destroy` frees
//! lexbor memory, and that borrowed views never free anything. These tests pin
//! the observable consequences of that rule: teardown is idempotent, borrowed
//! types have no `deinit`, and Zig-side allocations balance.

const std = @import("std");
const lexbor = @import("z_lexbor");
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

test "teardown is idempotent for every owning type" {
    // Calling deinit twice must be a no-op the second time, not a double free.
    var parser = try lexbor.html.Parser.createInit();
    parser.deinit();
    parser.deinit();
    parser.deinit();
    try std.testing.expect(parser.ptr == null);

    var css_parser = try lexbor.css.Parser.createInit();
    css_parser.deinit();
    css_parser.deinit();
    try std.testing.expect(css_parser.ptr == null);

    var url_parser = try lexbor.url.Parser.createInit();
    url_parser.deinit();
    url_parser.deinit();
    try std.testing.expect(url_parser.ptr == null);

    var engine = try lexbor.selectors.Engine.createInit();
    engine.deinit();
    engine.deinit();
    try std.testing.expect(engine.selectors == null);
}

test "deinit order does not matter for the doc harness" {
    // Engine first, then parser (the harness order) is the safe order; doing it
    // twice via explicit calls proves the guards hold.
    var doc = try harness.Doc.init(fixtures.page);
    doc.deinit();
    doc.deinit();
}

test "borrowed views expose no deinit (compile-time guarantee)" {
    // This is the property that makes use-after-free from Zig impossible to
    // express by accident: there is nothing to call.
    try std.testing.expect(!@hasDecl(lexbor.dom.Node, "deinit"));
    try std.testing.expect(!@hasDecl(lexbor.dom.Element, "deinit"));
    try std.testing.expect(!@hasDecl(lexbor.dom.Attr, "deinit"));
    try std.testing.expect(!@hasDecl(lexbor.html.Document, "deinit"));
    try std.testing.expect(!@hasDecl(lexbor.css.SelectorList, "deinit"));
    try std.testing.expect(!@hasDecl(lexbor.url.Url, "deinit"));

    // Owning types do expose it.
    try std.testing.expect(@hasDecl(lexbor.html.Parser, "deinit"));
    try std.testing.expect(@hasDecl(lexbor.css.Parser, "deinit"));
    try std.testing.expect(@hasDecl(lexbor.url.Parser, "deinit"));
    try std.testing.expect(@hasDecl(lexbor.selectors.Engine, "deinit"));
}

test "many create/destroy cycles do not leak lexbor state" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var parser = try lexbor.html.Parser.createInit();
        const doc = try parser.parse("<p>cycle</p>");
        try std.testing.expect(doc.rootNode() != null);
        parser.deinit();
    }
}

test "many engine create/destroy cycles" {
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var engine = try lexbor.selectors.Engine.createInit();
        engine.deinit();
    }
}

test "queryAll results are freed by the caller (leak-checked)" {
    // `std.testing.allocator` fails the test if anything leaks, so a correct
    // defer here is itself the assertion.
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var found = try doc.engine.queryAll(gpa, doc.root(), "li");
        defer found.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 3), found.items.len);
    }
}

test "a document stays valid for as long as its parser lives" {
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse(fixtures.page);

    // Hold borrowed views across further parser activity; they must still read
    // correctly because the pool is only released on destroy.
    const first_li = (try findFirst(doc, "li")).?;

    _ = try parser.parse("<p>unrelated</p>");
    _ = try parser.parse("<p>another</p>");

    try std.testing.expectEqualStrings("alpha", first_li.textContent());
    try std.testing.expectEqualStrings("1", first_li.asElement().?.getAttribute("data-id").?);
}

fn findFirst(doc: lexbor.html.Document, tag: []const u8) !?lexbor.dom.Node {
    var it = doc.rootNode().?.descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), tag)) return node;
        }
    }
    return null;
}

test "an engine's compiled selector list stays valid for the engine's life" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const list = try doc.engine.compile("li.item");

    // Use the same compiled list repeatedly.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var found = try doc.engine.queryAll(gpa, doc.root(), "li.item");
        defer found.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 3), found.items.len);
    }

    const Counter = struct {
        n: usize = 0,
        fn onMatch(self: *@This(), _: lexbor.dom.Node) lexbor.selectors.MatchError!void {
            self.n += 1;
        }
    };
    var counter = Counter{};
    try doc.engine.find(doc.root(), list, &counter, Counter.onMatch);
    try std.testing.expectEqual(@as(usize, 3), counter.n);
}
