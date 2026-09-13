//! z-lexbor build.
//!
//! Everything the library needs is derived from the vendored lexbor tree:
//!
//!   vendor/lexbor/source/**/*.h
//!        |
//!        v  tools/gen_c_header.zig (umbrella header, res.h tables excluded)
//!      lexbor_c.h
//!        |
//!        v  std.Build.addTranslateC
//!      "c" module  (raw, complete bindings)
//!        |
//!        v  src/root.zig
//!      "z_lexbor" module  +  lexbor C sources compiled by Zig
//!
//! No CMake, no pkg-config and no system lexbor installation is involved.

const std = @import("std");

/// Vendored lexbor source root, relative to this package's root.
const lexbor_root = "vendor/lexbor/source";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_system = b.option(
        bool,
        "system-lexbor",
        "Link a system-installed lexbor instead of compiling the vendored sources (not hermetic)",
    ) orelse false;

    const z = addZLexbor(b, target, optimize, use_system);

    // ---- examples --------------------------------------------------------
    // Built by the default step, so `zig build -Dtarget=...` cross-compiles
    // and links the engine for the requested target.
    const example_parse = b.addExecutable(.{
        .name = "parse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parse.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "z_lexbor", .module = z.module }},
        }),
    });
    b.installArtifact(example_parse);

    const example_query = b.addExecutable(.{
        .name = "query",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/query.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "z_lexbor", .module = z.module }},
        }),
    });
    b.installArtifact(example_query);

    // ---- tests -----------------------------------------------------------
    // Two halves: the inline unit tests that ship next to the code, and the
    // dedicated tests/ suite (integration, adversarial, fuzz, OOM injection).
    const unit_tests = b.addTest(.{ .root_module = z.module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "z_lexbor", .module = z.module }},
        }),
    });
    const run_suite = b.addRunArtifact(suite_tests);

    const test_step = b.step("test", "Run the inline unit tests and the full tests/ suite");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_suite.step);

    const unit_step = b.step("test-unit", "Run only the inline unit tests in src/");
    unit_step.dependOn(&run_unit_tests.step);

    const suite_step = b.step("test-suite", "Run only the tests/ suite");
    suite_step.dependOn(&run_suite.step);

    // ---- public API coverage gate ---------------------------------------
    const checker = b.addExecutable(.{
        .name = "check-coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_coverage.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_checker = b.addRunArtifact(checker);
    run_checker.addArg(b.pathFromRoot(lexbor_root));
    run_checker.addFileArg(z.bindings.getOutput());
    const coverage_step = b.step(
        "check-coverage",
        "Fail if any public lexbor declaration is missing from the bindings",
    );
    coverage_step.dependOn(&run_checker.step);
}

pub const ZLexbor = struct {
    /// The public `z_lexbor` module. Consumers only need this.
    module: *std.Build.Module,
    /// The translate-c step producing the raw bindings.
    bindings: *std.Build.Step.TranslateC,
};

/// Creates the `z_lexbor` module for the given target.
///
/// Exposed so that a consumer package can build a differently-configured
/// instance (e.g. a second target) with:
///
///     const z = @import("z_lexbor").addZLexbor(b, target, optimize, false);
///     exe.root_module.addImport("z_lexbor", z.module);
pub fn addZLexbor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_system: bool,
) ZLexbor {
    const bindings = addBindings(b, target, optimize);

    const module = b.addModule("z_lexbor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = bindings.createModule() }},
    });

    if (use_system) {
        module.linkSystemLibrary("lexbor", .{});
        return .{ .module = module, .bindings = bindings };
    }

    const port = portName(target.result);
    const port_root = b.fmt("{s}/lexbor/ports/{s}", .{ lexbor_root, port });
    const flags = cFlags(target.result);

    module.addIncludePath(b.path(lexbor_root));
    module.addIncludePath(b.path(port_root));

    // Compile the real lexbor engine straight from the vendored tree.
    module.addCSourceFiles(.{
        .root = b.path(lexbor_root),
        .files = collectCSources(b, lexbor_root, true),
        .flags = flags,
    });
    module.addCSourceFiles(.{
        .root = b.path(port_root),
        .files = collectCSources(b, port_root, false),
        .flags = flags,
    });

    return .{ .module = module, .bindings = bindings };
}

/// Generates the umbrella header and translates it into the "c" module.
fn addBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.TranslateC {
    const gen = b.addExecutable(.{
        .name = "gen-c-header",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_c_header.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_gen = b.addRunArtifact(gen);
    run_gen.addArg(b.pathFromRoot(lexbor_root));
    const c_header = run_gen.addOutputFileArg("lexbor_c.h");

    const tc = b.addTranslateC(.{
        .root_source_file = c_header,
        .target = target,
        .optimize = optimize,
    });
    tc.addSystemIncludePath(b.path(lexbor_root));
    return tc;
}

/// lexbor follows CMake's rule: Windows uses the `windows_nt` port, everything
/// else (Linux, macOS, BSD, WASI) uses `posix`.
fn portName(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .windows => "windows_nt",
        else => "posix",
    };
}

/// `LEXBOR_STATIC` suppresses dllexport/dllimport, which is what we want since
/// we always link lexbor statically. `_POSIX_C_SOURCE` mirrors lexbor's own
/// CMake configuration and is not applied on Windows.
fn cFlags(target: std.Target) []const []const u8 {
    if (target.os.tag == .windows) {
        return &.{
            "-std=c99",
            "-DLEXBOR_WITHOUT_THREADS",
            "-DLEXBOR_STATIC",
        };
    }
    return &.{
        "-std=c99",
        "-DLEXBOR_WITHOUT_THREADS",
        "-DLEXBOR_STATIC",
        "-D_POSIX_C_SOURCE=199309L",
    };
}

/// Walks a vendored subtree and returns every `.c` file relative to `root_rel`,
/// sorted for determinism. `skip_ports` drops `lexbor/ports/**` so that only
/// the port selected for the target is compiled.
fn collectCSources(b: *std.Build, root_rel: []const u8, skip_ports: bool) []const []const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const abs = b.pathFromRoot(root_rel);

    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true }) catch |err| {
        std.debug.panic("z-lexbor: cannot open vendored source '{s}': {s}", .{ abs, @errorName(err) });
    };
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch @panic("z-lexbor: out of memory");
    defer walker.deinit();

    var list: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch @panic("z-lexbor: failed to walk vendored source tree")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;
        if (skip_ports and std.mem.startsWith(u8, entry.path, "lexbor/ports/")) continue;

        const dup = b.dupe(entry.path);
        std.mem.replaceScalar(u8, dup, '\\', '/');
        list.append(b.allocator, dup) catch @panic("z-lexbor: out of memory");
    }

    if (list.items.len == 0) {
        std.debug.panic("z-lexbor: no C sources found under '{s}'", .{abs});
    }

    std.mem.sort([]const u8, list.items, {}, lessThanStr);
    return list.items;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
