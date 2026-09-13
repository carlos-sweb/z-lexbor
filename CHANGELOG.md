# Changelog

All notable changes to `z-lexbor` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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

### Added (test system)

- **182 tests**, split into inline unit tests (`src/`) and a dedicated `tests/`
  suite, run together by `zig build test`. New steps: `test-unit`, `test-suite`.
- `tests/status_test.zig` — exhaustive `lxb_status_t` mapping, plus a raw-value
  sweep proving the mapping is total and never panics.
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
  on `queryAll` and `queryFirst`.
- CI now runs the suite in **Debug and ReleaseSafe**, and on macOS.

### Behaviour pinned (previously undocumented)

- The selector search root is **not** itself a candidate, matching
  `element.querySelectorAll` semantics.
- `dom.Node.name()` returns the DOM `nodeName`, which lexbor upper-cases for
  HTML elements; `localName()` keeps the lower-case spelling.
- `std.Io.Writer.Error` is exactly `error{WriteFailed}`, so an allocating writer
  that runs out of memory surfaces `WriteFailed`, not `OutOfMemory`.
- An "empty" document still contains `html`, `head` and `body`.

### Verified

- 182/182 tests pass in Debug, ReleaseSafe and ReleaseFast.
- `x86_64-linux`, `aarch64-linux`, `x86_64-windows-gnu` and `wasm32-wasi` all
  compile and link.

### Deferred

- Typed `tag` / `ns` enums (the raw `LXB_TAG_*` / `LXB_NS_*` constants remain
  reachable through `sys`).
- Full decode/encode wrappers for the `encoding` module beyond label lookup.
- macOS cross-compilation from Linux is not possible without the macOS SDK;
  the macOS job runs natively in CI.
- `-Dsystem-lexbor` is provided as an escape hatch but is not hermetic and is
  not exercised by CI.
