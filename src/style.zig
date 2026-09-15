//! Idiomatic wrapper over lexbor's `style` module: CSS cascade resolution and
//! per-element computed styles.
//!
//! # Lifecycle (this is the part that bites)
//!
//! lexbor only applies CSS if the document's CSS state is initialised **before**
//! parsing:
//!
//!   * `lxb_style_init()` installs the mutation callbacks and the parse-done
//!     hook, and allocates `document.css`.
//!   * Styles are applied as elements are inserted, plus a final pass over the
//!     collected stylesheets when parsing finishes.
//!
//! Two consequences the wrapper exists to handle:
//!
//!   1. **`document.css` is NULL until `lxb_style_init()` runs**, and lexbor's
//!      `lxb_dom_element_style_by_name()` dereferences it without a null check
//!      (`style/dom/interfaces/element.c:103`). On a plain `html.Parser`
//!      document that call **aborts the process**. `style.of()` turns that into
//!      `error.StyleNotInitialized`.
//!   2. **Neither the document nor the parser frees the CSS state.** Only
//!      `lxb_style_destroy()` does; destroying the document without it leaks the
//!      whole CSS pool. `Engine` wraps `lxb_engine_t`, whose teardown performs
//!      `lxb_style_destroy()` before `lxb_html_document_destroy()` in the
//!      correct order.
//!
//! So `Engine` is the supported entry point. `html.Parser` deliberately does
//! **not** expose a styled parse: its documents are destroyed by
//! `lxb_html_parser_destroy()`, which would leak the CSS pool.
//!
//! # What lexbor does *not* do
//!
//! `var()` is **not** substituted. A declaration written as `color: var(--main)`
//! is stored literally, and looking `color` up by name returns null.
//!
//! # Styles are resolved at insertion time
//!
//! The computed style of an element is built when the element is inserted into
//! the document (and when a stylesheet is applied). **Changing an attribute
//! afterwards does not recompute it**, even though `lxb_style_init()` installs
//! attribute mutation steps. Verified behaviour:
//!
//! ```text
//! <style>.a{color:red}.b{color:blue}</style><p class=a>
//!   before  -> color: red
//!   after p.setAttribute("class", "b")  -> still color: red   (DOM says "b")
//! ```
//!
//! Elements created *after* parsing and then inserted do get styles, because
//! insertion is what triggers resolution. To restyle an existing tree after
//! changing attributes, apply the stylesheet again — see
//! `tests/style_deep_test.zig` for the exact behaviour that is pinned.

const std = @import("std");
const c = @import("sys/root.zig").c;
const status = @import("status.zig");
const conv = @import("internal/convert.zig");
const callback = @import("internal/callback.zig");
pub const dom = @import("dom.zig");

/// Errors specific to the `style` module.
pub const StyleError = error{
    /// The document has no CSS state: `lxb_style_init()` was never called on it.
    ///
    /// lexbor would dereference a null pointer here; the wrapper checks first.
    StyleNotInitialized,
};

/// Everything a style call can return.
pub const Error = status.Error || StyleError;

/// True when `document` has CSS state, i.e. style queries are safe on it.
pub fn isInitialized(document: [*c]c.lxb_dom_document_t) bool {
    return document != null and document.*.css != null;
}

/// The computed style of `element`, with the precondition **checked**.
///
/// Returns `error.StyleNotInitialized` rather than aborting when the document
/// was not style-initialised. Prefer `Engine`/`StyledDocument`, which cannot
/// produce such a document in the first place.
pub fn of(element: dom.Element) Error!Computed {
    const document = element.raw().*.node.owner_document;
    if (!isInitialized(document)) return error.StyleNotInitialized;
    return .{ .element = element.raw() };
}

/// Decodes a packed CSS selector specificity.
///
/// Layout, per `css/selectors/selector.h`:
///   bits [31..28] `!important`, bit [27] style attribute,
///   bits [26..18] `a` (id selectors), [17..9] `b` (class/attribute/pseudo-class),
///   bits [8..0] `c` (type selectors and pseudo-elements).
pub const Specificity = struct {
    raw: c.lxb_css_selector_specificity_t,

    /// The declaration carried `!important`.
    pub fn important(self: Specificity) bool {
        return c.lxb_css_selector_sp_i(self.raw) != 0;
    }

    /// The declaration came from an element's `style="..."` attribute.
    pub fn fromStyleAttribute(self: Specificity) bool {
        return c.lxb_css_selector_sp_s(self.raw) != 0;
    }

    /// Count of id selectors (`a`).
    pub fn ids(self: Specificity) u32 {
        return @intCast(c.lxb_css_selector_sp_a(self.raw));
    }

    /// Count of class selectors, attribute selectors and pseudo-classes (`b`).
    pub fn classes(self: Specificity) u32 {
        return @intCast(c.lxb_css_selector_sp_b(self.raw));
    }

    /// Count of type selectors and pseudo-elements (`c`).
    pub fn types(self: Specificity) u32 {
        return @intCast(c.lxb_css_selector_sp_c(self.raw));
    }

    /// A total order matching CSS cascade precedence.
    pub fn order(self: Specificity) u64 {
        const imp: u64 = if (self.important()) 1 else 0;
        const style_attr: u64 = if (self.fromStyleAttribute()) 1 else 0;
        return (imp << 40) | (style_attr << 39) |
            (@as(u64, self.ids()) << 20) |
            (@as(u64, self.classes()) << 10) |
            @as(u64, self.types());
    }

    pub fn eql(a: Specificity, b: Specificity) bool {
        return a.raw == b.raw;
    }
};

/// One style declaration, together with the specificity that selected it.
pub const Entry = struct {
    declr: [*c]const c.lxb_css_rule_declaration_t,
    specificity: Specificity,
    /// True when this declaration lost the cascade and is only kept as a
    /// candidate for a lower-priority property.
    is_weak: bool,

    pub fn raw(self: Entry) [*c]const c.lxb_css_rule_declaration_t {
        return self.declr;
    }

    /// Whether this declaration won with `!important`.
    pub fn important(self: Entry) bool {
        return self.specificity.important();
    }

    /// Writes `name: value` (including `!important` when present).
    pub fn serialize(self: Entry, writer: *std.Io.Writer) !void {
        var sink = callback.WriterSink{ .writer = writer };
        try sink.check(c.lxb_css_rule_declaration_serialize(
            self.declr,
            callback.WriterSink.callback,
            &sink,
        ));
    }

    /// Writes just the property name.
    pub fn serializeName(self: Entry, writer: *std.Io.Writer) !void {
        var sink = callback.WriterSink{ .writer = writer };
        try sink.check(c.lxb_css_rule_declaration_serialize_name(
            self.declr,
            callback.WriterSink.callback,
            &sink,
        ));
    }

    /// Convenience: the declaration serialized as an owned string.
    pub fn toOwnedString(self: Entry, allocator: std.mem.Allocator) ![]u8 {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        self.serialize(&allocating.writer) catch |err| {
            allocating.deinit();
            return err;
        };
        var list = allocating.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

/// The computed style of a single element. A borrowed view: no `deinit`.
pub const Computed = struct {
    element: [*c]c.lxb_dom_element_t,

    pub fn raw(self: Computed) [*c]c.lxb_dom_element_t {
        return self.element;
    }

    /// The winning declaration for `property`, or null when absent.
    ///
    /// An empty name is rejected: it makes lexbor's property hash underflow
    /// (`lexbor_shs_entry_get_lower_static`, `core/shs.c:67`), aborting under
    /// safety checks -- the same defect as the empty element name in `dom`.
    pub fn get(self: Computed, name: []const u8) ?Entry {
        if (name.len == 0) return null;

        const declr = c.lxb_dom_element_style_by_name(
            self.element,
            conv.ptr(name),
            name.len,
        );
        if (declr == null) return null;

        return .{
            .declr = declr,
            .specificity = .{ .raw = self.specificityOf(name) },
            .is_weak = false,
        };
    }

    /// Same as `get`, by numeric property id (`lxb_style_id_by_name`).
    pub fn getById(self: Computed, id: usize) ?Entry {
        const declr = c.lxb_dom_element_style_by_id(self.element, id);
        if (declr == null) return null;

        const node = c.lxb_dom_element_style_node_by_id(self.element, id);
        const sp: c.lxb_css_selector_specificity_t = if (node != null) node.*.sp else 0;
        return .{ .declr = declr, .specificity = .{ .raw = sp }, .is_weak = false };
    }

    fn specificityOf(self: Computed, name: []const u8) c.lxb_css_selector_specificity_t {
        const node = c.lxb_dom_element_style_node_by_name(
            self.element,
            conv.ptr(name),
            name.len,
        );
        return if (node != null) node.*.sp else 0;
    }

    /// The typed property value, or null when absent.
    ///
    /// lexbor's declaration union has ~90 property types, so this returns an
    /// untyped pointer: cast it to the matching `lxb_css_property_*_t`. Use
    /// `get()`/`serialize()` when you only need the textual value.
    pub fn property(self: Computed, name: []const u8) ?*const anyopaque {
        // `lxb_dom_element_css_property_by_id` returns a pointer even for a
        // known-but-unset property, so the declaration is checked first.
        // `get` also rejects an empty name, which would crash lexbor.
        if (self.get(name) == null) return null;

        const id = c.lxb_style_id_by_name(
            self.element.*.node.owner_document,
            conv.ptr(name),
            name.len,
        );
        if (id == 0) return null;
        return c.lxb_dom_element_css_property_by_id(self.element, id);
    }

    /// Invokes `on_entry` for each **winning** declaration, allocation-free.
    ///
    /// lexbor's walk also yields the losing candidates (`is_weak == true`), and
    /// can repeat an entry; this filters them out, so each property is visited
    /// exactly once with the declaration that actually won.
    pub fn walk(
        self: Computed,
        ctx: anytype,
        comptime on_entry: fn (@TypeOf(ctx), Entry) Error!void,
    ) !void {
        const Bridge = struct {
            ctx: @TypeOf(ctx),
            err: ?Error = null,

            fn cb(
                element: [*c]c.lxb_dom_element_t,
                declr: [*c]const c.lxb_css_rule_declaration_t,
                raw_ctx: ?*anyopaque,
                spec: c.lxb_css_selector_specificity_t,
                is_weak: bool,
            ) callconv(.c) c.lxb_status_t {
                _ = element;
                const self_: *@This() = @ptrCast(@alignCast(raw_ctx orelse return status.raw_error));

                // Losing candidates: skipped, not reported.
                if (is_weak) return status.raw_ok;

                on_entry(self_.ctx, .{
                    .declr = declr,
                    .specificity = .{ .raw = spec },
                    .is_weak = false,
                }) catch |err| {
                    self_.err = err;
                    return status.raw_error;
                };
                return status.raw_ok;
            }
        };

        var bridge = Bridge{ .ctx = ctx };

        // An element that matched nothing has element->style == NULL, and
        // lexbor's lexbor_avl_foreach() reports that as
        // LXB_STATUS_ERROR_WRONG_ARGS (9) -- a misleading status for an empty
        // collection. Check the field directly instead of interpreting it.
        if (self.element.*.style == null) return;

        const walk_status = c.lxb_dom_element_style_walk(
            self.element,
            Bridge.cb,
            &bridge,
            true,
        );

        // The callback's own failure takes priority: when it aborts, lexbor
        // propagates a generic LXB_STATUS_ERROR, which would otherwise mask the
        // real error (an allocation failure, say) recorded in the bridge.
        if (bridge.err) |err| return err;

        try status.check(walk_status);
    }

    /// Collects the winning declarations. Caller owns the slice.
    pub fn collect(
        self: Computed,
        allocator: std.mem.Allocator,
    ) ![]Entry {
        const Collector = struct {
            out: *std.ArrayList(Entry),
            allocator: std.mem.Allocator,

            fn onEntry(self_: *@This(), entry: Entry) Error!void {
                try self_.out.append(self_.allocator, entry);
            }
        };

        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(allocator);

        var collector = Collector{ .out = &out, .allocator = allocator };
        try self.walk(&collector, Collector.onEntry);

        return out.toOwnedSlice(allocator);
    }

    /// Number of winning declarations.
    pub fn count(self: Computed) !usize {
        const Counter = struct {
            n: usize = 0,
            fn onEntry(self_: *@This(), _: Entry) Error!void {
                self_.n += 1;
            }
        };
        var counter = Counter{};
        try self.walk(&counter, Counter.onEntry);
        return counter.n;
    }

    /// True when the element matched no declaration at all.
    pub fn isEmpty(self: Computed) !bool {
        return (try self.count()) == 0;
    }

    /// Writes the full computed style, e.g. `color: red; font-size: 12px`.
    pub fn serialize(self: Computed, writer: *std.Io.Writer) !void {
        var sink = callback.WriterSink{ .writer = writer };
        try sink.check(c.lxb_dom_element_style_serialize(
            self.element,
            0,
            callback.WriterSink.callback,
            &sink,
        ));
    }

    /// The full computed style as an owned string.
    pub fn serializeAlloc(self: Computed, allocator: std.mem.Allocator) ![]u8 {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        self.serialize(&allocating.writer) catch |err| {
            allocating.deinit();
            return err;
        };
        var list = allocating.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

/// A document whose CSS state is initialised, so style queries on it are safe.
///
/// Borrowed: the owning `Engine` (or whatever created the document) controls
/// its lifetime.
pub const StyledDocument = struct {
    ptr: [*c]c.lxb_html_document_t,

    pub fn raw(self: StyledDocument) [*c]c.lxb_html_document_t {
        return self.ptr;
    }

    pub fn domDocument(self: StyledDocument) [*c]c.lxb_dom_document_t {
        return &self.ptr.*.dom_document;
    }

    pub fn documentNode(self: StyledDocument) dom.Node {
        return .{ .ptr = c.lxb_dom_interface_node(self.domDocument()) };
    }

    /// The root element, or null when the document is empty.
    pub fn rootElement(self: StyledDocument) ?dom.Element {
        return dom.firstElementChild(self.documentNode());
    }

    pub fn rootNode(self: StyledDocument) ?dom.Node {
        const element = self.rootElement() orelse return null;
        return element.node();
    }

    /// The computed style of `element`.
    ///
    /// Always safe on a `StyledDocument`: the type cannot exist without CSS
    /// state, but the check is kept as a cheap invariant assertion.
    pub fn styleOf(self: StyledDocument, element: dom.Element) Error!Computed {
        if (!isInitialized(self.domDocument())) return error.StyleNotInitialized;
        return .{ .element = element.raw() };
    }

    /// Parses `css_source` and applies it to this (already built) document.
    ///
    /// The stylesheet is allocated from the document's CSS memory pool, so it
    /// stays alive for the document's lifetime and is released by
    /// `lxb_style_destroy()` — do not free it.
    pub fn applyStylesheet(self: StyledDocument, css_source: []const u8) Error!void {
        const document = self.domDocument();
        if (!isInitialized(document)) return error.StyleNotInitialized;

        const css = document.*.css;
        const sheet = c.lxb_css_stylesheet_create(css.*.memory);
        if (sheet == null) return error.OutOfMemory;

        try status.check(c.lxb_css_stylesheet_parse(
            sheet,
            css.*.parser,
            conv.ptr(css_source),
            css_source.len,
        ));

        // `add` only records the pointer; the document owns the memory.
        try status.check(c.lxb_dom_document_stylesheet_add(document, sheet));
        try status.check(c.lxb_dom_document_stylesheet_apply(document, sheet));
    }
};

/// Owns an HTML document **and** its CSS state.
///
/// Wraps `lxb_engine_t`, whose teardown calls `lxb_style_destroy()` before
/// destroying the document — the order lexbor requires and that destroying the
/// document alone gets wrong.
pub const Engine = struct {
    ptr: [*c]c.lxb_engine_t,

    pub fn create() status.Error!Engine {
        const ptr = c.lxb_engine_create();
        if (ptr == null) return error.OutOfMemory;
        errdefer _ = c.lxb_engine_destroy(ptr);

        try status.check(c.lxb_engine_init(ptr));
        return .{ .ptr = ptr };
    }

    /// Idempotent.
    pub fn deinit(self: *Engine) void {
        if (self.ptr != null) {
            _ = c.lxb_engine_destroy(self.ptr);
            self.ptr = null;
        }
    }

    pub fn raw(self: Engine) [*c]c.lxb_engine_t {
        return self.ptr;
    }

    /// The document, as a type that guarantees CSS is initialised.
    pub fn document(self: Engine) StyledDocument {
        return .{ .ptr = self.ptr.*.document };
    }

    /// Parses `source` with style application enabled.
    ///
    /// `<style>` elements, `style="..."` attributes and injected stylesheets
    /// are all resolved into per-element computed styles.
    pub fn parse(self: Engine, source: []const u8) status.Error!StyledDocument {
        try status.check(c.lxb_engine_parse(
            self.ptr,
            conv.ptr(source),
            source.len,
            0,
        ));
        return self.document();
    }
};
