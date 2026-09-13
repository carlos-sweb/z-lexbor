# Changelog

All notable changes to `z-lexbor` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Build a DOM without parsing.** `html.OwnedDocument` wraps
  `lxb_html_document_create()` (which returns an *empty* document — the tree
  builder only runs during parsing), and `dom` gained the mutation primitives:
  `createElement`, `createTextNode`, `firstElementChild`, `Node.appendChild`,
  `Node.appendChildUnchecked`, `Node.appendElement`, `Node.appendText`,
  `Node.ownerDocument`, plus the same conveniences on `Element`.
- `Document.rootElement()` / `rootNode()` now fall back to the first element
  child of the document node. A hand-built document never populates
  `document.element`, so without this fallback the root was invisible.
- `Document.documentNode()` exposes the document node itself.
- `examples/build_dom.zig` and a "Building a DOM without parsing" section in the
  README, with 17 new tests in `tests/build_dom_test.zig` (213 total overall).

### Fixed

- **`dom.createElement` rejects an empty name with `error.InvalidName`.** A
  zero-length element name underflows an unsigned offset inside lexbor's tag
  hash (`lexbor_shs_entry_get_lower_static`, `core/shs.c:67`), which aborts the
  process under Zig's safety checks and would read out of bounds in an
  optimised build. The wrapper now refuses it before the call, matching the
  DOM's `InvalidCharacterError`.

  This is an **upstream lexbor defect**, not a wrapper bug: the root cause is in
  `vendor/lexbor/source/lexbor/core/shs.c`. It has not been reported to the
  lexbor project; the guard here is what keeps Zig callers safe.
- **`Document.rootElement()` returned null for documents built by hand** (see
  above).

- **CSS cascade coverage.** `tests/style_test.zig` (14 tests) and the
  self-checking `examples/css_cascade.zig` pin that lexbor resolves the cascade
  for real: specificity ordering (`id > class > type`), `!important` beating
  higher specificity, author `!important` beating an inline style, inline style
  beating author normal declarations, and source order as the tiebreak.

### Documented

- **lexbor is a CSS engine, not only a parser.** Three layers: `css` (Syntax +
  CSSOM), `selectors` (matching), `style` (applies matched rules into a
  per-element computed style tree). The README gained a "CSS" section.
- **Style queries require `lxb_style_init()`.** Without it the document's `css`
  field is null, and `lxb_dom_element_style_by_name()` dereferences it without a
  null check (`style/dom/interfaces/element.c:103`), aborting the process.
  `html.Parser` does not call `lxb_style_init()`; `lxb_engine_t` does.
- Appending a node that belongs to another document is accepted by lexbor and
  **moves** the node, leaving the source document without a root.
- `AUDIT.md` gained three findings and updated figures.

## [0.2.0] - 2026-09-13

Testing, verification and documentation release. **No change to the library
implementation**: the production code is identical to 0.1.0.

### Added

- **Test system**: 182 tests, split into inline unit tests (`src/`) and a
  dedicated `tests/` suite, run together by `zig build test`. New steps:
  `test-unit` (26 tests) and `test-suite` (156 tests).
  - `tests/status_test.zig` — exhaustive `lxb_status_t` mapping, plus a
    raw-value sweep proving the mapping is total and never panics.
  - `tests/convert_test.zig`, `tests/callback_test.zig` — the C boundary and the
    callback/write-failure bridges.
  - `tests/dom_test.zig`, `tests/html_test.zig`, `tests/css_test.zig`,
    `tests/selectors_test.zig`, `tests/url_test.zig`, `tests/encoding_test.zig` —
    per-module behavioural coverage.
  - `tests/ownership_test.zig` — idempotent teardown, absence of `deinit` on
    borrowed views, leak-checked allocation.
  - `tests/adversarial_test.zig` — hostile input (1 MiB documents, 5000-deep
    nesting, 64 KiB attributes, NUL and invalid UTF-8, unbalanced markup) and
    exhausted resources (too-small and zero-length serialization buffers).
  - `tests/fuzz_test.zig` — deterministic seeded fuzzing of HTML, markup, byte
    mutations, selectors and URLs.
  - `tests/integration_test.zig` — end-to-end scenarios (link extraction and
    resolution, table extraction, query/mutate/serialize/re-parse).
- **Allocation-failure injection** via `std.testing.checkAllAllocationFailures`
  on `queryAll` and `queryFirst`: every allocation point is failed in turn and
  the test must return `error.OutOfMemory` with zero leaked bytes.
- **The inline status test is now exhaustive** (all 22 enumerators) and asserts
  its own completeness against `std.enums.values(Status).len`, so a status added
  by a future lexbor release breaks the build until it is classified.
- **[AUDIT.md](AUDIT.md)** — the full write-up: method, verified figures,
  mutation-testing results, the assumptions that turned out to be wrong, and an
  explicit threats-to-validity section.

### Changed

- CI now runs the suite in **Debug and ReleaseSafe** (safety checks stay on, so
  a different optimisation path is exercised), and on macOS.
- `build.zig.zon` package contents now include `tests/` and `AUDIT.md`.

### Behaviour pinned (previously undocumented)

These were discovered by tests that failed on first run. In every case the test
was wrong, not the code — but each was a genuine unknown, now documented:

- The selector search root is **not** itself a candidate, matching
  `element.querySelectorAll` semantics.
- `dom.Node.name()` returns the DOM `nodeName`, which lexbor upper-cases for
  HTML elements; `localName()` keeps the lower-case spelling.
- `std.Io.Writer.Error` is exactly `error{WriteFailed}`, so an allocating writer
  that runs out of memory surfaces `WriteFailed`, not `OutOfMemory`.
- An "empty" document still contains `html`, `head` and `body`.

### Fixed

- The exhaustive inline status test was written during 0.2.0 development but was
  silently discarded: the mutation-verification step used
  `git checkout -- src/status.zig` while the change was still uncommitted, which
  reverted both the injected mutation and the new test. `AUDIT.md` and this file
  described the work as done, which made them inaccurate for a period. The
  change has been restored and the mutation that exposed the gap is now caught
  by the inline tests as well as the suite.

### Verified

- 182/182 tests pass in **Debug, ReleaseSafe and ReleaseFast**.
- A fresh `git clone` with an empty cache builds and passes 182/182.
- `x86_64-linux`, `aarch64-linux`, `x86_64-windows-gnu` and `wasm32-wasi` all
  compile and link.
- The suite was validated by mutation: three deliberately injected bugs were all
  detected (see `AUDIT.md` §5).

## [0.1.0] - 2026-09-13

First working version.

### Added

- **Complete bindings** for the lexbor v3.0.1 C API, generated at build time
  with `std.Build.addTranslateC` over an umbrella header covering all 226
  public headers (2740 `extern fn`).
- **Coverage gate** (`zig build check-coverage`): parses every public header and
  fails if any of the 2408 public function-like names is missing from the
  bindings. Currently 0 missing.
- **Vendored engine**: lexbor v3.0.1 (`7e278c0`) under `vendor/lexbor/`,
  trimmed to `source/`, compiled directly by Zig. No CMake, no pkg-config and
  no system lexbor.
- **Idiomatic wrapper modules**:
  - `status` — `Status` enum, `Error` set, `check`, `isError`, `name`
  - `html` — `Parser` (RAII, owns its documents), `Document`, `serialize`
  - `dom` — `Node`, `Element`, `Attr`, `NodeType`, `Children`, `Descendants`,
    `Attributes`
  - `css` — `Parser` (RAII), `SelectorList`
  - `selectors` — `Engine` with `compile`, `find`, `queryAll`, `queryFirst`
  - `url` — `Parser` (RAII), `Url.serialize`, base-relative resolution
  - `encoding` — WHATWG encoding lookup by label
- **Examples**: `parse.zig` (raw `sys` bindings), `query.zig` (wrapper API).
- **Consumer check** (`tools/check-consumer.sh`): builds a standalone project
  against the package to prove one-line integration.
- **CI**: tests, coverage gate, cross-compilation (`aarch64-linux`,
  `x86_64-windows-gnu`, `wasm32-wasi`), native macOS, and a hermetic-build job.

### Verified

- 26/26 tests pass.
- `x86_64-linux`, `aarch64-linux`, `x86_64-windows-gnu` and `wasm32-wasi` all
  compile and link.

## Deferred

Applies to the current state of the project.

- Typed `tag` / `ns` enums (the raw `LXB_TAG_*` / `LXB_NS_*` constants remain
  reachable through `sys`).
- Full decode/encode wrappers for the `encoding` module beyond label lookup.
- No dynamic analysis of the C side: no ASan, MSan or Valgrind run is part of
  CI. This is the largest remaining verification gap.
- Fuzzing is bounded and seeded, not coverage-guided (no libFuzzer/AFL corpus).
- The coverage gate checks that every public *name* is reachable; it does not
  verify signatures against the C declarations.
- macOS cross-compilation from Linux is not possible without the macOS SDK;
  the macOS job runs natively in CI.
- `-Dsystem-lexbor` is provided as an escape hatch but is not hermetic and is
  not exercised by CI.
