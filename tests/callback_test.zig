//! Tests for the callback bridges, including how write failures cross the
//! C boundary and come back out as Zig errors.

const std = @import("std");
const lexbor = @import("z_lexbor");
const c = lexbor.sys.c;
const cb = lexbor.internal.callback;
const status = lexbor.status;

test "FixedSink collects every chunk in order" {
    var buf: [64]u8 = undefined;
    var sink = cb.FixedSink{ .buf = &buf };

    try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback("abc".ptr, 3, &sink));
    try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback("de".ptr, 2, &sink));
    try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback("f".ptr, 1, &sink));

    try std.testing.expectEqualStrings("abcdef", sink.written());
    try std.testing.expect(!sink.truncated);
}

test "FixedSink reports truncation instead of overrunning the buffer" {
    var buf: [4]u8 = undefined;
    var sink = cb.FixedSink{ .buf = &buf };

    try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback("abcdefgh".ptr, 8, &sink));

    try std.testing.expectEqualStrings("abcd", sink.written());
    try std.testing.expect(sink.truncated);
    // The sink must never write past `buf`.
    try std.testing.expect(sink.len <= buf.len);
}

test "FixedSink: a zero-capacity buffer stays safe forever" {
    var sink = cb.FixedSink{ .buf = &.{} };

    // Repeatedly pushing data must not advance `len` past 0 or corrupt memory.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback("xxxx".ptr, 4, &sink));
    }
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expect(sink.truncated);
}

test "FixedSink: a null chunk is a no-op" {
    var buf: [8]u8 = undefined;
    var sink = cb.FixedSink{ .buf = &buf };

    try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback(null, 0, &sink));
    try std.testing.expectEqual(status.raw_ok, cb.FixedSink.callback(null, 99, &sink));
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "FixedSink: a null context is rejected, not dereferenced" {
    try std.testing.expectEqual(
        status.raw_error,
        cb.FixedSink.callback("x".ptr, 1, null),
    );
}

test "WriterSink forwards to a std.Io.Writer" {
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var sink = cb.WriterSink{ .writer = &writer };

    try std.testing.expectEqual(status.raw_ok, cb.WriterSink.callback("hello ".ptr, 6, &sink));
    try std.testing.expectEqual(status.raw_ok, cb.WriterSink.callback("world".ptr, 5, &sink));

    try sink.check(status.raw_ok);
    try std.testing.expectEqualStrings("hello world", std.Io.Writer.buffered(&writer));
}

test "WriterSink into an allocating writer" {
    const gpa = std.testing.allocator;

    var allocating = std.Io.Writer.Allocating.init(gpa);
    defer allocating.deinit();

    var sink = cb.WriterSink{ .writer = &allocating.writer };
    try std.testing.expectEqual(status.raw_ok, cb.WriterSink.callback("allocated".ptr, 9, &sink));
    try sink.check(status.raw_ok);

    try std.testing.expectEqualStrings("allocated", allocating.written());
}

test "BREAK: a writer that runs out of room surfaces WriteFailed through try" {
    // This is the core of "how does Zig respond with try": the failure happens
    // inside a callconv(.c) callback, where a Zig error cannot be returned, so
    // it is stashed and re-raised by check().
    var tiny: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&tiny);
    var sink = cb.WriterSink{ .writer = &writer };

    const raw = cb.WriterSink.callback("this will not fit".ptr, 17, &sink);
    try std.testing.expectEqual(status.raw_error, raw);

    // The stashed error wins over the (generic) raw status.
    try std.testing.expectError(error.WriteFailed, sink.check(raw));
}

test "BREAK: the writer error is also raised when the raw status is OK" {
    var tiny: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&tiny);
    var sink = cb.WriterSink{ .writer = &writer };

    _ = cb.WriterSink.callback("xx".ptr, 2, &sink);

    // Even a success status must not mask the captured write failure.
    try std.testing.expectError(error.WriteFailed, sink.check(status.raw_ok));
}

test "BREAK: only the first write error is kept, later chunks cannot clear it" {
    var tiny: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&tiny);
    var sink = cb.WriterSink{ .writer = &writer };

    _ = cb.WriterSink.callback("first chunk fails".ptr, 17, &sink);
    const first = sink.err;
    try std.testing.expect(first != null);

    _ = cb.WriterSink.callback("second".ptr, 6, &sink);
    // The original error is preserved, not overwritten or cleared.
    try std.testing.expectEqual(first.?, sink.err.?);
    try std.testing.expectError(error.WriteFailed, sink.check(status.raw_ok));
}

test "WriterSink: a null context is rejected, not dereferenced" {
    try std.testing.expectEqual(status.raw_error, cb.WriterSink.callback("x".ptr, 1, null));
}

test "WriterSink: check passes through lexbor failures when writing succeeded" {
    var storage: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var sink = cb.WriterSink{ .writer = &writer };

    try sink.check(c.LXB_STATUS_OK);
    try std.testing.expectError(error.ObjectIsNull, sink.check(c.LXB_STATUS_ERROR_OBJECT_IS_NULL));
    try std.testing.expectError(error.OutOfMemory, sink.check(c.LXB_STATUS_ERROR_MEMORY_ALLOCATION));
    // Control signals still pass.
    try sink.check(c.LXB_STATUS_STOP);
}

test "WriterSink: a null chunk is written as nothing" {
    var storage: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var sink = cb.WriterSink{ .writer = &writer };

    try std.testing.expectEqual(status.raw_ok, cb.WriterSink.callback(null, 0, &sink));
    try sink.check(status.raw_ok);
    try std.testing.expectEqualStrings("", std.Io.Writer.buffered(&writer));
}

test "STRESS: many small chunks concatenate exactly" {
    var buf: [1024]u8 = undefined;
    var sink = cb.FixedSink{ .buf = &buf };

    const chunk = "0123456789";
    const times = 100;
    var i: usize = 0;
    while (i < times) : (i += 1) {
        try std.testing.expectEqual(
            status.raw_ok,
            cb.FixedSink.callback(chunk.ptr, chunk.len, &sink),
        );
    }

    try std.testing.expectEqual(chunk.len * times, sink.len);
    var j: usize = 0;
    while (j < times) : (j += 1) {
        try std.testing.expectEqualStrings(chunk, buf[j * chunk.len ..][0..chunk.len]);
    }
}
