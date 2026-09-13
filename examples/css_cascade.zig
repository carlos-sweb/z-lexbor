//! Demonstrates that lexbor is not only a CSS *parser*: it matches selectors
//! against the parsed DOM, resolves the cascade (specificity, `!important`,
//! inline style, source order) and stores the result as a per-element computed
//! style tree that can be read back or serialized.
//!
//! This example is self-checking: it returns an error if any case resolves
//! differently from what the CSS cascade specifies.

const std = @import("std");
const lexbor = @import("z_lexbor");
const c = lexbor.sys.c;

const ok: c.lxb_status_t = @intCast(c.LXB_STATUS_OK);

/// Parses `html` with style application enabled and returns the serialized
/// computed style of the first `<p>` element.
fn computedStyleOfP(html: []const u8, buf: []u8) ![]const u8 {
    const engine = c.lxb_engine_create();
    if (engine == null) return error.OutOfMemory;
    defer _ = c.lxb_engine_destroy(engine);

    if (c.lxb_engine_init(engine) != ok) return error.EngineInitFailed;
    if (c.lxb_engine_parse(engine, html.ptr, html.len, 0) != ok) return error.ParseFailed;

    const document = engine.*.document;
    const root: [*c]c.lxb_dom_node_t =
        c.lxb_dom_interface_node(document.*.dom_document.element);

    var stack: [64][*c]c.lxb_dom_node_t = undefined;
    stack[0] = root;
    var top: usize = 1;
    var p: [*c]c.lxb_dom_element_t = null;

    while (top > 0) {
        top -= 1;
        const node = stack[top];
        if (node.*.type == @as(c.lxb_dom_node_type_t, @intCast(c.LXB_DOM_NODE_TYPE_ELEMENT))) {
            const el = c.lxb_dom_interface_element(node);
            var len: usize = 0;
            const name = c.lxb_dom_element_local_name(el, &len);
            if (p == null and std.mem.eql(u8, name[0..len], "p")) p = el;
        }
        if (node.*.first_child != null) {
            stack[top] = node.*.first_child;
            top += 1;
        }
        if (node.*.next != null) {
            stack[top] = node.*.next;
            top += 1;
        }
    }

    if (p == null) return error.NoParagraph;

    var str = std.mem.zeroes(c.lexbor_str_t);
    try lexbor.status.check(c.lxb_dom_element_style_serialize_str(p, &str, 0));

    const n = @min(str.length, buf.len);
    @memcpy(buf[0..n], str.data[0..n]);
    return buf[0..n];
}

const Case = struct { html: []const u8, expected: []const u8, what: []const u8 };

const cases = [_]Case{
    .{
        .what = "specificity: #id beats .class beats type",
        .html = "<style>p{color:red}.big{color:blue}#x{color:green}</style><p class=big id=x>hi</p>",
        .expected = "color: green",
    },
    .{
        .what = "specificity wins over source order",
        .html = "<style>#x{color:green}.big{color:blue}p{color:red}</style><p class=big id=x>hi</p>",
        .expected = "color: green",
    },
    .{
        .what = "!important beats higher specificity",
        .html = "<style>p{color:red !important}.big{color:blue}</style><p class=big>hi</p>",
        .expected = "color: red !important",
    },
    .{
        .what = "author !important beats inline style",
        .html = "<style>p{color:red !important}</style><p style='color:blue'>hi</p>",
        .expected = "color: red !important",
    },
    .{
        .what = "inline style beats author normal declarations",
        .html = "<style>p{color:red}</style><p style='color:blue'>hi</p>",
        .expected = "color: blue",
    },
    .{
        .what = "equal specificity: later rule wins",
        .html = "<style>.a{color:red}.b{color:blue}</style><p class='a b'>hi</p>",
        .expected = "color: blue",
    },
    .{
        .what = "attribute selector (b) beats type selector (c)",
        .html = "<style>p{color:red}[data-x]{color:blue}</style><p data-x=1>hi</p>",
        .expected = "color: blue",
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &out.interface;

    try w.print("lexbor CSS cascade ({d} cases)\n\n", .{cases.len});

    var failures: usize = 0;
    for (cases) |case| {
        var buf: [256]u8 = undefined;
        const got = computedStyleOfP(case.html, &buf) catch |err| {
            try w.print("  ERROR {s}: {s}\n", .{ case.what, @errorName(err) });
            failures += 1;
            continue;
        };

        if (std.mem.eql(u8, got, case.expected)) {
            try w.print("  ok    {s:<48} {s}\n", .{ case.what, got });
        } else {
            try w.print("  FAIL  {s:<48} expected '{s}', got '{s}'\n", .{ case.what, case.expected, got });
            failures += 1;
        }
    }

    try w.flush();

    if (failures != 0) return error.CascadeMismatch;
}
