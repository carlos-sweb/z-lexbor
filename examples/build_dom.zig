//! Builds a DOM entirely from scratch — no HTML parsing — and serializes it.
//!
//! lexbor supports this, but nothing creates the `html`/`head`/`body` skeleton
//! for you: `lxb_html_document_create()` returns an *empty* document, because
//! the tree builder only runs during parsing. `html.OwnedDocument` wraps that,
//! and every node is created and wired up explicitly.

const std = @import("std");
const lexbor = @import("z_lexbor");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var document = try lexbor.html.OwnedDocument.create();
    defer document.deinit();

    // document -> html -> { head -> link, body -> h1 -> "Hello world" }
    const html = try document.appendElement("html");

    const head = try html.appendElement("head");
    const link = try head.appendElement("link");
    try link.setAttribute("rel", "stylesheet");
    try link.setAttribute("href", "style.css");

    const body = try html.appendElement("body");
    const h1 = try body.appendElement("h1");
    _ = try h1.appendText("Hello world");

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try document.serializeTo(&writer);

    var out_buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buffer);
    try out.interface.writeAll(std.Io.Writer.buffered(&writer));
    try out.interface.writeAll("\n");
    try out.interface.flush();
}
