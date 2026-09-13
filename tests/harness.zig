//! Shared harness: a parsed document plus a ready selector engine.
//!
//! Ownership note: `Parser` owns the document and `Engine` owns its CSS/selector
//! state, so both must outlive every `Node` / `Element` derived from them. The
//! harness keeps them together and destroys them in the right order.

const std = @import("std");
const lexbor = @import("z_lexbor");

pub const Doc = struct {
    parser: lexbor.html.Parser,
    document: lexbor.html.Document,
    engine: lexbor.selectors.Engine,

    pub fn init(html: []const u8) !Doc {
        var parser = try lexbor.html.Parser.createInit();
        errdefer parser.deinit();

        const document = try parser.parse(html);

        var engine = try lexbor.selectors.Engine.createInit();
        errdefer engine.deinit();

        return .{ .parser = parser, .document = document, .engine = engine };
    }

    pub fn deinit(self: *Doc) void {
        self.engine.deinit();
        self.parser.deinit();
    }

    pub fn root(self: *const Doc) lexbor.dom.Node {
        return self.document.rootNode().?;
    }

    /// Nullable form, for tests that assert on presence rather than assuming it.
    pub fn rootNode(self: *const Doc) ?lexbor.dom.Node {
        return self.document.rootNode();
    }

    pub fn first(self: *Doc, selector: []const u8) !?lexbor.dom.Node {
        return self.engine.queryFirst(self.root(), selector);
    }

    pub fn all(
        self: *Doc,
        allocator: std.mem.Allocator,
        selector: []const u8,
    ) !std.ArrayList(lexbor.dom.Node) {
        return self.engine.queryAll(allocator, self.root(), selector);
    }

    /// Collects the tag name of every element, in document order.
    pub fn tagNames(
        self: *const Doc,
        allocator: std.mem.Allocator,
    ) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);

        var it = self.root().descendants();
        while (it.next()) |node| {
            if (node.asElement()) |el| try out.append(allocator, el.localName());
        }
        return out;
    }
};

/// Parses and runs `body`, guaranteeing teardown. Avoids repeating
/// `defer doc.deinit()` in every test.
pub fn withDoc(
    html: []const u8,
    ctx: anytype,
    comptime body: fn (@TypeOf(ctx), *Doc) anyerror!void,
) !void {
    var doc = try Doc.init(html);
    defer doc.deinit();
    try body(ctx, &doc);
}
