//! Idiomatic, non-owning views over lexbor's DOM.
//!
//! Every type here is a thin wrapper around a raw lexbor pointer plus a small
//! amount of Zig ergonomics:
//!
//!   * relationship accessors return `?Node` instead of nullable C pointers,
//!   * strings come back as Zig slices borrowed from lexbor's memory,
//!   * iterators replace the `first_child`/`next` pointer walks.
//!
//! **Ownership:** none of these types own anything and none of them have a
//! `deinit`. The DOM they point into is owned by the parser or document that
//! produced it; see `html.Parser`.

const std = @import("std");
const c = @import("sys/root.zig").c;
const status = @import("status.zig");
const conv = @import("internal/convert.zig");

/// `lxb_dom_node_type_t` as a typed Zig enum.
pub const NodeType = enum(u32) {
    undef = @intCast(c.LXB_DOM_NODE_TYPE_UNDEF),
    element = @intCast(c.LXB_DOM_NODE_TYPE_ELEMENT),
    attribute = @intCast(c.LXB_DOM_NODE_TYPE_ATTRIBUTE),
    text = @intCast(c.LXB_DOM_NODE_TYPE_TEXT),
    cdata_section = @intCast(c.LXB_DOM_NODE_TYPE_CDATA_SECTION),
    entity_reference = @intCast(c.LXB_DOM_NODE_TYPE_ENTITY_REFERENCE),
    entity = @intCast(c.LXB_DOM_NODE_TYPE_ENTITY),
    processing_instruction = @intCast(c.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION),
    comment = @intCast(c.LXB_DOM_NODE_TYPE_COMMENT),
    document = @intCast(c.LXB_DOM_NODE_TYPE_DOCUMENT),
    document_type = @intCast(c.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE),
    document_fragment = @intCast(c.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT),
    notation = @intCast(c.LXB_DOM_NODE_TYPE_NOTATION),
    character_data = @intCast(c.LXB_DOM_NODE_TYPE_CHARACTER_DATA),
    shadow_root = @intCast(c.LXB_DOM_NODE_TYPE_SHADOW_ROOT),

    pub fn fromRaw(raw: c.lxb_dom_node_type_t) ?NodeType {
        return std.enums.fromInt(NodeType, raw);
    }
};

/// `lxb_dom_node_append_child` reports DOM exceptions; -1 means success.
const exception_ok: c.lxb_dom_exception_code_t = @intCast(c.LXB_DOM_EXCEPTION_OK);

/// Errors raised when building or mutating the DOM.
pub const BuildError = error{
    /// lexbor could not allocate the node.
    OutOfMemory,
    /// The insertion raised a DOM exception (for example a hierarchy request).
    InsertRejected,
    /// The element name was empty.
    ///
    /// Rejected before reaching lexbor: its tag hash underflows on a
    /// zero-length name (`lexbor_shs_entry_get_lower_static` in `core/shs.c`),
    /// which aborts under Zig's safety checks and would read wild memory in an
    /// optimised build. The DOM also specifies `InvalidCharacterError` here.
    InvalidName,
};

/// Creates a new element owned by `document`.
///
/// The result is a borrowed view: the document owns it, so there is nothing to
/// free individually.
pub fn createElement(
    document: [*c]c.lxb_dom_document_t,
    local_name: []const u8,
) BuildError!Element {
    if (local_name.len == 0) return error.InvalidName;

    const el = c.lxb_dom_document_create_element(document, conv.ptr(local_name), local_name.len, null);
    if (el == null) return error.OutOfMemory;
    return .{ .ptr = el };
}

/// Creates a new text node owned by `document`.
pub fn createTextNode(
    document: [*c]c.lxb_dom_document_t,
    text: []const u8,
) BuildError!Node {
    const node = c.lxb_dom_document_create_text_node(document, conv.ptr(text), text.len);
    if (node == null) return error.OutOfMemory;
    return .{ .ptr = c.lxb_dom_interface_node(node) };
}

/// The first element child of `node`, skipping text and comment nodes.
pub fn firstElementChild(node: Node) ?Element {
    var child = node.firstChild();
    while (child) |candidate| : (child = candidate.nextSibling()) {
        if (candidate.asElement()) |el| return el;
    }
    return null;
}

/// A borrowed DOM node.
pub const Node = struct {
    ptr: [*c]c.lxb_dom_node_t,

    /// Wraps a raw pointer, mapping null to null.
    pub fn maybe(ptr: [*c]c.lxb_dom_node_t) ?Node {
        return if (ptr == null) null else Node{ .ptr = ptr };
    }

    pub fn raw(self: Node) [*c]c.lxb_dom_node_t {
        return self.ptr;
    }

    pub fn nodeType(self: Node) ?NodeType {
        return NodeType.fromRaw(self.ptr.*.type);
    }

    pub fn parent(self: Node) ?Node {
        return maybe(self.ptr.*.parent);
    }

    pub fn firstChild(self: Node) ?Node {
        return maybe(self.ptr.*.first_child);
    }

    pub fn lastChild(self: Node) ?Node {
        return maybe(self.ptr.*.last_child);
    }

    pub fn nextSibling(self: Node) ?Node {
        return maybe(self.ptr.*.next);
    }

    pub fn previousSibling(self: Node) ?Node {
        return maybe(self.ptr.*.prev);
    }

    /// Direct children, in document order.
    pub fn children(self: Node) Children {
        return .{ .next_ptr = self.ptr.*.first_child };
    }

    /// Pre-order traversal of this node and all of its descendants.
    pub fn descendants(self: Node) Descendants {
        return .{ .root = self.ptr, .current = self.ptr };
    }

    /// The node name (`lxb_dom_node_name`). Borrowed from lexbor memory.
    pub fn name(self: Node) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_node_name(self.ptr, &len), len);
    }

    /// The document that owns this node.
    pub fn ownerDocument(self: Node) [*c]c.lxb_dom_document_t {
        return self.ptr.*.owner_document;
    }

    /// Appends `child` as this node's last child, running the DOM's insertion
    /// steps (validity checks and mutation callbacks).
    ///
    /// Returns `error.InsertRejected` when the DOM raises an exception. Use
    /// `appendChildUnchecked` to bypass those steps.
    pub fn appendChild(self: Node, child: Node) BuildError!void {
        const code = c.lxb_dom_node_append_child(self.ptr, child.ptr);
        if (code != exception_ok) return error.InsertRejected;
    }

    /// Appends `child` without running the DOM's insertion steps. Faster, but
    /// no validity checking and no mutation callbacks.
    pub fn appendChildUnchecked(self: Node, child: Node) void {
        c.lxb_dom_node_insert_child(self.ptr, child.ptr);
    }

    /// Creates a child element in the same document and appends it.
    pub fn appendElement(self: Node, local_name: []const u8) BuildError!Element {
        const el = try createElement(self.ownerDocument(), local_name);
        try self.appendChild(el.node());
        return el;
    }

    /// Creates a text node in the same document and appends it.
    pub fn appendText(self: Node, text: []const u8) BuildError!Node {
        const node = try createTextNode(self.ownerDocument(), text);
        try self.appendChild(node);
        return node;
    }

    /// The concatenated text content of this node's subtree.
    pub fn textContent(self: Node) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_node_text_content(self.ptr, &len), len);
    }

    /// Views this node as an element, or null when it is not one.
    pub fn asElement(self: Node) ?Element {
        if (self.nodeType() != .element) return null;
        return Element{ .ptr = c.lxb_dom_interface_element(self.ptr) };
    }

    pub fn eql(a: Node, b: Node) bool {
        return a.ptr == b.ptr;
    }
};

/// Iterates the direct children of a node.
pub const Children = struct {
    next_ptr: [*c]c.lxb_dom_node_t,

    pub fn next(self: *Children) ?Node {
        const cur = self.next_ptr;
        if (cur == null) return null;
        self.next_ptr = cur.*.next;
        return Node{ .ptr = cur };
    }
};

/// Pre-order iterator over a subtree, yielding the root first.
pub const Descendants = struct {
    root: [*c]c.lxb_dom_node_t,
    current: [*c]c.lxb_dom_node_t,
    done: bool = false,

    pub fn next(self: *Descendants) ?Node {
        if (self.done or self.current == null) return null;

        const cur = self.current;

        var following: [*c]c.lxb_dom_node_t = null;
        if (cur.*.first_child != null) {
            following = cur.*.first_child;
        } else {
            var n = cur;
            while (n != self.root) {
                if (n.*.next != null) {
                    following = n.*.next;
                    break;
                }
                n = n.*.parent;
                if (n == null) break;
            }
        }

        if (following == null) {
            self.done = true;
        } else {
            self.current = following;
        }
        return Node{ .ptr = cur };
    }
};

/// A borrowed attribute.
pub const Attr = struct {
    ptr: [*c]c.lxb_dom_attr_t,

    pub fn maybe(ptr: [*c]c.lxb_dom_attr_t) ?Attr {
        return if (ptr == null) null else Attr{ .ptr = ptr };
    }

    pub fn raw(self: Attr) [*c]c.lxb_dom_attr_t {
        return self.ptr;
    }

    /// The attribute name without its namespace prefix.
    pub fn localName(self: Attr) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_attr_local_name(self.ptr, &len), len);
    }

    /// The attribute name as written, including any prefix.
    pub fn qualifiedName(self: Attr) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_attr_qualified_name(self.ptr, &len), len);
    }

    /// The attribute value.
    pub fn value(self: Attr) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_attr_value(self.ptr, &len), len);
    }

    pub fn next(self: Attr) ?Attr {
        return maybe(c.lxb_dom_element_next_attribute(self.ptr));
    }
};

/// Iterates an element's attributes.
pub const Attributes = struct {
    next_ptr: [*c]c.lxb_dom_attr_t,

    pub fn next(self: *Attributes) ?Attr {
        const cur = self.next_ptr;
        if (cur == null) return null;
        self.next_ptr = c.lxb_dom_element_next_attribute(cur);
        return Attr{ .ptr = cur };
    }
};

/// A borrowed element.
pub const Element = struct {
    ptr: [*c]c.lxb_dom_element_t,

    pub fn maybe(ptr: [*c]c.lxb_dom_element_t) ?Element {
        return if (ptr == null) null else Element{ .ptr = ptr };
    }

    pub fn raw(self: Element) [*c]c.lxb_dom_element_t {
        return self.ptr;
    }

    /// The same node as a generic `Node`.
    pub fn node(self: Element) Node {
        return .{ .ptr = c.lxb_dom_interface_node(self.ptr) };
    }

    /// The element's tag name in lower case (e.g. `"div"`).
    pub fn localName(self: Element) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_element_local_name(self.ptr, &len), len);
    }

    /// The element's qualified name (e.g. `"svg:rect"`).
    pub fn tagName(self: Element) []const u8 {
        var len: usize = 0;
        return conv.slice(c.lxb_dom_element_tag_name(self.ptr, &len), len);
    }

    /// The `id` attribute, if present.
    pub fn id(self: Element) ?[]const u8 {
        return self.getAttribute("id");
    }

    /// The `class` attribute list, if present.
    pub fn classAttribute(self: Element) ?[]const u8 {
        return self.getAttribute("class");
    }

    /// Attribute lookup by qualified name.
    pub fn getAttribute(self: Element, name: []const u8) ?[]const u8 {
        var len: usize = 0;
        const value = c.lxb_dom_element_get_attribute(self.ptr, conv.ptr(name), name.len, &len);
        if (value == null) return null;
        return conv.slice(value, len);
    }

    pub fn hasAttribute(self: Element, name: []const u8) bool {
        return c.lxb_dom_element_has_attribute(self.ptr, conv.ptr(name), name.len);
    }

    /// Sets (or replaces) an attribute value.
    pub fn setAttribute(self: Element, name: []const u8, value: []const u8) status.Error!void {
        const attr = c.lxb_dom_element_set_attribute(
            self.ptr,
            conv.ptr(name),
            name.len,
            conv.ptr(value),
            value.len,
        );
        if (attr == null) return error.LexborError;
    }

    pub fn removeAttribute(self: Element, name: []const u8) status.Error!void {
        try status.check(c.lxb_dom_element_remove_attribute(self.ptr, conv.ptr(name), name.len));
    }

    pub fn attributes(self: Element) Attributes {
        return .{ .next_ptr = c.lxb_dom_element_first_attribute(self.ptr) };
    }

    /// Appends `child` as this element's last child (DOM insertion steps run).
    pub fn appendChild(self: Element, child: Node) BuildError!void {
        return self.node().appendChild(child);
    }

    /// Creates a child element in the same document and appends it.
    pub fn appendElement(self: Element, local_name: []const u8) BuildError!Element {
        return self.node().appendElement(local_name);
    }

    /// Creates a text node in the same document and appends it.
    pub fn appendText(self: Element, text: []const u8) BuildError!Node {
        return self.node().appendText(text);
    }

    pub fn firstChild(self: Element) ?Node {
        return self.node().firstChild();
    }

    pub fn children(self: Element) Children {
        return self.node().children();
    }

    pub fn descendants(self: Element) Descendants {
        return self.node().descendants();
    }

    pub fn parent(self: Element) ?Node {
        return self.node().parent();
    }

    pub fn textContent(self: Element) []const u8 {
        return self.node().textContent();
    }
};

test "NodeType maps every lexbor node type" {
    try std.testing.expectEqual(NodeType.element, NodeType.fromRaw(@intCast(c.LXB_DOM_NODE_TYPE_ELEMENT)).?);
    try std.testing.expectEqual(NodeType.text, NodeType.fromRaw(@intCast(c.LXB_DOM_NODE_TYPE_TEXT)).?);
    try std.testing.expectEqual(NodeType.comment, NodeType.fromRaw(@intCast(c.LXB_DOM_NODE_TYPE_COMMENT)).?);
    try std.testing.expectEqual(NodeType.document, NodeType.fromRaw(@intCast(c.LXB_DOM_NODE_TYPE_DOCUMENT)).?);
    // Unknown values surface as null rather than trapping.
    try std.testing.expectEqual(@as(?NodeType, null), NodeType.fromRaw(999));
}
