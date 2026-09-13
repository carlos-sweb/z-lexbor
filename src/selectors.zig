//! CSS selector matching: the `querySelector` / `querySelectorAll` core of
//! lexbor, in Zig.
//!
//! ```zig
//! var engine = try selectors.Engine.createInit();
//! defer engine.deinit();
//!
//! var found = try engine.queryAll(std.testing.allocator, root, "div.a > p");
//! defer found.deinit(std.testing.allocator);
//! ```

const std = @import("std");
const c = @import("sys/root.zig").c;
const status = @import("status.zig");
const conv = @import("internal/convert.zig");
pub const css = @import("css.zig");
pub const dom = @import("dom.zig");

pub const SelectorList = css.SelectorList;

/// Errors a match callback may return.
///
/// `StopIteration` is not a failure: it asks the engine to stop the search
/// cleanly. It is the idiomatic replacement for returning
/// `LXB_STATUS_STOP` from a raw lexbor callback.
pub const MatchError = status.Error || error{StopIteration};

/// Owns a CSS parser plus a selector engine, so a caller can compile selectors
/// and match them without managing two lexbor objects.
pub const Engine = struct {
    css_parser: css.Parser,
    selectors: [*c]c.lxb_selectors_t,

    pub fn createInit() status.Error!Engine {
        var parser = try css.Parser.createInit();
        errdefer parser.deinit();

        const sel = c.lxb_selectors_create();
        if (sel == null) return error.OutOfMemory;
        errdefer _ = c.lxb_selectors_destroy(sel, true);

        try status.check(c.lxb_selectors_init(sel));

        return .{ .css_parser = parser, .selectors = sel };
    }

    pub fn deinit(self: *Engine) void {
        if (self.selectors != null) {
            _ = c.lxb_selectors_destroy(self.selectors, true);
            self.selectors = null;
        }
        self.css_parser.deinit();
    }

    /// Compiles a selector list. The result borrows the engine's CSS parser.
    pub fn compile(self: *Engine, source: []const u8) status.Error!SelectorList {
        return self.css_parser.parseSelectorList(source);
    }

    /// Invokes `on_match` for every node under `root` matching `list`.
    ///
    /// Returning `error.StopIteration` from `on_match` ends the search
    /// cleanly (this is the idiomatic replacement for lexbor's
    /// `LXB_STATUS_STOP` callback protocol).
    pub fn find(
        self: *Engine,
        root: dom.Node,
        list: SelectorList,
        ctx: anytype,
        comptime on_match: fn (@TypeOf(ctx), dom.Node) MatchError!void,
    ) !void {
        const Bridge = struct {
            ctx: @TypeOf(ctx),
            err: ?MatchError = null,
            stopped: bool = false,

            fn callback(
                node: [*c]c.lxb_dom_node_t,
                spec: c.lxb_css_selector_specificity_t,
                raw_ctx: ?*anyopaque,
            ) callconv(.c) c.lxb_status_t {
                _ = spec;
                const self_: *@This() = @ptrCast(@alignCast(raw_ctx orelse return status.raw_error));

                on_match(self_.ctx, dom.Node{ .ptr = node }) catch |e| {
                    if (e == error.StopIteration) {
                        self_.stopped = true;
                        return c.LXB_STATUS_STOP;
                    }
                    self_.err = e;
                    return status.raw_error;
                };
                return status.raw_ok;
            }
        };

        var bridge = Bridge{ .ctx = ctx };

        const raw = c.lxb_selectors_find(
            self.selectors,
            root.raw(),
            list.raw(),
            Bridge.callback,
            &bridge,
        );

        if (bridge.err) |e| return e;
        if (bridge.stopped) return;

        try status.check(raw);
    }

    /// Compiles `source` and collects every match under `root`.
    ///
    /// The returned list owns its backing memory.
    pub fn queryAll(
        self: *Engine,
        allocator: std.mem.Allocator,
        root: dom.Node,
        source: []const u8,
    ) !std.ArrayList(dom.Node) {
        const list = try self.compile(source);

        const Collector = struct {
            out: *std.ArrayList(dom.Node),
            allocator: std.mem.Allocator,

            fn onMatch(self_: *@This(), node: dom.Node) MatchError!void {
                try self_.out.append(self_.allocator, node);
            }
        };

        var out: std.ArrayList(dom.Node) = .empty;
        errdefer out.deinit(allocator);

        var collector = Collector{ .out = &out, .allocator = allocator };
        try self.find(root, list, &collector, Collector.onMatch);

        return out;
    }

    /// Returns the first node matching `source`, or null.
    pub fn queryFirst(
        self: *Engine,
        root: dom.Node,
        source: []const u8,
    ) !?dom.Node {
        const list = try self.compile(source);

        const First = struct {
            found: ?dom.Node = null,

            fn onMatch(self_: *@This(), node: dom.Node) MatchError!void {
                self_.found = node;
                return error.StopIteration;
            }
        };

        var first = First{};
        try self.find(root, list, &first, First.onMatch);
        return first.found;
    }
};

test "queryAll selects by tag, class and descendant combinator" {
    const html = @import("html.zig");

    var parser = try html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse(
        "<div class=\"a\"><p id=\"one\">1</p><p id=\"two\">2</p></div>" ++
            "<div class=\"b\"><p id=\"three\">3</p></div>",
    );
    const root = doc.rootNode().?;

    var engine = try Engine.createInit();
    defer engine.deinit();

    // plain type selector
    var all_p = try engine.queryAll(std.testing.allocator, root, "p");
    defer all_p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), all_p.items.len);

    // class + descendant combinator
    var in_a = try engine.queryAll(std.testing.allocator, root, "div.a > p");
    defer in_a.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), in_a.items.len);

    // id selector
    var by_id = try engine.queryAll(std.testing.allocator, root, "#three");
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), by_id.items.len);
    try std.testing.expectEqualStrings("three", by_id.items[0].asElement().?.id().?);

    // attribute selector
    var by_attr = try engine.queryAll(std.testing.allocator, root, "div[class=b] p");
    defer by_attr.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), by_attr.items.len);
    try std.testing.expectEqualStrings("3", by_attr.items[0].textContent());
}

test "queryFirst stops at the first match" {
    const html = @import("html.zig");

    var parser = try html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<ul><li>a</li><li>b</li></ul>");
    const root = doc.rootNode().?;

    var engine = try Engine.createInit();
    defer engine.deinit();

    const first = (try engine.queryFirst(root, "li")).?;
    try std.testing.expectEqualStrings("a", first.textContent());

    try std.testing.expectEqual(@as(?dom.Node, null), try engine.queryFirst(root, "table"));
}

test "find reports errors from the match callback" {
    const html = @import("html.zig");

    var parser = try html.Parser.createInit();
    defer parser.deinit();
    const doc = try parser.parse("<p>x</p>");
    const root = doc.rootNode().?;

    var engine = try Engine.createInit();
    defer engine.deinit();

    const Failing = struct {
        fn onMatch(_: *@This(), _: dom.Node) MatchError!void {
            return error.OutOfMemory;
        }
    };

    var ctx = Failing{};
    const list = try engine.compile("p");
    try std.testing.expectError(error.OutOfMemory, engine.find(root, list, &ctx, Failing.onMatch));
}
