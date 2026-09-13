# Vendored lexbor

This directory contains a trimmed, flat vendored copy of the lexbor C engine.

| Field | Value |
|---|---|
| Upstream | https://github.com/lexbor/lexbor |
| Tag | `v3.0.1` |
| Commit | `7e278c0188489bfce6b71ced0cc900cbb31e6244` |
| License | Apache-2.0 (see `LICENSE`, `NOTICE`) |

## How it was vendored

```sh
git clone --depth 1 --branch v3.0.1 https://github.com/lexbor/lexbor.git vendor/lexbor
rm -rf vendor/lexbor/{.git,test,utils,examples,images,packaging,benchmarks,wasm,.github}
```

Only `source/` is required: every include in `source/lexbor/**` is an internal
`lexbor/...` include path, so the tree is self-contained and needs no CMake,
no generated headers and no file outside `source/`.

## Do not build with CMake

The Zig build compiles `source/lexbor/**/*.c` directly (see `build.zig`). No
CMake, pkg-config or system lexbor installation is used, which keeps the build
hermetic and cross-compilable.

## Updating

1. Replace this directory with the new upstream tag.
2. Update the tag/commit table above.
3. Run `zig build check-coverage` — the gate fails if the public API surface
   grew or changed in a way the bindings no longer cover.

## Note on `res.h` tables

`source/lexbor/**/res.h` and `*_res.h` are generated, translation-unit-private
static data tables. No public header includes them; only 16 `.c` files do, and
they are not self-contained (they require declarations from sibling headers and
a specific include order). They are excluded from the generated umbrella header
used for bindings, and are still compiled normally as part of their own `.c`
translation units.
