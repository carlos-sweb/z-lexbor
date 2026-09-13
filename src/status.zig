//! Mapping between lexbor's `lxb_status_t` and Zig.
//!
//! lexbor reports every outcome through a single `lxb_status_t` return value.
//! This module turns that into a typed `Status` enum and a Zig error set.
//!
//! Policy for `check`:
//!   * `ok` and `warning` are successes.
//!   * `continue_`, `next`, `stop`, `stopped` and `skipped` are *control
//!     signals*, not failures: lexbor uses them to let a callback drive
//!     iteration (selectors, walkers, incremental parsing). They pass.
//!   * `small_buffer` means "call me again with a bigger buffer" and also
//!     passes; `small_buffer_error` (`LXB_STATUS_ERROR_SMALL_BUFFER`) is a
//!     genuine failure.
//!   * everything else maps to a distinct Zig error.

const std = @import("std");
const c = @import("sys/root.zig").c;

/// Every `LXB_STATUS_*` code, as a typed Zig enum.
pub const Status = enum(c.lxb_status_t) {
    ok = @intCast(c.LXB_STATUS_OK),
    err = @intCast(c.LXB_STATUS_ERROR),
    out_of_memory = @intCast(c.LXB_STATUS_ERROR_MEMORY_ALLOCATION),
    object_is_null = @intCast(c.LXB_STATUS_ERROR_OBJECT_IS_NULL),
    small_buffer_error = @intCast(c.LXB_STATUS_ERROR_SMALL_BUFFER),
    incomplete_object = @intCast(c.LXB_STATUS_ERROR_INCOMPLETE_OBJECT),
    no_free_slot = @intCast(c.LXB_STATUS_ERROR_NO_FREE_SLOT),
    too_small_size = @intCast(c.LXB_STATUS_ERROR_TOO_SMALL_SIZE),
    not_exists = @intCast(c.LXB_STATUS_ERROR_NOT_EXISTS),
    wrong_args = @intCast(c.LXB_STATUS_ERROR_WRONG_ARGS),
    wrong_stage = @intCast(c.LXB_STATUS_ERROR_WRONG_STAGE),
    unexpected_result = @intCast(c.LXB_STATUS_ERROR_UNEXPECTED_RESULT),
    unexpected_data = @intCast(c.LXB_STATUS_ERROR_UNEXPECTED_DATA),
    overflow = @intCast(c.LXB_STATUS_ERROR_OVERFLOW),
    continue_ = @intCast(c.LXB_STATUS_CONTINUE),
    small_buffer = @intCast(c.LXB_STATUS_SMALL_BUFFER),
    aborted = @intCast(c.LXB_STATUS_ABORTED),
    stopped = @intCast(c.LXB_STATUS_STOPPED),
    next = @intCast(c.LXB_STATUS_NEXT),
    stop = @intCast(c.LXB_STATUS_STOP),
    warning = @intCast(c.LXB_STATUS_WARNING),
    skipped = @intCast(c.LXB_STATUS_SKIPPED),
};

/// Errors a lexbor call can produce.
pub const Error = error{
    /// Generic `LXB_STATUS_ERROR`.
    LexborError,
    OutOfMemory,
    ObjectIsNull,
    SmallBuffer,
    IncompleteObject,
    NoFreeSlot,
    TooSmallSize,
    NotExists,
    WrongArgs,
    WrongStage,
    UnexpectedResult,
    UnexpectedData,
    Overflow,
    Aborted,
};

/// The raw success value, for return statements inside `callconv(.c)` callbacks.
pub const raw_ok: c.lxb_status_t = @intCast(c.LXB_STATUS_OK);

/// The raw generic-error value, for return statements inside `callconv(.c)`
/// callbacks (where a Zig error cannot cross the boundary).
pub const raw_error: c.lxb_status_t = @intCast(c.LXB_STATUS_ERROR);

/// Converts a raw status into `Status`.
///
/// Unknown values (a future lexbor status this wrapper predates) degrade to
/// `.err` instead of trapping.
pub fn fromRaw(raw: c.lxb_status_t) Status {
    return std.enums.fromInt(Status, raw) orelse .err;
}

/// True for statuses that represent a hard failure.
pub fn isError(raw: c.lxb_status_t) bool {
    return switch (fromRaw(raw)) {
        .ok,
        .continue_,
        .small_buffer,
        .stopped,
        .next,
        .stop,
        .warning,
        .skipped,
        => false,
        .err,
        .out_of_memory,
        .object_is_null,
        .small_buffer_error,
        .incomplete_object,
        .no_free_slot,
        .too_small_size,
        .not_exists,
        .wrong_args,
        .wrong_stage,
        .unexpected_result,
        .unexpected_data,
        .overflow,
        .aborted,
        => true,
    };
}

/// Converts a raw status into a Zig error unless it is a success or a control
/// signal.
pub fn check(raw: c.lxb_status_t) Error!void {
    return switch (fromRaw(raw)) {
        .ok,
        .continue_,
        .small_buffer,
        .stopped,
        .next,
        .stop,
        .warning,
        .skipped,
        => {},
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
    };
}

/// The lexbor enumerator name of a status, for diagnostics.
pub fn name(status: Status) []const u8 {
    return switch (status) {
        .ok => "LXB_STATUS_OK",
        .err => "LXB_STATUS_ERROR",
        .out_of_memory => "LXB_STATUS_ERROR_MEMORY_ALLOCATION",
        .object_is_null => "LXB_STATUS_ERROR_OBJECT_IS_NULL",
        .small_buffer_error => "LXB_STATUS_ERROR_SMALL_BUFFER",
        .incomplete_object => "LXB_STATUS_ERROR_INCOMPLETE_OBJECT",
        .no_free_slot => "LXB_STATUS_ERROR_NO_FREE_SLOT",
        .too_small_size => "LXB_STATUS_ERROR_TOO_SMALL_SIZE",
        .not_exists => "LXB_STATUS_ERROR_NOT_EXISTS",
        .wrong_args => "LXB_STATUS_ERROR_WRONG_ARGS",
        .wrong_stage => "LXB_STATUS_ERROR_WRONG_STAGE",
        .unexpected_result => "LXB_STATUS_ERROR_UNEXPECTED_RESULT",
        .unexpected_data => "LXB_STATUS_ERROR_UNEXPECTED_DATA",
        .overflow => "LXB_STATUS_ERROR_OVERFLOW",
        .continue_ => "LXB_STATUS_CONTINUE",
        .small_buffer => "LXB_STATUS_SMALL_BUFFER",
        .aborted => "LXB_STATUS_ABORTED",
        .stopped => "LXB_STATUS_STOPPED",
        .next => "LXB_STATUS_NEXT",
        .stop => "LXB_STATUS_STOP",
        .warning => "LXB_STATUS_WARNING",
        .skipped => "LXB_STATUS_SKIPPED",
    };
}

test "every lexbor status maps to a named Status" {
    const all = [_]c.lxb_status_t{
        c.LXB_STATUS_OK,
        c.LXB_STATUS_ERROR,
        c.LXB_STATUS_ERROR_MEMORY_ALLOCATION,
        c.LXB_STATUS_ERROR_OBJECT_IS_NULL,
        c.LXB_STATUS_ERROR_SMALL_BUFFER,
        c.LXB_STATUS_ERROR_INCOMPLETE_OBJECT,
        c.LXB_STATUS_ERROR_NO_FREE_SLOT,
        c.LXB_STATUS_ERROR_TOO_SMALL_SIZE,
        c.LXB_STATUS_ERROR_NOT_EXISTS,
        c.LXB_STATUS_ERROR_WRONG_ARGS,
        c.LXB_STATUS_ERROR_WRONG_STAGE,
        c.LXB_STATUS_ERROR_UNEXPECTED_RESULT,
        c.LXB_STATUS_ERROR_UNEXPECTED_DATA,
        c.LXB_STATUS_ERROR_OVERFLOW,
        c.LXB_STATUS_CONTINUE,
        c.LXB_STATUS_SMALL_BUFFER,
        c.LXB_STATUS_ABORTED,
        c.LXB_STATUS_STOPPED,
        c.LXB_STATUS_NEXT,
        c.LXB_STATUS_STOP,
        c.LXB_STATUS_WARNING,
        c.LXB_STATUS_SKIPPED,
    };

    for (all) |raw| {
        const st = fromRaw(@intCast(raw));
        // Round-trips, and is a real enum member rather than the `.err` fallback
        // (except for the genuine generic error).
        if (st != .err) {
            try std.testing.expectEqual(@as(c.lxb_status_t, @intCast(raw)), @intFromEnum(st));
        }
        try std.testing.expect(name(st).len != 0);
    }

    // Out-of-range values degrade to `.err` instead of trapping.
    try std.testing.expectEqual(Status.err, fromRaw(0xFFFF));
}

test "check separates failures from control signals, exhaustively" {
    // Every enumerator is covered on purpose: a single misclassified status
    // would make `try` report success for a failure (or the reverse). An
    // earlier version of this test only sampled three of them, and a mutation
    // that swallowed `NotExists` slipped past it -- the tests/ suite caught it,
    // but the fast inline check should too.
    const table = [_]struct { raw: c.lxb_status_t, err: ?Error }{
        .{ .raw = c.LXB_STATUS_OK, .err = null },
        .{ .raw = c.LXB_STATUS_ERROR, .err = error.LexborError },
        .{ .raw = c.LXB_STATUS_ERROR_MEMORY_ALLOCATION, .err = error.OutOfMemory },
        .{ .raw = c.LXB_STATUS_ERROR_OBJECT_IS_NULL, .err = error.ObjectIsNull },
        .{ .raw = c.LXB_STATUS_ERROR_SMALL_BUFFER, .err = error.SmallBuffer },
        .{ .raw = c.LXB_STATUS_ERROR_INCOMPLETE_OBJECT, .err = error.IncompleteObject },
        .{ .raw = c.LXB_STATUS_ERROR_NO_FREE_SLOT, .err = error.NoFreeSlot },
        .{ .raw = c.LXB_STATUS_ERROR_TOO_SMALL_SIZE, .err = error.TooSmallSize },
        .{ .raw = c.LXB_STATUS_ERROR_NOT_EXISTS, .err = error.NotExists },
        .{ .raw = c.LXB_STATUS_ERROR_WRONG_ARGS, .err = error.WrongArgs },
        .{ .raw = c.LXB_STATUS_ERROR_WRONG_STAGE, .err = error.WrongStage },
        .{ .raw = c.LXB_STATUS_ERROR_UNEXPECTED_RESULT, .err = error.UnexpectedResult },
        .{ .raw = c.LXB_STATUS_ERROR_UNEXPECTED_DATA, .err = error.UnexpectedData },
        .{ .raw = c.LXB_STATUS_ERROR_OVERFLOW, .err = error.Overflow },
        .{ .raw = c.LXB_STATUS_CONTINUE, .err = null },
        .{ .raw = c.LXB_STATUS_SMALL_BUFFER, .err = null },
        .{ .raw = c.LXB_STATUS_ABORTED, .err = error.Aborted },
        .{ .raw = c.LXB_STATUS_STOPPED, .err = null },
        .{ .raw = c.LXB_STATUS_NEXT, .err = null },
        .{ .raw = c.LXB_STATUS_STOP, .err = null },
        .{ .raw = c.LXB_STATUS_WARNING, .err = null },
        .{ .raw = c.LXB_STATUS_SKIPPED, .err = null },
    };

    for (table) |case| {
        if (case.err) |want| {
            try std.testing.expectError(want, check(case.raw));
            try std.testing.expect(isError(case.raw));
        } else {
            try check(case.raw);
            try std.testing.expect(!isError(case.raw));
        }
    }

    // The table must cover every enumerator: a new lexbor status breaks the
    // build here until it is classified.
    try std.testing.expectEqual(std.enums.values(Status).len, table.len);

    // Unknown values degrade to a generic error rather than trapping.
    try std.testing.expectError(error.LexborError, check(0xFFFF));
    try std.testing.expectEqual(Status.err, fromRaw(0xFFFF));
}
