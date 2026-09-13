#!/usr/bin/env bash
#
# Acceptance check: a standalone Zig project must be able to depend on
# z-lexbor with nothing but a path dependency and a single `@import`.
#
# Builds a throwaway consumer outside the repository, so it also proves the
# package is self-contained (no CMake, no pkg-config, no system lexbor).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export ZIG_GLOBAL_CACHE_DIR="$work/.zig-cache/global"
export ZIG_LOCAL_CACHE_DIR="$work/.zig-cache/local"

mkdir -p "$work/src"

# Zig 0.16 requires dependency paths relative to the consumer's build root.
rel_repo="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "$work" "$repo_root")"

cat > "$work/build.zig.zon" <<EOF
.{
    .name = .consumer,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .fingerprint = 0x0123456789abcdef,
    .dependencies = .{
        .z_lexbor = .{ .path = "$rel_repo" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
EOF

cat > "$work/build.zig" <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlexbor = b.dependency("z_lexbor", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // The entire integration: one import.
            .imports = &.{.{ .name = "z_lexbor", .module = zlexbor.module("z_lexbor") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the consumer").dependOn(&run.step);
}
EOF

cat > "$work/src/main.zig" <<'EOF'
const std = @import("std");
const lexbor = @import("z_lexbor");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var parser = try lexbor.html.Parser.createInit();
    defer parser.deinit();

    const doc = try parser.parse("<div class=\"a\"><p>one</p><p>two</p></div>");
    const root = doc.rootNode() orelse return error.NoRoot;

    var engine = try lexbor.selectors.Engine.createInit();
    defer engine.deinit();

    var found = try engine.queryAll(gpa, root, "div.a > p");
    defer found.deinit(gpa);

    var buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.print("consumer matched {d} nodes\n", .{found.items.len});
    try out.interface.flush();

    if (found.items.len != 2) return error.WrongMatchCount;
}
EOF

# Zig requires the package fingerprint the project actually hashes to; the
# value is reported on the first failure.
echo "== first pass (finds the real fingerprint) =="
set +e
(cd "$work" && zig build run 2>"$work/err.txt" >/dev/null)
set -e

real_fp="$(grep -oE 'use this value: 0x[0-9a-f]+' "$work/err.txt" | grep -oE '0x[0-9a-f]+' | head -1 || true)"
if [ -n "$real_fp" ]; then
  sed "s/0x0123456789abcdef/$real_fp/" "$work/build.zig.zon" > "$work/zon.tmp"
  mv "$work/zon.tmp" "$work/build.zig.zon"
  echo "fingerprint -> $real_fp"
fi

echo "== building consumer =="
(cd "$work" && zig build run --summary all)
