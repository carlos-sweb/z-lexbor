# z-lexbor

Zig 0.16 bindings and idiomatic wrapper for the [lexbor](https://github.com/lexbor/lexbor)
HTML engine.

The **entire** lexbor API is reachable from Zig, and the engine is compiled
from vendored sources by `zig build` — no CMake, no pkg-config, no system
lexbor.

```zig
const lexbor = @import("z_lexbor");

var parser = try lexbor.html.Parser.createInit();
defer parser.deinit();

const doc = try parser.parse("<div class=a><p>one</p><p>two</p></div>");

var engine = try lexbor.selectors.Engine.createInit();
defer engine.deinit();

var found = try engine.queryAll(allocator, doc.rootNode().?, "div.a > p");
defer found.deinit(allocator);
```

## Guarantees

| Guarantee | How it is enforced |
|---|---|
| Complete API coverage | `zig build check-coverage` parses all 226 public headers and fails if any of the 2408 public function-like names is missing from the bindings (currently **0 missing**, 2740 `extern fn` emitted) |
| Hermetic, version-pinned engine | lexbor `v3.0.1` (`7e278c0`) vendored under `vendor/lexbor/`; the build never reads a system lexbor |
| Cross-platform | `x86_64-linux`, `aarch64-linux`, `x86_64-windows-gnu` and `wasm32-wasi` all compile and link (see CI) |
| Easy integration | verified by `tools/check-consumer.sh`, which builds a standalone project against this package |
| Behaviour is pinned by tests | 182 tests: exhaustive status mapping, OOM injection, deterministic fuzzing and adversarial input; all pass in Debug, ReleaseSafe and ReleaseFast |

## Using it

Add the dependency and import the module:

```zig
// build.zig
const zlexbor = b.dependency("z_lexbor", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("z_lexbor", zlexbor.module("z_lexbor"));
```

That single import brings in the whole stack: the translated C bindings *and*
the compiled lexbor engine.

## API

Two layers are always available. Anything lexbor can do is reachable through
`sys`, even where a dedicated wrapper does not exist yet.

### `z_lexbor.sys`
The raw, complete, 1:1 translated C API (`z_lexbor.sys.c`).

### Wrapper modules

| Module | Contents |
|---|---|
| `html` | `Parser` (RAII, owns its documents), `Document`, `serialize`, `serializeDocument` |
| `dom` | `Node`, `Element`, `Attr`, `NodeType`, `Children`, `Descendants`, `Attributes` |
| `css` | `Parser` (RAII), `SelectorList` |
| `selectors` | `Engine` with `compile`, `find`, `queryAll`, `queryFirst` |
| `url` | `Parser` (RAII), `Url.serialize`, base-relative resolution |
| `encoding` | `byName`, `name` (WHATWG encoding labels) |
| `status` | `Status` enum, `Error` set, `check`, `isError`, `name` |

### Ownership rules

* `html.Parser` owns every `Document` it produces: a document lives in the
  parser's memory pool and is invalidated by `Parser.deinit`.
* `dom.Node` / `dom.Element` / `dom.Attr` are **non-owning views** with no
  `deinit`.
* `css.Parser` owns the `SelectorList`s it parses; `selectors.Engine` owns both
  its CSS parser and its selector engine.
* `url.Parser` owns the `Url`s it parses.
* Memory that lexbor allocated is only ever freed by the corresponding
  `lxb_*_destroy`. A Zig allocator is never used on lexbor-owned pointers;
  `queryAll` allocates only the *result list*.

## Layout

| Path | Purpose |
|---|---|
| `src/sys/` | Complete raw bindings, 1:1 with the C API |
| `src/*.zig` | Idiomatic wrapper modules |
| `tools/gen_c_header.zig` | Builds the umbrella header fed to `addTranslateC` |
| `tools/check_coverage.zig` | Public-API coverage gate |
| `tools/check-consumer.sh` | External-consumer integration check |
| `vendor/lexbor/` | Vendored lexbor v3.0.1 (see `vendor/lexbor/VENDOR.md`) |
| `examples/` | `parse.zig` (raw `sys`), `query.zig` (wrappers) |

## Build steps

| Step | Action |
|---|---|
| `zig build test` | **Everything**: inline unit tests + the full `tests/` suite |
| `zig build test-unit` | Only the inline unit tests in `src/` |
| `zig build test-suite` | Only the `tests/` suite |
| `zig build check-coverage` | Fail if the bindings miss any public symbol |
| `zig build` | Build the examples |
| `zig build -Dtarget=...` | Cross-compile for another target |
| `zig build -Dsystem-lexbor` | Link a system lexbor instead (not hermetic) |

## Testing

182 tests, split in two halves that `zig build test` runs together.

### Inline unit tests (`src/`)

Small, fast tests next to the code they cover, including an exhaustive table of
every `lxb_status_t` enumerator.

### The `tests/` suite

| File | Focus |
|---|---|
| `status_test.zig` | Every status enumerator; a full sweep of raw values proves the mapping never panics |
| `convert_test.zig` | The C-string/slice boundary, including null and out-of-range lengths |
| `callback_test.zig` | `callconv(.c)` bridges and how write failures cross back out |
| `dom_test.zig` | Traversal, iterators, attributes, deep trees |
| `html_test.zig` | Parsing, document structure, serialization stability |
| `css_test.zig` | Selector-list parsing, including garbage and 2000-combinator input |
| `selectors_test.zig` | Matching, document order, early exit, callback errors |
| `url_test.zig` | WHATWG parsing, relative resolution, IDNA, path traversal strings |
| `encoding_test.zig` | Label lookup, case-insensitivity, 100 KB labels |
| `ownership_test.zig` | Idempotent teardown, `Document` has no `deinit`, leak checking |
| `adversarial_test.zig` | 1 MiB documents, 5000-deep nesting, 64 KiB attributes, NUL bytes, exhausted buffers |
| `fuzz_test.zig` | Deterministic (seeded) fuzzing of HTML, markup, selectors and URLs |
| `integration_test.zig` | End-to-end scenarios: scraping, tables, mutation round-trips |

### How failures are provoked

Several techniques are used deliberately, rather than only testing the happy path:

- **Allocation-failure injection** — `std.testing.checkAllAllocationFailures`
  fails every allocation point in turn and requires that nothing leaks and that
  the error surfaces. Applied to `queryAll` and `queryFirst`.
- **Deterministic fuzzing** — seeded `std.Random.DefaultPrng`, so any failure is
  reproducible; the invariant under fuzz is "typed error or well-formed result,
  never a trap".
- **Adversarial sizing** — inputs far outside what any real page contains.
- **Error-path assertions** — every fallible wrapper API is asserted with
  `expectError` for its specific error, not just "some error".

### Mutation-checked

The suite was validated by injecting deliberate bugs and confirming it fails:

| Injected bug | Result |
|---|---|
| `status.check` swallows `LXB_STATUS_ERROR_NOT_EXISTS` | 3 tests fail |
| `conv.slice` drops its null guard | tests abort with `panic: attempt to use null value` |
| `FixedSink` stops reporting truncation | 3 tests fail |

This is also how a real coverage gap was found and closed: the *inline* status
test originally missed `NotExists`, which the suite caught.

## Notes

* lexbor's generated `res.h` / `*_res.h` static tables are excluded from the
  bindings: they are translation-unit-private and not self-contained. They are
  still compiled as part of their own `.c` files.
* translate-c emits `@compileError` placeholders for a number of glibc macros
  (never for lexbor symbols). They are inert while unreferenced, which is why
  `sys` must not be passed to `refAllDeclsRecursive`.

## License

MIT for this project. lexbor is Apache-2.0; see `vendor/lexbor/LICENSE`.
