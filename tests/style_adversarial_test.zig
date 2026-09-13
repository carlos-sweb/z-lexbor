//! Adversarial and fuzz tests for the `style` module.
//!
//! The invariant everywhere: hostile CSS produces a typed error or a usable
//! document, never a trap, a hang or a leak.

const std = @import("std");
const lexbor = @import("z_lexbor");
const style = lexbor.style;
const dom = lexbor.dom;

const fixtures = @import("fixtures.zig");

fn firstTag(doc: style.StyledDocument, tag: []const u8) ?dom.Element {
    var it = doc.documentNode().descendants();
    while (it.next()) |node| {
        if (node.asElement()) |el| {
            if (std.mem.eql(u8, el.localName(), tag)) return el;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Hostile CSS
// ---------------------------------------------------------------------------

test "BREAK: malformed stylesheets never derail the document" {
    const sheets = [_][]const u8{
        "",
        " ",
        "}",
        "{{{",
        "p{",
        "p{color:",
        "p{color:red",
        "@media {",
        "@@@",
        "/* unterminated",
        "p{color:red}}}.b{",
        "\x00",
        "\xff\xfe",
    };

    for (sheets) |sheet| {
        var engine = try style.Engine.create();
        defer engine.deinit();

        const doc = try engine.parse("<style></style><p>hi</p>");
        // Injecting garbage must not corrupt a usable document.
        doc.applyStylesheet(sheet) catch |err| {
            // OOM is the only acceptable failure here.
            try std.testing.expectEqual(error.OutOfMemory, err);
        };

        const p = firstTag(doc, "p") orelse return error.NoParagraph;
        try std.testing.expectEqualStrings("hi", p.textContent());
        _ = (try doc.styleOf(p)).count() catch {};
    }
}

test "BREAK: a stylesheet with 10 000 rules does not collapse" {
    const gpa = std.testing.allocator;

    var sheet: std.ArrayList(u8) = .empty;
    defer sheet.deinit(gpa);

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var buf: [48]u8 = undefined;
        const rule = try std.fmt.bufPrint(&buf, ".c{d}{{color:#{x:0>6}}}\n", .{ i, i });
        try sheet.appendSlice(gpa, rule);
    }

    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<p class=c9999>hi</p>");
    try doc.applyStylesheet(sheet.items);

    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);
    try std.testing.expect((try computed.count()) >= 1);
}

test "BREAK: an absurdly long property name and value" {
    const gpa = std.testing.allocator;

    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(gpa);

    try name.appendSlice(gpa, "p{");
    var i: usize = 0;
    while (i < 100_000) : (i += 1) try name.append(gpa, 'x');
    try name.appendSlice(gpa, ":red}");

    try value.appendSlice(gpa, "p{color:");
    i = 0;
    while (i < 100_000) : (i += 1) try value.append(gpa, 'y');
    try value.append(gpa, '}');

    var engine = try style.Engine.create();
    defer engine.deinit();
    const doc = try engine.parse("<p>hi</p>");

    doc.applyStylesheet(name.items) catch {};
    doc.applyStylesheet(value.items) catch {};

    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    _ = try (try doc.styleOf(p)).count();
}

test "BREAK: 5 000 elements against a large stylesheet" {
    const gpa = std.testing.allocator;

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(gpa);
    try html.appendSlice(gpa, "<style>.hit{color:red}</style>");

    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        if (i % 100 == 0) {
            try html.appendSlice(gpa, "<p class=hit>x</p>");
        } else {
            try html.appendSlice(gpa, "<span>x</span>");
        }
    }

    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse(html.items);
    const hit = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(hit);
    const text = try computed.serializeAlloc(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "red") != null);
}

// ---------------------------------------------------------------------------
// Exhausted resources
// ---------------------------------------------------------------------------

test "BREAK: serializing into a tiny buffer reports WriteFailed" {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red;font-size:12px}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    var tiny: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, computed.serialize(&writer));
}

test "OOM INJECTION: serializeAlloc surfaces the writer's failure" {
    // std.Io.Writer.Error is exactly error{WriteFailed}: the allocating writer
    // collapses allocation failure into it, so checkAllAllocationFailures (which
    // requires OutOfMemory) cannot be used here. What matters is that the
    // failure is reported and nothing leaks.
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red;font-size:12px}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.WriteFailed, computed.serializeAlloc(failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
}

test "OOM INJECTION: collect frees everything when an allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectUnderOom,
        .{},
    );
}

fn collectUnderOom(allocator: std.mem.Allocator) !void {
    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red;font-size:12px}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;

    const entries = try (try doc.styleOf(p)).collect(allocator);
    defer allocator.free(entries);
    try std.testing.expect(entries.len > 0);
}

// ---------------------------------------------------------------------------
// Fuzzing
// ---------------------------------------------------------------------------

const Fuzz = struct {
    prng: std.Random.DefaultPrng,

    fn init(stream: u64) Fuzz {
        return .{ .prng = std.Random.DefaultPrng.init(fixtures.fuzz_seed +% stream) };
    }

    fn random(self: *Fuzz) std.Random {
        return self.prng.random();
    }

    fn fillCss(self: *Fuzz, buf: []u8) void {
        const alphabet = "abc.#{}:;>+~[]()!importantcolor:redpx0123456789 -\n\t\"'*/@";
        const r = self.prng.random();
        for (buf) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
    }

    fn fillBytes(self: *Fuzz, buf: []u8) void {
        self.prng.random().bytes(buf);
    }
};

test "FUZZ: random CSS text applied to a document" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 256);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(21);
    var iterations: usize = 0;
    while (iterations < 200) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillCss(buf[0..len]);

        var engine = try style.Engine.create();
        defer engine.deinit();

        const doc = try engine.parse("<p class=a>hi</p>");
        doc.applyStylesheet(buf[0..len]) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };

        // The document must survive and stay queryable.
        const p = firstTag(doc, "p") orelse return error.NoParagraph;
        _ = (try doc.styleOf(p)).count() catch {};
    }
}

test "FUZZ: raw random bytes as CSS" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 128);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(22);
    var iterations: usize = 0;
    while (iterations < 200) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillBytes(buf[0..len]);

        var engine = try style.Engine.create();
        defer engine.deinit();

        const doc = try engine.parse("<p>x</p>");
        doc.applyStylesheet(buf[0..len]) catch {};
    }
}

test "FUZZ: random HTML with embedded styles" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 384);
    defer gpa.free(buf);

    var fuzz = Fuzz.init(23);
    var iterations: usize = 0;
    while (iterations < 150) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillCss(buf[0..len]);

        var html: std.ArrayList(u8) = .empty;
        defer html.deinit(gpa);
        try html.appendSlice(gpa, "<style>");
        try html.appendSlice(gpa, buf[0..len]);
        try html.appendSlice(gpa, "</style><p class=a style='color:red'>hi</p>");

        var engine = try style.Engine.create();
        defer engine.deinit();

        const doc = engine.parse(html.items) catch continue;
        const p = firstTag(doc, "p") orelse continue;
        _ = (try doc.styleOf(p)).count() catch {};
    }
}

test "FUZZ: random property names are looked up safely" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 48);
    defer gpa.free(buf);

    var engine = try style.Engine.create();
    defer engine.deinit();

    const doc = try engine.parse("<style>p{color:red}</style><p>hi</p>");
    const p = firstTag(doc, "p") orelse return error.NoParagraph;
    const computed = try doc.styleOf(p);

    var fuzz = Fuzz.init(24);
    var iterations: usize = 0;
    while (iterations < 400) : (iterations += 1) {
        const len = fuzz.random().uintLessThan(usize, buf.len + 1);
        fuzz.fillBytes(buf[0..len]);

        // Neither of these may trap for arbitrary names.
        _ = computed.get(buf[0..len]);
        _ = computed.property(buf[0..len]);
    }
}
