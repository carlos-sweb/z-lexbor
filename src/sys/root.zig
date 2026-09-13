//! Raw, complete bindings for the lexbor C API.
//!
//! `c` is produced at build time by `addTranslateC` over the generated
//! umbrella header (`build.zig` + `tools/gen_c_header.zig`). It exposes the
//! full public surface: every `extern fn`, type, enum and macro of lexbor
//! v3.0.1.
//!
//! Rules for this layer:
//!   * Do not wrap or rename anything here. It must stay a 1:1 mirror of the
//!     C API so that no symbol of the complete API becomes unreachable.
//!   * Do not call `std.testing.refAllDeclsRecursive` on this module.
//!     translate-c emits `@compileError` placeholders for a number of C
//!     standard-library macros; they are inert only while unreferenced.
//!   * Idiomatic sugar belongs in the wrapper modules (`html.zig`, `dom.zig`,
//!     ...), never here.

pub const c = @import("c");
