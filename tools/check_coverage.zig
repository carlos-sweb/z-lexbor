//! Public-API coverage gate.
//!
//! Parses every public lexbor header, collects every `lxb_*` / `lexbor_*`
//! identifier that is used as a function (i.e. followed by `(`), and verifies
//! that each one is present in the translate-c output.
//!
//! This is what makes the "complete API" claim checkable: if lexbor grows a
//! public function, or translate-c starts dropping one, the build fails.
//!
//! Usage: check-coverage <lexbor-source-dir> <generated-bindings.zig>

const std = @import("std");

const max_header_bytes = 8 * 1024 * 1024;
const max_bindings_bytes = 256 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: check-coverage <lexbor-source-dir> <generated-bindings.zig>\n",
        );
        return error.BadUsage;
    }
    const src_dir = args[1];
    const bindings_path = args[2];

    // ---- collect every function-like public identifier from the headers ----
    var headers = try std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true });
    defer headers.close(io);

    var walker = try headers.walk(gpa);
    defer walker.deinit();

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);

    // Keys outlive nothing beyond this run; an arena keeps ownership simple.
    var key_arena = std.heap.ArenaAllocator.init(gpa);
    defer key_arena.deinit();
    const key_alloc = key_arena.allocator();

    var header_count: usize = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "lexbor/")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".h")) continue;
        if (std.mem.eql(u8, entry.basename, "res.h")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_res.h")) continue;

        const text = entry.dir.readFileAlloc(
            io,
            entry.basename,
            gpa,
            .limited(max_header_bytes),
        ) catch |err| {
            try std.Io.File.stderr().writeStreamingAll(io, "check-coverage: cannot read header\n");
            return err;
        };
        defer gpa.free(text);

        header_count += 1;
        try collectNames(gpa, key_alloc, text, &names);
    }

    if (header_count == 0) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "check-coverage: no public headers found; is the vendored tree present?\n",
        );
        return error.NoHeadersFound;
    }

    // ---- read the translated bindings -------------------------------------
    const bindings = try std.Io.Dir.cwd().readFileAlloc(
        io,
        bindings_path,
        gpa,
        .limited(max_bindings_bytes),
    );
    defer gpa.free(bindings);

    // ---- report ------------------------------------------------------------
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);

    var it = names.iterator();
    while (it.next()) |kv| {
        if (!containsWord(bindings, kv.key_ptr.*)) {
            try missing.append(gpa, kv.key_ptr.*);
        }
    }

    std.mem.sort([]const u8, missing.items, {}, lessThanStr);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &out_buf);
    const w = &out.interface;

    try w.print(
        "check-coverage: {d} public headers, {d} function-like public names, {d} missing\n",
        .{ header_count, names.count(), missing.items.len },
    );

    if (missing.items.len != 0) {
        try w.writeAll("missing from bindings:\n");
        for (missing.items) |name| {
            try w.print("  {s}\n", .{name});
        }
        try w.flush();
        std.process.exit(1);
    }

    try w.flush();
}

/// Scans C text for `lxb_*` / `lexbor_*` identifiers immediately followed by
/// `(`, ignoring comments, string/char literals and preprocessor directives.
///
/// Preprocessor directives must be skipped: lexbor's tokenizer macros call
/// file-local `static` helpers (e.g. `lxb_tag_append_lower`), which are not
/// part of the public API and therefore never appear in the bindings.
fn collectNames(
    map_gpa: std.mem.Allocator,
    key_alloc: std.mem.Allocator,
    text: []const u8,
    names: *std.StringHashMapUnmanaged(void),
) !void {
    var i: usize = 0;
    var at_line_start = true;

    while (i < text.len) {
        const ch = text[i];

        if (at_line_start) {
            switch (ch) {
                ' ', '\t', '\r' => {
                    i += 1;
                    continue;
                },
                '#' => {
                    i = skipDirective(text, i);
                    continue;
                },
                else => at_line_start = false,
            }
        }

        if (ch == '\n') {
            at_line_start = true;
            i += 1;
            continue;
        }

        // line comment
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = skipLineComment(text, i + 2);
            continue;
        }
        // block comment
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = skipBlockComment(text, i + 2);
            continue;
        }
        // string literal
        if (ch == '"') {
            i = skipQuoted(text, i + 1, '"');
            continue;
        }
        // char literal
        if (ch == '\'') {
            i = skipQuoted(text, i + 1, '\'');
            continue;
        }

        if (isIdentStart(ch)) {
            const start = i;
            i += 1;
            while (i < text.len and isIdentChar(text[i])) i += 1;
            const ident = text[start..i];

            if (isLexborIdent(ident) and nextNonSpace(text, i) == '(') {
                if (!names.contains(ident)) {
                    try names.put(map_gpa, try key_alloc.dupe(u8, ident), {});
                }
            }
            continue;
        }

        i += 1;
    }
}

fn isLexborIdent(ident: []const u8) bool {
    return std.mem.startsWith(u8, ident, "lxb_") or
        std.mem.startsWith(u8, ident, "lexbor_");
}

fn nextNonSpace(text: []const u8, from: usize) u8 {
    var i = from;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ' ', '\t', '\r', '\n' => continue,
            else => return text[i],
        }
    }
    return 0;
}

fn skipLineComment(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and text[i] != '\n') i += 1;
    return i;
}

/// Skips a preprocessor directive, including backslash line continuations.
/// Returns the index just past the terminating newline.
fn skipDirective(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) {
        if (text[i] == '\\') {
            var j = i + 1;
            if (j < text.len and text[j] == '\r') j += 1;
            if (j < text.len and text[j] == '\n') {
                i = j + 1;
                continue;
            }
        }
        if (text[i] == '\n') return i + 1;
        i += 1;
    }
    return text.len;
}

fn skipBlockComment(text: []const u8, from: usize) usize {
    var i = from;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == '*' and text[i + 1] == '/') return i + 2;
    }
    return text.len;
}

fn skipQuoted(text: []const u8, from: usize, quote: u8) usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i + 1;
    }
    return text.len;
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Whole-word search: `name` must not be part of a longer identifier.
fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |idx| {
        const before_ok = idx == 0 or !isIdentChar(haystack[idx - 1]);
        const end = idx + needle.len;
        const after_ok = end >= haystack.len or !isIdentChar(haystack[end]);
        if (before_ok and after_ok) return true;
        offset = idx + 1;
    }
    return false;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
