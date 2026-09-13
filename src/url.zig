//! Idiomatic wrapper over lexbor's WHATWG URL parser.

const std = @import("std");
const c = @import("sys/root.zig").c;
const status = @import("status.zig");
const conv = @import("internal/convert.zig");
const callback = @import("internal/callback.zig");

/// A borrowed parsed URL.
///
/// Owned by the `Parser` that produced it; invalidated by `Parser.deinit`.
pub const Url = struct {
    ptr: [*c]c.lxb_url_t,

    pub fn raw(self: Url) [*c]c.lxb_url_t {
        return self.ptr;
    }

    /// Writes the serialized URL (WHATWG serialization) into `writer`.
    pub fn serialize(self: Url, writer: *std.Io.Writer, exclude_fragment: bool) !void {
        var sink = callback.WriterSink{ .writer = writer };
        const st = c.lxb_url_serialize(self.ptr, callback.WriterSink.callback, &sink, exclude_fragment);
        try sink.check(st);
    }
};

/// Owns a URL parser and the URLs it allocates.
pub const Parser = struct {
    ptr: [*c]c.lxb_url_parser_t,

    pub fn create() status.Error!Parser {
        const ptr = c.lxb_url_parser_create();
        if (ptr == null) return error.OutOfMemory;
        return .{ .ptr = ptr };
    }

    /// `mraw` is optional; lexbor allocates its own memory pool when null.
    pub fn init(self: *Parser) status.Error!void {
        try status.check(c.lxb_url_parser_init(self.ptr, null));
    }

    pub fn createInit() status.Error!Parser {
        var self = try create();
        errdefer self.deinit();
        try self.init();
        return self;
    }

    pub fn deinit(self: *Parser) void {
        if (self.ptr != null) {
            _ = c.lxb_url_parser_destroy(self.ptr, true);
            self.ptr = null;
        }
    }

    pub fn raw(self: *Parser) [*c]c.lxb_url_parser_t {
        return self.ptr;
    }

    /// Parses `data`, optionally relative to `base`.
    pub fn parse(self: *Parser, base: ?Url, data: []const u8) status.Error!Url {
        const base_ptr: [*c]const c.lxb_url_t = if (base) |b| b.ptr else null;
        const url = c.lxb_url_parse(self.ptr, base_ptr, conv.ptr(data), data.len);
        if (url == null) return error.LexborError;
        return .{ .ptr = url };
    }

    /// Convenience: serializes a freshly parsed URL into `writer`.
    pub fn parseTo(
        self: *Parser,
        base: ?Url,
        data: []const u8,
        writer: *std.Io.Writer,
    ) !void {
        const url = try self.parse(base, data);
        try url.serialize(writer, false);
    }
};

test "parses and re-serializes an absolute URL" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const url = try parser.parse(null, "https://user@example.com:8080/a/b?q=1#frag");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try url.serialize(&writer, false);

    try std.testing.expectEqualStrings(
        "https://user@example.com:8080/a/b?q=1#frag",
        std.Io.Writer.buffered(&writer),
    );
}

test "exclude_fragment drops the fragment" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const url = try parser.parse(null, "https://example.com/x#section");

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try url.serialize(&writer, true);

    try std.testing.expectEqualStrings("https://example.com/x", std.Io.Writer.buffered(&writer));
}

test "resolves a relative URL against a base" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    const base = try parser.parse(null, "https://example.com/dir/page.html");

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try parser.parseTo(base, "../other?x=1", &writer);

    try std.testing.expectEqualStrings("https://example.com/other?x=1", std.Io.Writer.buffered(&writer));
}

test "invalid input returns an error instead of trapping" {
    var parser = try Parser.createInit();
    defer parser.deinit();

    // No base and not an absolute URL.
    try std.testing.expectError(error.LexborError, parser.parse(null, "not a url"));
}
