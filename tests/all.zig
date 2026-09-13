//! Complete test-suite entry point.
//!
//! `zig build test` runs this suite *and* the inline unit tests in `src/`.
//! Use `zig build test-suite` or `zig build test-unit` to run either half.
//!
//! Layout:
//!
//!   status_test       exhaustive lxb_status_t -> Status/Error mapping
//!   convert_test      C string <-> Zig slice boundary
//!   callback_test     callconv(.c) callback bridges and write failures
//!   dom_test          traversal, iterators, attributes
//!   html_test         parsing, document structure, serialization
//!   css_test          selector-list parsing
//!   selectors_test    matching, early exit, OOM injection
//!   url_test          WHATWG URL parsing and serialization
//!   encoding_test     WHATWG encoding lookup
//!   ownership_test    lifetime rules, idempotent teardown, leak checking
//!   adversarial_test  hostile input and exhausted resources
//!   fuzz_test         deterministic randomized testing
//!   build_dom_test    assembling a DOM by hand (no parsing)
//!   style_test        CSS cascade and computed styles (raw sys API)
//!   style_deep_test   the style module: cascade, specificity, injection
//!   style_adversarial hostile CSS, OOM injection and fuzzing
//!   integration_test  end-to-end user scenarios

const std = @import("std");

test {
    _ = @import("status_test.zig");
    _ = @import("convert_test.zig");
    _ = @import("callback_test.zig");
    _ = @import("dom_test.zig");
    _ = @import("html_test.zig");
    _ = @import("css_test.zig");
    _ = @import("selectors_test.zig");
    _ = @import("url_test.zig");
    _ = @import("encoding_test.zig");
    _ = @import("ownership_test.zig");
    _ = @import("adversarial_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("build_dom_test.zig");
    _ = @import("style_test.zig");
    _ = @import("style_deep_test.zig");
    _ = @import("style_adversarial_test.zig");
    _ = @import("integration_test.zig");
}

test {
    std.testing.refAllDecls(@import("fixtures.zig"));
    std.testing.refAllDecls(@import("harness.zig"));
}
