//! Minimal end-to-end example: parse an HTML fragment, then serialize the
//! resulting tree back to stdout.
//!
//! It deliberately uses the raw `sys` layer only, to prove that the complete
//! translated C API is usable on its own.

const std = @import("std");
const c = @import("z_lexbor").sys.c;

/// lexbor's `lxb_status_t` is an unsigned int, while translate-c emits the
/// `LXB_STATUS_*` enumerators as `c_int`; this normalises the success value.
const ok: c.lxb_status_t = @intCast(c.LXB_STATUS_OK);

const Sink = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,

    fn write(
        data: [*c]const c.lxb_char_t,
        length: usize,
        ctx_ptr: ?*anyopaque,
    ) callconv(.c) c.lxb_status_t {
        const self: *Sink = @ptrCast(@alignCast(ctx_ptr orelse return c.LXB_STATUS_ERROR_WRONG_ARGS));
        const room = self.buf.len - self.len;
        const n = @min(length, room);
        @memcpy(self.buf[self.len..][0..n], data[0..n]);
        self.len += n;
        return ok;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const html = "<div id=\"x\"><p>Hello <b>world</b></p></div>";

    const parser = c.lxb_html_parser_create();
    if (parser == null) return error.OutOfMemory;
    defer _ = c.lxb_html_parser_destroy(parser);

    if (c.lxb_html_parser_init(parser) != ok) return error.ParserInitFailed;

    // The returned document lives in the parser's memory pool: it stays valid
    // until `lxb_html_parser_destroy`.
    const doc = c.lxb_html_parse(parser, html.ptr, html.len);
    if (doc == null) return error.ParseFailed;

    const root = doc.*.dom_document.element;
    if (root == null) return error.NoRootElement;

    var sink = Sink{};
    if (c.lxb_html_serialize_tree_cb(c.lxb_dom_interface_node(root), Sink.write, &sink) != ok) {
        return error.SerializeFailed;
    }

    var out_buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buffer);
    try out.interface.writeAll(sink.buf[0..sink.len]);
    try out.interface.writeAll("\n");
    try out.interface.flush();
}
