//! Adversarial tests.
//!
//! Every test in this file tries to break an assumption of the wrapper: wrong
//! sizes, hostile bytes, exhausted buffers, exhausted memory, absurd
//! structures. The expected outcome is always the same: a typed Zig error or a
//! well-formed result, *never* a trap, a silent corruption or a leaked buffer.

const std = @import("std");
const lexbor = @import("z_lexbor");
const dom = lexbor.dom;
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

// ---------------------------------------------------------------------------
// Hostile input
// ---------------------------------------------------------------------------

test "BREAK: a 1 MiB document parses without collapsing" {
    const gpa = std.testing.allocator;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);

    try html.appendSlice(gpa, "<html><body>");
    var i: usize = 0;
    while (html.items.len < 1024 * 1024) : (i += 1) {
        try html.appendSlice(gpa, "<p class=\"c\">paragraph</p>");
    }
    try html.appendSlice(gpa, "</body></html>");

    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse(html.items);
    const root = doc.rootNode().?;

    // Count paragraphs: must be non-trivial and consistent.
    var paragraphs: usize = 0;
    var it = root.descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), "p")) paragraphs += 1;
        }
    }
    try std.testing.expect(paragraphs > 10_000);
}

test "BREAK: absurdly deep nesting does not crash the tree walk" {
    const gpa = std.testing.allocator;

    const depth = 5000;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);

    try html.appendSlice(gpa, "<div id=root>");
    var i: usize = 0;
    while (i < depth) : (i += 1) try html.appendSlice(gpa, "<div>");
    try html.appendSlice(gpa, "x");

    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse(html.items);

    // The exact depth lexbor keeps is its business; walking whatever it built
    // must terminate and stay finite.
    var nodes: usize = 0;
    var it = doc.rootNode().?.descendants();
    while (it.next()) |_| {
        nodes += 1;
        try std.testing.expect(nodes < depth * 4);
    }
    try std.testing.expect(nodes > 1);
}

test "BREAK: NUL bytes inside markup" {
    const inputs = [_][]const u8{
        "<p>a\x00b</p>",
        "\x00",
        "<div\x00id=x></div>",
        "<p>\x00\x00\x00</p>",
    };

    for (inputs) |input| {
        var doc = try harness.Doc.init(input);
        defer doc.deinit();
        try std.testing.expect(doc.rootNode() != null);
    }
}

test "BREAK: invalid UTF-8 never derails the parser" {
    const invalid = [_][]const u8{
        "<p>\xff\xfe</p>",
        "<p>\x80\x81\x82</p>",
        "<p>\xc3</p>",
        "<p>\xe2\x82</p>",
        "<p>\xf0\x9f</p>",
    };

    for (invalid) |input| {
        var doc = try harness.Doc.init(input);
        defer doc.deinit();

        // Must produce a tree and be serializable.
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try lexbor.html.serializeDocument(doc.document, &w);
        try std.testing.expect(std.Io.Writer.buffered(&w).len > 0);
    }
}

test "BREAK: a 64 KiB attribute value" {
    const gpa = std.testing.allocator;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);

    try html.appendSlice(gpa, "<div data-big=\"");
    var i: usize = 0;
    while (i < 64 * 1024) : (i += 1) try html.append(gpa, 'v');
    try html.appendSlice(gpa, "\"></div>");

    var doc = try harness.Doc.init(html.items);
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;
    try std.testing.expectEqual(@as(usize, 64 * 1024), div.getAttribute("data-big").?.len);
}

test "BREAK: an element with thousands of attributes" {
    const gpa = std.testing.allocator;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);

    try html.appendSlice(gpa, "<div");
    const count = 2000;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [32]u8 = undefined;
        const attr = try std.fmt.bufPrint(&buf, " a{d}=\"{d}\"", .{ i, i });
        try html.appendSlice(gpa, attr);
    }
    try html.appendSlice(gpa, "></div>");

    var doc = try harness.Doc.init(html.items);
    defer doc.deinit();

    const div = (try doc.first("div")).?.asElement().?;

    var seen: usize = 0;
    var it = div.attributes();
    while (it.next()) |_| seen += 1;
    try std.testing.expectEqual(count, seen);
}

test "BREAK: a very long tag name" {
    const gpa = std.testing.allocator;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);

    try html.append(gpa, '<');
    var i: usize = 0;
    while (i < 4096) : (i += 1) try html.append(gpa, 'q');
    try html.appendSlice(gpa, ">x</");
    i = 0;
    while (i < 4096) : (i += 1) try html.append(gpa, 'q');
    try html.append(gpa, '>');

    var doc = try harness.Doc.init(html.items);
    defer doc.deinit();
    try std.testing.expect(doc.rootNode() != null);
}

test "BREAK: unbalanced and interleaved tags never lose the root" {
    const nasty = [_][]const u8{
        "<a><b><c></a></b></c>",
        "<div></span></p></div>",
        "<table><div><tr><td>",
        "<select><option><select>",
        "<html><body><html><body>",
        "<!DOCTYPE html><!DOCTYPE html><html>",
        "<!--unterminated comment",
        "<![CDATA[unterminated",
        "<?processing instruction",
        "<p attr=\"unterminated",
        "<p attr='mixed\">",
    };

    for (nasty) |input| {
        var doc = try harness.Doc.init(input);
        defer doc.deinit();
        try std.testing.expectEqualStrings("html", doc.root().asElement().?.localName());
    }
}

// ---------------------------------------------------------------------------
// Exhausted resources
// ---------------------------------------------------------------------------

test "BREAK: serializing into a buffer that is too small fails with WriteFailed" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var tiny: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&tiny);

    // The error must come back as a typed Zig error, not a truncated string and
    // not a crash.
    try std.testing.expectError(
        error.WriteFailed,
        lexbor.html.serializeDocument(doc.document, &w),
    );

    // Partial output is allowed, but it must be bounded by the buffer.
    try std.testing.expect(std.Io.Writer.buffered(&w).len <= tiny.len);
}

test "BREAK: a zero-length serialization buffer still fails cleanly" {
    var doc = try harness.Doc.init("<p>hello</p>");
    defer doc.deinit();

    var empty: [0]u8 = undefined;
    var w = std.Io.Writer.fixed(&empty);

    try std.testing.expectError(
        error.WriteFailed,
        lexbor.html.serializeDocument(doc.document, &w),
    );
}

test "BREAK: an allocating writer that cannot allocate surfaces WriteFailed" {
    // std.Io.Writer.Error is exactly error{WriteFailed}: the allocating writer
    // collapses allocation failure into it, so that -- not OutOfMemory -- is
    // what reaches the caller. This pins that behaviour rather than guessing.
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var allocating = std.Io.Writer.Allocating.init(failing.allocator());
    defer allocating.deinit();

    try std.testing.expectError(
        error.WriteFailed,
        lexbor.html.serializeDocument(doc.document, &allocating.writer),
    );
    try std.testing.expect(failing.has_induced_failure);
}

test "serialization into an allocating writer succeeds with enough memory" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();

    try lexbor.html.serializeDocument(doc.document, &allocating.writer);
    try std.testing.expect(allocating.written().len > 0);
}

// ---------------------------------------------------------------------------
// Error propagation through `try`
// ---------------------------------------------------------------------------

test "try chains preserve the exact error across wrapper layers" {
    // parse() failure -> typed error, and the caller can discriminate it.
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    // A valid parse must not error.
    _ = try parser.parse("<p>ok</p>");

    // URL failures carry their own identity through two `try` hops.
    var url_parser = try lexbor.url.Parser.createInit();
    defer url_parser.deinit();

    const result = parseUrlTwice(&url_parser, "definitely not a url");
    try std.testing.expectError(error.LexborError, result);
}

fn parseUrlTwice(parser: *lexbor.url.Parser, input: []const u8) lexbor.status.Error!lexbor.url.Url {
    const url = try parser.parse(null, input);
    return url;
}

test "catch can recover from a lexbor error and keep going" {
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    // Failure path taken...
    var url_parser = try lexbor.url.Parser.createInit();
    defer url_parser.deinit();

    const recovered = blk: {
        const url = url_parser.parse(null, "not a url") catch {
            break :blk true;
        };
        _ = url;
        break :blk false;
    };
    try std.testing.expect(recovered);

    // ...and the parser is still usable afterwards.
    const ok = try url_parser.parse(null, "https://example.com/");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ok.serialize(&w, false);
    try std.testing.expectEqualStrings("https://example.com/", std.Io.Writer.buffered(&w));
}

/// Support types for the errdefer test, at file scope because Zig container
/// functions cannot close over a test's local declarations.
const ErrdeferGuard = struct {
    cleaned: *usize,

    fn rollback(self: ErrdeferGuard) void {
        self.cleaned.* += 1;
    }
};

const ErrdeferRunner = struct {
    fn run(cleaned: *usize, should_fail: bool) !void {
        const guard = ErrdeferGuard{ .cleaned = cleaned };
        errdefer guard.rollback();
        if (should_fail) return error.Aborted;
    }
};

test "errdefer runs on the failure path but not on success" {
    // Pins the language behaviour every teardown guard in the wrapper relies on.
    var cleaned: usize = 0;

    try ErrdeferRunner.run(&cleaned, false);
    try std.testing.expectEqual(@as(usize, 0), cleaned);

    try std.testing.expectError(error.Aborted, ErrdeferRunner.run(&cleaned, true));
    try std.testing.expectEqual(@as(usize, 1), cleaned);
}

test "BREAK: a callback that aborts mid-walk leaves partial results cleanable" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const Collector = struct {
        out: *std.ArrayList(dom.Node),
        abort_at: usize,
        seen: usize = 0,

        fn onMatch(self: *@This(), node: dom.Node) lexbor.selectors.MatchError!void {
            self.seen += 1;
            if (self.seen == self.abort_at) return error.Aborted;
            try self.out.append(std.testing.allocator, node);
        }
    };

    var partial: std.ArrayList(dom.Node) = .empty;
    // Whatever the engine does, the caller must be able to release the partial
    // list; `std.testing.allocator` fails the test if this leaks.
    defer partial.deinit(gpa);

    var ctx = Collector{ .out = &partial, .abort_at = 2 };
    const list = try doc.engine.compile("li");

    try std.testing.expectError(
        error.Aborted,
        doc.engine.find(doc.root(), list, &ctx, Collector.onMatch),
    );

    // One match was appended before the abort, and it is still readable.
    try std.testing.expectEqual(@as(usize, 1), partial.items.len);
    try std.testing.expectEqualStrings("alpha", partial.items[0].textContent());
}

test "BREAK: queryFirst on an empty document returns null, not an error" {
    var doc = try harness.Doc.init("");
    defer doc.deinit();

    try std.testing.expectEqual(@as(?dom.Node, null), try doc.first("div"));

    // Even "empty" input produces html/head/body, so a universal search finds
    // something; it is the *elements* that are absent, not the tree.
    try std.testing.expect((try doc.first("*")) != null);
}

test "BREAK: textContent of a document root is finite" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const text = doc.root().textContent();
    try std.testing.expect(text.len < 4096);
}

test "BREAK: repeated serialization into the same buffer is stable" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var first: [8192]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&first);
    try lexbor.html.serializeDocument(doc.document, &w1);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var again: [8192]u8 = undefined;
        var w2 = std.Io.Writer.fixed(&again);
        try lexbor.html.serializeDocument(doc.document, &w2);
        try std.testing.expectEqualStrings(
            std.Io.Writer.buffered(&w1),
            std.Io.Writer.buffered(&w2),
        );
    }
}
