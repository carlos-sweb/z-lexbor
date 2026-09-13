//! Idiomatic wrapper over lexbor's CSS parser (selector lists).

const std = @import("std");
const c = @import("sys/root.zig").c;
const status = @import("status.zig");
const conv = @import("internal/convert.zig");

/// A parsed CSS selector list.
///
/// Owned by the `Parser` that produced it: the list is allocated in the
/// parser's memory pool and is invalidated by `Parser.deinit`.
pub const SelectorList = struct {
    ptr: [*c]c.lxb_css_selector_list_t,

    pub fn raw(self: SelectorList) [*c]c.lxb_css_selector_list_t {
        return self.ptr;
    }
};

/// Owns a CSS parser and everything it allocates.
pub const Parser = struct {
    ptr: [*c]c.lxb_css_parser_t,

    pub fn create() status.Error!Parser {
        const ptr = c.lxb_css_parser_create();
        if (ptr == null) return error.OutOfMemory;
        return .{ .ptr = ptr };
    }

    /// `tkz` is optional; lexbor allocates its own tokenizer when null.
    pub fn init(self: *Parser) status.Error!void {
        try status.check(c.lxb_css_parser_init(self.ptr, null));
    }

    pub fn createInit() status.Error!Parser {
        var self = try create();
        errdefer self.deinit();
        try self.init();
        return self;
    }

    pub fn deinit(self: *Parser) void {
        if (self.ptr != null) {
            _ = c.lxb_css_parser_destroy(self.ptr, true);
            self.ptr = null;
        }
    }

    pub fn raw(self: *Parser) [*c]c.lxb_css_parser_t {
        return self.ptr;
    }

    /// Parses a selector list such as `"div.a > p, #id"`.
    pub fn parseSelectorList(self: *Parser, source: []const u8) status.Error!SelectorList {
        const list = c.lxb_css_selectors_parse(self.ptr, conv.ptr(source), source.len);
        if (list == null) return error.LexborError;
        return .{ .ptr = list };
    }
};

test "CSS parser is created, initialized and destroyed" {
    var parser = try Parser.createInit();
    defer parser.deinit();
    try std.testing.expect(parser.raw() != null);
}

test "parses a selector list" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const list = try parser.parseSelectorList("div.a > p, #id");
    try std.testing.expect(list.raw() != null);
}
