//! Exhaustive tests for the `lxb_status_t` -> `Status` / `Error` mapping.
//!
//! The mapping is the backbone of every `try` in this wrapper: if a status is
//! misclassified, errors become silent successes (or vice versa). These tests
//! therefore check *every* enumerator, not a sample.

const std = @import("std");
const lexbor = @import("z_lexbor");
const c = lexbor.sys.c;
const status = lexbor.status;

/// Every lexbor status, paired with the Zig enum member it must map to.
const cases = [_]struct { raw: c.lxb_status_t, expected: status.Status, is_error: bool }{
    .{ .raw = c.LXB_STATUS_OK, .expected = .ok, .is_error = false },
    .{ .raw = c.LXB_STATUS_ERROR, .expected = .err, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_MEMORY_ALLOCATION, .expected = .out_of_memory, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_OBJECT_IS_NULL, .expected = .object_is_null, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_SMALL_BUFFER, .expected = .small_buffer_error, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_INCOMPLETE_OBJECT, .expected = .incomplete_object, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_NO_FREE_SLOT, .expected = .no_free_slot, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_TOO_SMALL_SIZE, .expected = .too_small_size, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_NOT_EXISTS, .expected = .not_exists, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_WRONG_ARGS, .expected = .wrong_args, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_WRONG_STAGE, .expected = .wrong_stage, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_UNEXPECTED_RESULT, .expected = .unexpected_result, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_UNEXPECTED_DATA, .expected = .unexpected_data, .is_error = true },
    .{ .raw = c.LXB_STATUS_ERROR_OVERFLOW, .expected = .overflow, .is_error = true },
    .{ .raw = c.LXB_STATUS_CONTINUE, .expected = .continue_, .is_error = false },
    .{ .raw = c.LXB_STATUS_SMALL_BUFFER, .expected = .small_buffer, .is_error = false },
    .{ .raw = c.LXB_STATUS_ABORTED, .expected = .aborted, .is_error = true },
    .{ .raw = c.LXB_STATUS_STOPPED, .expected = .stopped, .is_error = false },
    .{ .raw = c.LXB_STATUS_NEXT, .expected = .next, .is_error = false },
    .{ .raw = c.LXB_STATUS_STOP, .expected = .stop, .is_error = false },
    .{ .raw = c.LXB_STATUS_WARNING, .expected = .warning, .is_error = false },
    .{ .raw = c.LXB_STATUS_SKIPPED, .expected = .skipped, .is_error = false },
};

test "every LXB_STATUS_* maps to the expected Status member" {
    for (cases) |case| {
        const got = status.fromRaw(@intCast(case.raw));
        try std.testing.expectEqual(case.expected, got);
        // Round-trips back to the raw value.
        try std.testing.expectEqual(
            @as(c.lxb_status_t, @intCast(case.raw)),
            @intFromEnum(got),
        );
    }
}

test "enumeration is complete: every Status member is covered by the table" {
    // If lexbor grows a new status this fails, forcing the table (and the
    // switch statements in status.zig) to be updated.
    try std.testing.expectEqual(std.enums.values(status.Status).len, cases.len);
}

test "isError agrees with the table for every status" {
    for (cases) |case| {
        try std.testing.expectEqual(
            case.is_error,
            status.isError(@intCast(case.raw)),
        );
    }
}

test "check succeeds exactly for the non-error statuses" {
    for (cases) |case| {
        const raw: c.lxb_status_t = @intCast(case.raw);
        if (case.is_error) {
            try std.testing.expectError(error_expected(case.expected), status.check(raw));
        } else {
            try status.check(raw);
        }
    }
}

/// The error a given `.err`-like status must produce.
fn error_expected(s: status.Status) status.Error {
    return switch (s) {
        .err => error.LexborError,
        .out_of_memory => error.OutOfMemory,
        .object_is_null => error.ObjectIsNull,
        .small_buffer_error => error.SmallBuffer,
        .incomplete_object => error.IncompleteObject,
        .no_free_slot => error.NoFreeSlot,
        .too_small_size => error.TooSmallSize,
        .not_exists => error.NotExists,
        .wrong_args => error.WrongArgs,
        .wrong_stage => error.WrongStage,
        .unexpected_result => error.UnexpectedResult,
        .unexpected_data => error.UnexpectedData,
        .overflow => error.Overflow,
        .aborted => error.Aborted,
        else => unreachable,
    };
}

test "check maps each failure to its own distinct error" {
    // Two different failure statuses must never collapse into one error,
    // otherwise `try` would hide which stage failed.
    try std.testing.expectError(error.LexborError, status.check(c.LXB_STATUS_ERROR));
    try std.testing.expectError(error.OutOfMemory, status.check(c.LXB_STATUS_ERROR_MEMORY_ALLOCATION));
    try std.testing.expectError(error.ObjectIsNull, status.check(c.LXB_STATUS_ERROR_OBJECT_IS_NULL));
    try std.testing.expectError(error.SmallBuffer, status.check(c.LXB_STATUS_ERROR_SMALL_BUFFER));
    try std.testing.expectError(error.IncompleteObject, status.check(c.LXB_STATUS_ERROR_INCOMPLETE_OBJECT));
    try std.testing.expectError(error.NoFreeSlot, status.check(c.LXB_STATUS_ERROR_NO_FREE_SLOT));
    try std.testing.expectError(error.TooSmallSize, status.check(c.LXB_STATUS_ERROR_TOO_SMALL_SIZE));
    try std.testing.expectError(error.NotExists, status.check(c.LXB_STATUS_ERROR_NOT_EXISTS));
    try std.testing.expectError(error.WrongArgs, status.check(c.LXB_STATUS_ERROR_WRONG_ARGS));
    try std.testing.expectError(error.WrongStage, status.check(c.LXB_STATUS_ERROR_WRONG_STAGE));
    try std.testing.expectError(error.UnexpectedResult, status.check(c.LXB_STATUS_ERROR_UNEXPECTED_RESULT));
    try std.testing.expectError(error.UnexpectedData, status.check(c.LXB_STATUS_ERROR_UNEXPECTED_DATA));
    try std.testing.expectError(error.Overflow, status.check(c.LXB_STATUS_ERROR_OVERFLOW));
    try std.testing.expectError(error.Aborted, status.check(c.LXB_STATUS_ABORTED));
}

test "control signals never become errors (callbacks rely on this)" {
    // A selector callback returns STOP to end the search; if `check` treated it
    // as a failure every early-exit would surface as an error.
    try status.check(c.LXB_STATUS_STOP);
    try status.check(c.LXB_STATUS_NEXT);
    try status.check(c.LXB_STATUS_CONTINUE);
    try status.check(c.LXB_STATUS_STOPPED);
    try status.check(c.LXB_STATUS_SKIPPED);
    try status.check(c.LXB_STATUS_SMALL_BUFFER);
    try status.check(c.LXB_STATUS_WARNING);
}

test "unknown status values degrade to .err instead of trapping" {
    const unknown = [_]c.lxb_status_t{ 0x00FF, 0x1000, 0x7FFF, 0xFFFF, 0xFFFF_FFFF };
    for (unknown) |raw| {
        try std.testing.expectEqual(status.Status.err, status.fromRaw(raw));
        // And `check` reports a generic error rather than panicking.
        try std.testing.expectError(error.LexborError, status.check(raw));
        try std.testing.expect(status.isError(raw));
    }
}

test "full sweep: check and isError never panic for any raw value" {
    // Broken/adversarial input can make a C library return garbage; the
    // mapping must stay total. 0..4096 plus the extremes.
    var raw: u32 = 0;
    while (raw < 4096) : (raw += 1) {
        const v: c.lxb_status_t = @intCast(raw);
        const mapped = status.fromRaw(v);
        _ = status.isError(v);
        _ = status.name(mapped);
        _ = status.check(v) catch {};
    }

    const extremes = [_]c.lxb_status_t{ 0, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF };
    for (extremes) |v| {
        _ = status.isError(v);
        _ = status.name(status.fromRaw(v));
        _ = status.check(v) catch {};
    }
}

test "name() yields the lexbor enumerator spelling" {
    try std.testing.expectEqualStrings("LXB_STATUS_OK", status.name(.ok));
    try std.testing.expectEqualStrings("LXB_STATUS_ERROR_MEMORY_ALLOCATION", status.name(.out_of_memory));
    try std.testing.expectEqualStrings("LXB_STATUS_WARNING", status.name(.warning));
    try std.testing.expectEqualStrings("LXB_STATUS_SKIPPED", status.name(.skipped));

    for (cases) |case| {
        const n = status.name(case.expected);
        try std.testing.expect(std.mem.startsWith(u8, n, "LXB_STATUS_"));
    }
}

test "try on check() propagates the exact error through the call stack" {
    // Demonstrates how Zig composes the typed error set: the innermost failure
    // survives two levels of `try` unchanged.
    const helpers = struct {
        fn inner(raw: c.lxb_status_t) status.Error!void {
            try status.check(raw);
        }
        fn outer(raw: c.lxb_status_t) status.Error!void {
            try inner(raw);
        }
    };

    try std.testing.expectError(
        error.NotExists,
        helpers.outer(c.LXB_STATUS_ERROR_NOT_EXISTS),
    );
    try helpers.outer(c.LXB_STATUS_OK);
}

test "exhaustive switch over status.Error compiles (error set is closed)" {
    // If the Error set grows, this switch stops compiling -- that is the
    // guarantee that callers cannot silently ignore a new failure mode.
    const f = struct {
        fn describe(err: status.Error) []const u8 {
            return switch (err) {
                error.LexborError => "generic",
                error.OutOfMemory => "oom",
                error.ObjectIsNull => "null",
                error.SmallBuffer => "small buffer",
                error.IncompleteObject => "incomplete",
                error.NoFreeSlot => "no free slot",
                error.TooSmallSize => "too small",
                error.NotExists => "not exists",
                error.WrongArgs => "wrong args",
                error.WrongStage => "wrong stage",
                error.UnexpectedResult => "unexpected result",
                error.UnexpectedData => "unexpected data",
                error.Overflow => "overflow",
                error.Aborted => "aborted",
            };
        }
    };

    try std.testing.expectEqualStrings("oom", f.describe(error.OutOfMemory));
    try std.testing.expectEqualStrings("aborted", f.describe(error.Aborted));
}
