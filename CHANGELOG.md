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

### Verified

- 26/26 tests pass.
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
