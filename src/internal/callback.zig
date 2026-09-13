//! Bridges lexbor's `callconv(.c)` callbacks to Zig.
//!
//! lexbor reports callback outcomes through `lxb_status_t`, so a Zig error
//! cannot propagate out of a callback directly. The pattern used here is to
//! stash the error in the context struct and re-surface it once the lexbor call
//! returns.

const std = @import("std");
const c = @import("../sys/root.zig").c;
const status = @import("../status.zig");

fn chunk(data: [*c]const c.lxb_char_t, len: usize) []const u8 {
    if (data == null or len == 0) return &.{};
    return data[0..len];
}

/// A `std.Io.Writer` sink for lexbor's serialize callbacks.
///
/// ```zig
/// var sink = WriterSink{ .writer = &out.interface };
/// const raw = c.lxb_html_serialize_tree_cb(node, WriterSink.callback, &sink);
/// try sink.check(raw);
/// ```
pub const WriterSink = struct {
    writer: *std.Io.Writer,
    /// First write error seen, if any.
    err: ?anyerror = null,

    pub fn callback(
        data: [*c]const c.lxb_char_t,
        len: usize,
        ctx: ?*anyopaque,
    ) callconv(.c) c.lxb_status_t {
        const self: *WriterSink = @ptrCast(@alignCast(ctx orelse return status.raw_error));
        self.writer.writeAll(chunk(data, len)) catch |e| {
            self.err = e;
            return status.raw_error;
        };
        return status.raw_ok;
    }

    /// Re-surfaces a write error captured during the lexbor call, otherwise
    /// validates the raw status.
    ///
    /// The inferred error set is the union of the writer's errors and
    /// `status.Error`.
    pub fn check(self: *const WriterSink, raw: c.lxb_status_t) !void {
        if (self.err) |e| return e;
        try status.check(raw);
    }
};

/// Collects serialized output into a caller-provided fixed buffer, stopping
/// once the buffer is full. Useful for small, allocation-free serializations.
pub const FixedSink = struct {
    buf: []u8,
    len: usize = 0,
    /// Set when output had to be truncated.
    truncated: bool = false,

    pub fn callback(
        data: [*c]const c.lxb_char_t,
        len: usize,
        ctx: ?*anyopaque,
    ) callconv(.c) c.lxb_status_t {
        const self: *FixedSink = @ptrCast(@alignCast(ctx orelse return status.raw_error));
        const bytes = chunk(data, len);
        const room = self.buf.len - self.len;
        const n = @min(bytes.len, room);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
        if (n < bytes.len) self.truncated = true;
        return status.raw_ok;
    }

    pub fn written(self: *const FixedSink) []const u8 {
        return self.buf[0..self.len];
    }
};

test "FixedSink collects output and reports truncation" {
    var buf: [8]u8 = undefined;

    var sink = FixedSink{ .buf = &buf };
    try std.testing.expectEqual(status.raw_ok, FixedSink.callback("abc".ptr, 3, &sink));
    try std.testing.expectEqualStrings("abc", sink.written());
    try std.testing.expect(!sink.truncated);

    try std.testing.expectEqual(status.raw_ok, FixedSink.callback("defghij".ptr, 7, &sink));
    try std.testing.expectEqualStrings("abcdefgh", sink.written());
    try std.testing.expect(sink.truncated);
}

test "FixedSink tolerates a null chunk" {
    var buf: [4]u8 = undefined;
    var sink = FixedSink{ .buf = &buf };
    try std.testing.expectEqual(status.raw_ok, FixedSink.callback(null, 0, &sink));
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "WriterSink writes into a std.Io.Writer" {
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var sink = WriterSink{ .writer = &writer };

    try std.testing.expectEqual(status.raw_ok, WriterSink.callback("hello ".ptr, 6, &sink));
    try std.testing.expectEqual(status.raw_ok, WriterSink.callback("world".ptr, 5, &sink));
    try sink.check(status.raw_ok);

    try std.testing.expectEqualStrings("hello world", std.Io.Writer.buffered(&writer));
}
