//! Idiomatic example: parse HTML, query it with CSS selectors, print results.
//!
//! Uses the wrapper layer only (`html`, `selectors`, `dom`), in contrast to
//! `parse.zig` which uses the raw `sys` bindings.

const std = @import("std");
const lexbor = @import("z_lexbor");

const page =
    \\<html><body>
    \\  <ul id="list">
    \\    <li class="item" data-id="1">alpha</li>
    \\    <li class="item" data-id="2">beta</li>
    \\    <li class="item special" data-id="3">gamma</li>
    \\  </ul>
    \\  <a href="/next">next page</a>
    \\</body></html>
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &out.interface;

    // The parser owns the document: `doc` is only valid until `parser.deinit`.
    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse(page);
    const root = doc.rootNode() orelse return error.NoRoot;

    // A selector engine owns a CSS parser plus the matching engine.
    var engine = try lexbor.selectors.Engine.createInit();
    defer engine.deinit();

    try w.print("items matching 'li.item':\n", .{});
    var items = try engine.queryAll(gpa, root, "li.item");
    defer items.deinit(gpa);

    for (items.items) |node| {
        const el = node.asElement().?;
        const id = el.getAttribute("data-id") orelse "?";
        try w.print("  [{s}] {s}\n", .{ id, el.textContent() });
    }

    const special = try engine.queryFirst(root, "li.special");
    try w.print(
        "first 'li.special': {s}\n",
        .{if (special) |n| n.textContent() else "(none)"},
    );

    const href = try engine.queryFirst(root, "a[href]");
    if (href) |node| {
        try w.print("link href: {s}\n", .{node.asElement().?.getAttribute("href").?});
    }

    // Re-serialize just the matched list.
    if (try engine.queryFirst(root, "#list")) |list_node| {
        try w.print("serialized list: ", .{});
        try lexbor.html.serialize(list_node, w);
        try w.writeAll("\n");
    }

    try w.flush();
}
