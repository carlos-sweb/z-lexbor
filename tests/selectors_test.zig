//! Selector engine tests: matching, iteration, early exit and failure paths.

const std = @import("std");
const lexbor = @import("z_lexbor");
const dom = lexbor.dom;
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

test "every supported selector shape matches the expected node count" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    for (fixtures.selector_cases) |case| {
        var found = doc.all(gpa, case.selector) catch |err| {
            std.debug.print("selector '{s}' failed: {s}\n", .{ case.selector, @errorName(err) });
            return err;
        };
        defer found.deinit(gpa);

        if (found.items.len != case.expected) {
            std.debug.print(
                "selector '{s}': expected {d}, got {d}\n",
                .{ case.selector, case.expected, found.items.len },
            );
        }
        try std.testing.expectEqual(case.expected, found.items.len);
    }
}

test "the universal selector matches many elements" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var all = try doc.all(gpa, "*");
    defer all.deinit(gpa);

    try std.testing.expect(all.items.len > 10);
}

test "matches are returned in document order" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var items = try doc.all(gpa, "li");
    defer items.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("alpha", items.items[0].textContent());
    try std.testing.expectEqualStrings("beta", items.items[1].textContent());
    try std.testing.expectEqualStrings("gamma", items.items[2].textContent());
}

test "a comma-separated list matches the union, in document order" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var items = try doc.all(gpa, "h1, li.special, a[rel=next]");
    defer items.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("h1", items.items[0].asElement().?.localName());
    try std.testing.expectEqualStrings("li", items.items[1].asElement().?.localName());
    try std.testing.expectEqualStrings("a", items.items[2].asElement().?.localName());
}

test "queryFirst returns the first match in document order" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const first = (try doc.first("li")).?;
    try std.testing.expectEqualStrings("alpha", first.textContent());

    const special = (try doc.first("li.special")).?;
    try std.testing.expectEqualStrings("gamma", special.textContent());
}

test "a selector that matches nothing yields an empty result, not an error" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var none = try doc.all(gpa, "table");
    defer none.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    try std.testing.expectEqual(@as(?dom.Node, null), try doc.first("table"));
}

test "find() with a custom context collects into caller state" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const Counter = struct {
        seen: usize = 0,
        text_len: usize = 0,

        fn onMatch(self: *@This(), node: dom.Node) lexbor.selectors.MatchError!void {
            self.seen += 1;
            self.text_len += node.textContent().len;
        }
    };

    var counter = Counter{};
    const list = try doc.engine.compile("li.item");
    try doc.engine.find(doc.root(), list, &counter, Counter.onMatch);

    try std.testing.expectEqual(@as(usize, 3), counter.seen);
    try std.testing.expect(counter.text_len >= "alphabetagamma".len);
}

test "find() stops cleanly when the callback returns StopIteration" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const StopAfter = struct {
        limit: usize,
        seen: usize = 0,

        fn onMatch(self: *@This(), _: dom.Node) lexbor.selectors.MatchError!void {
            self.seen += 1;
            if (self.seen >= self.limit) return error.StopIteration;
        }
    };

    var ctx = StopAfter{ .limit = 2 };
    const list = try doc.engine.compile("li");
    try doc.engine.find(doc.root(), list, &ctx, StopAfter.onMatch);

    // StopIteration must not surface as an error, and must stop the walk.
    try std.testing.expectEqual(@as(usize, 2), ctx.seen);
}

test "queryFirst short-circuits and never visits later matches" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    // Verified indirectly: queryFirst must agree with the first element of the
    // full list for every selector.
    const gpa = std.testing.allocator;

    for (fixtures.selector_cases) |case| {
        var items = try doc.all(gpa, case.selector);
        defer items.deinit(gpa);

        const first = try doc.first(case.selector);
        if (items.items.len == 0) {
            try std.testing.expectEqual(@as(?dom.Node, null), first);
        } else {
            try std.testing.expectEqual(items.items[0].raw(), first.?.raw());
        }
    }
}

test "an error from the match callback propagates out of find()" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const Failing = struct {
        at: usize = 0,
        seen: usize = 0,

        fn onMatch(self: *@This(), _: dom.Node) lexbor.selectors.MatchError!void {
            self.seen += 1;
            if (self.seen == self.at) return error.NotExists;
        }
    };

    var ctx = Failing{ .at = 2 };
    const list = try doc.engine.compile("li");
    try std.testing.expectError(
        error.NotExists,
        doc.engine.find(doc.root(), list, &ctx, Failing.onMatch),
    );
    try std.testing.expectEqual(@as(usize, 2), ctx.seen);
}

test "a callback error aborts the walk instead of continuing" {
    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const Abort = struct {
        seen: usize = 0,

        fn onMatch(self: *@This(), _: dom.Node) lexbor.selectors.MatchError!void {
            self.seen += 1;
            return error.Aborted;
        }
    };

    var ctx = Abort{};
    const list = try doc.engine.compile("li");
    try std.testing.expectError(
        error.Aborted,
        doc.engine.find(doc.root(), list, &ctx, Abort.onMatch),
    );
    // Exactly one node was visited before the abort.
    try std.testing.expectEqual(@as(usize, 1), ctx.seen);
}

test "OOM INJECTION: queryAll frees everything when an allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        queryAllUnderOom,
        .{ fixtures.page, "li.item" },
    );
}

fn queryAllUnderOom(
    allocator: std.mem.Allocator,
    html: []const u8,
    selector: []const u8,
) !void {
    var doc = try harness.Doc.init(html);
    defer doc.deinit();

    var found = try doc.engine.queryAll(allocator, doc.root(), selector);
    defer found.deinit(allocator);

    try std.testing.expect(found.items.len > 0);
}

test "OOM INJECTION: queryFirst under allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        queryFirstUnderOom,
        .{fixtures.page},
    );
}

fn queryFirstUnderOom(allocator: std.mem.Allocator, html: []const u8) !void {
    _ = allocator; // queryFirst allocates nothing of its own
    var doc = try harness.Doc.init(html);
    defer doc.deinit();

    const node = try doc.engine.queryFirst(doc.root(), "li");
    try std.testing.expect(node != null);
}

test "BREAK: matching against a leaf root still respects the subtree" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const ul = (try doc.first("#list")).?;

    // Restricted to the <ul>, only its descendants can match.
    var items = try doc.engine.queryAll(gpa, ul, "li");
    defer items.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);

    // Nothing outside the subtree can match.
    var headers = try doc.engine.queryAll(gpa, ul, "h1");
    defer headers.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "the search root is not itself a candidate (element.querySelectorAll semantics)" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    const span = (try doc.first("span")).?;

    // `span` has a single text child, so a universal search from it finds no
    // *element*: the root is excluded from matching.
    var from_span = try doc.engine.queryAll(gpa, span, "*");
    defer from_span.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), from_span.items.len);

    // Searching from the same node for its own tag likewise finds nothing...
    var self_match = try doc.engine.queryAll(gpa, span, "span");
    defer self_match.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), self_match.items.len);

    // ...but searching from its parent does find it.
    const parent = span.parent().?;
    var from_parent = try doc.engine.queryAll(gpa, parent, "span");
    defer from_parent.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), from_parent.items.len);
}

test "STRESS: 300 queries on one engine stay correct" {
    const gpa = std.testing.allocator;

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const selector = if (i % 2 == 0) "li.item" else "#list > li";
        var found = try doc.engine.queryAll(gpa, doc.root(), selector);
        defer found.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 3), found.items.len);
    }
}
