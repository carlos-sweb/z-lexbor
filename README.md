# z-lexbor

Zig 0.16 bindings and idiomatic wrapper for the [lexbor](https://github.com/lexbor/lexbor)
HTML engine.

The whole lexbor API is reachable from Zig, and the engine is compiled from
vendored sources by `zig build` — no CMake, no pkg-config, no system lexbor.

## Status

Work in progress. See `PLAN.md`-style phase tracking in the commit history.

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

```zig
// src/main.zig
const lexbor = @import("z_lexbor");
```

## Layout

| Path | Purpose |
|---|---|
| `src/sys/` | Complete raw bindings, 1:1 with the C API |
| `src/*.zig` | Idiomatic wrapper modules (RAII, slices, errors, `std.Io`) |
| `tools/gen_c_header.zig` | Builds the umbrella header fed to `addTranslateC` |
| `tools/check_coverage.zig` | Fails the build if a public symbol is missing |
| `vendor/lexbor/` | Vendored lexbor v3.0.1 (see `vendor/lexbor/VENDOR.md`) |

## Build steps

| Step | Action |
|---|---|
| `zig build test` | Unit tests |
| `zig build check-coverage` | Verify the bindings cover the whole public API |
| `zig build -Dsystem-lexbor` | Link a system lexbor instead (not hermetic) |

## License

MIT for this project. lexbor is Apache-2.0; see `vendor/lexbor/LICENSE`.
