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
| `zig build test` | Unit + integration tests |
| `zig build check-coverage` | Fail if the bindings miss any public symbol |
| `zig build` | Build the examples |
| `zig build -Dtarget=...` | Cross-compile for another target |
| `zig build -Dsystem-lexbor` | Link a system lexbor instead (not hermetic) |

## Notes

* lexbor's generated `res.h` / `*_res.h` static tables are excluded from the
  bindings: they are translation-unit-private and not self-contained. They are
  still compiled as part of their own `.c` files.
* translate-c emits `@compileError` placeholders for a number of glibc macros
  (never for lexbor symbols). They are inert while unreferenced, which is why
  `sys` must not be passed to `refAllDeclsRecursive`.

## License

MIT for this project. lexbor is Apache-2.0; see `vendor/lexbor/LICENSE`.
