//! Shared fixtures for the test suite.
//!
//! Everything here is deterministic: no clock, no randomness, no I/O.

/// A small page exercising nesting, attributes, classes, ids, text and links.
pub const page =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <title>Fixture Page</title>
    \\</head>
    \\<body>
    \\  <header id="top"><h1 class="title">Hello</h1></header>
    \\  <ul id="list">
    \\    <li class="item" data-id="1">alpha</li>
    \\    <li class="item" data-id="2">beta</li>
    \\    <li class="item special" data-id="3">gamma</li>
    \\  </ul>
    \\  <p class="note empty" title="a &lt;b&gt; c">note &amp; more</p>
    \\  <a href="/next" rel="next">next</a>
    \\  <a href="https://example.com/abs">absolute</a>
    \\  <div class="a"><span>deep</span></div>
    \\</body>
    \\</html>
;

/// A table, for structural extraction tests.
pub const table_page =
    \\<table id="t">
    \\  <thead><tr><th>Name</th><th>Value</th></tr></thead>
    \\  <tbody>
    \\    <tr><td>one</td><td>1</td></tr>
    \\    <tr><td>two</td><td>2</td></tr>
    \\  </tbody>
    \\</table>
;

/// Text nodes, comments, doctype and raw-text elements.
pub const mixed_page =
    \\<!DOCTYPE html>
    \\<html><body>
    \\<!-- a comment -->
    \\<script>var x = 1 < 2 && "a";</script>
    \\<style>.a > b { color: red }</style>
    \\<p>plain <b>bold</b> tail</p>
    \\</body></html>
;

/// UTF-8 content, including astral-plane characters.
pub const unicode_page =
    "<p id=\"u\">caf\u{e9} \u{1f600} \u{4e2d}\u{6587} \u{fc}</p>";

/// Every selector shape the engine is expected to support.
pub const selector_cases = [_]struct { selector: []const u8, expected: usize }{
    .{ .selector = "li", .expected = 3 },
    .{ .selector = ".item", .expected = 3 },
    .{ .selector = "#list", .expected = 1 },
    .{ .selector = "li.item", .expected = 3 },
    .{ .selector = "li.special", .expected = 1 },
    .{ .selector = "#list > li", .expected = 3 },
    .{ .selector = "ul li", .expected = 3 },
    .{ .selector = "li + li", .expected = 2 },
    .{ .selector = "li ~ li", .expected = 2 },
    .{ .selector = "li:first-child", .expected = 1 },
    .{ .selector = "li:last-child", .expected = 1 },
    .{ .selector = "li:nth-child(2)", .expected = 1 },
    .{ .selector = "li:not(.special)", .expected = 2 },
    .{ .selector = "[data-id]", .expected = 3 },
    .{ .selector = "[data-id=\"2\"]", .expected = 1 },
    .{ .selector = "[class~=special]", .expected = 1 },
    .{ .selector = "[class^=ite]", .expected = 3 },
    .{ .selector = "[class$=ial]", .expected = 1 },
    .{ .selector = "[class*=pec]", .expected = 1 },
    .{ .selector = "header h1.title", .expected = 1 },
    .{ .selector = "a[rel=next]", .expected = 1 },
};

/// Deterministic seed for every randomized test.
pub const fuzz_seed: u64 = 0x5eed_1eaf_1234_5678;
