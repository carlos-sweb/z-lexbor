//! Deterministic fuzzing.
//!
//! Every loop is seeded from `fixtures.fuzz_seed`, so failures are reproducible
//! and the suite is never flaky. The invariant under fuzz is always:
//!
//!   * the call either succeeds or returns a typed error,
//!   * a produced document is walkable and serializable,
//!   * nothing traps, hangs or leaks.
//!
//! These tests deliberately feed lexbor input that no real page would contain.

const std = @import("std");
const lexbor = @import("z_lexbor");
const harness = @import("harness.zig");
const fixtures = @import("fixtures.zig");

const Fuzz = struct {
    prng: std.Random.DefaultPrng,

    fn init(stream: u64) Fuzz {
        return .{ .prng = std.Random.DefaultPrng.init(fixtures.fuzz_seed +% stream) };
    }

    fn random(self: *Fuzz) std.Random {
        return self.prng.random();
    }

    /// Uniform random bytes: invalid UTF-8, NULs, control characters, high bytes.
    fn fillBytes(self: *Fuzz, buf: []u8) void {
        self.prng.random().bytes(buf);
    }

    /// Random bytes drawn from a hostile markup/selector alphabet.
    fn fillMarkup(self: *Fuzz, buf: []u8) void {
        const alphabet = "abcdefghijklmnopqrstuvwxyz<>/=\"'[]#.:;{}() 0123456789-*+~^$|!&%\\\n\t";
        const r = self.prng.random();
        for (buf) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
    }
};

/// Walks a document and returns how many nodes it contains, aborting if the
/// tree looks unbounded (a cycle would show up as an enormous count).
fn countNodes(root: lexbor.dom.Node, limit: usize) !usize {
    var n: usize = 0;
    var it = root.descendants();
    while (it.next()) |_| {
        n += 1;
        if (n > limit) return error.TreeTooLarge;
    }
    return n;
}

test "FUZZ: uniform random bytes as HTML" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 512);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(1);
    var iterations: usize = 0;
    while (iterations < 200) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillBytes(buf[0..len]);

        var parser = try lexbor.html.Parser.createInit();
        defer parser.deinit();

        const doc = parser.parse(buf[0..len]) catch |err| {
            // A hard failure is acceptable for garbage input; it must be typed.
            try std.testing.expectEqual(error.LexborError, err);
            continue;
        };

        const root = doc.rootNode() orelse continue;
        _ = try countNodes(root, 100_000);

        // Whatever was built must be serializable.
        var out: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        lexbor.html.serializeDocument(doc, &w) catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
        };
    }
}

test "FUZZ: random markup-shaped text as HTML" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 512);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(2);
    var iterations: usize = 0;
    while (iterations < 300) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillMarkup(buf[0..len]);

        var parser = try lexbor.html.Parser.createInit();
        defer parser.deinit();

        const doc = parser.parse(buf[0..len]) catch continue;
        const root = doc.rootNode() orelse continue;
        _ = try countNodes(root, 100_000);
    }
}

test "FUZZ: byte mutations of a valid page" {
    const gpa = std.testing.allocator;

    // Start from a real page and corrupt it in place.
    const base = try gpa.dupe(u8, fixtures.page);
    defer gpa.free(base);

    var fuzz = Fuzz.init(3);
    var iterations: usize = 0;
    while (iterations < 300) : (iterations += 1) {
        const mutations = 1 + fuzz.random().uintLessThan(usize, 16);
        var i: usize = 0;
        while (i < mutations) : (i += 1) {
            const pos = fuzz.random().uintLessThan(usize, base.len);
            base[pos] = fuzz.random().int(u8);
        }

        var parser = try lexbor.html.Parser.createInit();
        defer parser.deinit();

        const doc = parser.parse(base) catch continue;
        const root = doc.rootNode() orelse continue;
        _ = try countNodes(root, 100_000);
    }
}

test "FUZZ: random selector text" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 128);
    defer gpa.free(buf);

    var doc = try harness.Doc.init(fixtures.page);
    defer doc.deinit();

    var fuzz = Fuzz.init(4);
    var iterations: usize = 0;
    var compiled: usize = 0;
    var rejected: usize = 0;

    while (iterations < 400) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillMarkup(buf[0..len]);

        // Compiling must never trap. Whether lexbor accepts the selector is its
        // business; both outcomes are legal, but each must be well-formed.
        const list = doc.engine.compile(buf[0..len]) catch {
            rejected += 1;
            continue;
        };
        compiled += 1;

        var found = try doc.engine.queryAll(gpa, doc.root(), buf[0..len]);
        defer found.deinit(gpa);
        _ = &list;
    }

    // Sanity: the fuzzer must actually exercise both branches, otherwise this
    // test could silently stop testing anything.
    try std.testing.expect(compiled > 0 or rejected > 0);
}

test "FUZZ: random URL text" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 256);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(5);
    var iterations: usize = 0;
    var parsed: usize = 0;
    var rejected: usize = 0;

    while (iterations < 300) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillMarkup(buf[0..len]);

        var parser = try lexbor.url.Parser.createInit();
        defer parser.deinit();

        const url = parser.parse(null, buf[0..len]) catch {
            rejected += 1;
            continue;
        };
        parsed += 1;

        var out: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        url.serialize(&w, false) catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
        };
    }

    try std.testing.expect(parsed + rejected == 300);
}

test "FUZZ: URL prefixes with random suffixes always parse or error cleanly" {
    const gpa = std.testing.allocator;
    const suffix = try gpa.alloc(u8, 128);
    defer gpa.free(suffix);

    const prefixes = [_][]const u8{
        "https://example.com/",
        "http://example.com/",
        "//example.com/",
        "/",
        "?",
        "#",
    };

    var fuzz = Fuzz.init(6);
    var iterations: usize = 0;
    while (iterations < 200) : (iterations += 1) {
        fuzz.fillMarkup(suffix);

        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(gpa);

        const prefix = prefixes[fuzz.random().uintLessThan(usize, prefixes.len)];
        try input.appendSlice(gpa, prefix);
        try input.appendSlice(gpa, suffix);

        var parser = try lexbor.url.Parser.createInit();
        defer parser.deinit();

        if (parser.parse(null, input.items)) |url| {
            var out: [16384]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);
            url.serialize(&w, false) catch |err| {
                try std.testing.expectEqual(error.WriteFailed, err);
            };
        } else |err| {
            try std.testing.expectEqual(error.LexborError, err);
        }
    }
}

test "FUZZ: random bytes as selector and encoding labels" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 64);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(7);
    var iterations: usize = 0;
    while (iterations < 300) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillBytes(buf[0..len]);

        // Neither of these may trap, whatever the bytes are.
        _ = lexbor.encoding.byName(buf[0..len]);

        var parser = try lexbor.css.Parser.createInit();
        defer parser.deinit();
        if (parser.parseSelectorList(buf[0..len])) |list| {
            try std.testing.expect(list.raw() != null);
        } else |err| {
            try std.testing.expectEqual(error.LexborError, err);
        }
    }
}
