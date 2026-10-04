# Zig 0.17.0 Release Notes — migration-relevant extract

**Source:** https://ziglang.org/download/0.17.0/release-notes.html
**Read:** 2026-10-04
**Used by:** `feature/zig_0_17_migration`
**Full docs:** https://ziglang.org/download/0.17.0/release-notes.html

This is a distilled extract of the changes that affect acps and similar
services. It is not a complete mirror of the release notes.

## Language changes

- **`@bitCast` semantics changed** for arrays/vectors and `extern` structs/
  unions — now reinterprets the *logical* bit representation, endian-agnostic.
  `extern struct`/`extern union` casts are **no longer permitted** (use
  `@ptrCast` or an `extern union`). Integer↔integer and integer↔packed
  struct/union casts are unchanged. This can break code **without a compile
  error** — audit array/vector `@bitCast` uses. (acps has none.)
- **`@backingInt` / `@fromBackingInt` added**; `@intFromEnum` / `@enumFromInt`
  are deprecated. `@bitCast` now safety-checks enum tag validity. `zig fmt`
  auto-upgrades the deprecated builtins.
- **`@divCeil` added** (`std.math.divCeil(a,b) catch unreachable` no longer
  needed).
- **`@hasDecl` now returns true only for public declarations.**
- **Array multiplication syntax `a ** b` removed** → `@splat`.
- **`void{}` removed** → use `{}`.
- **`errdefer |err|` capture removed** (split the function or use
  `catch |err|`).
- **`i0` removed.**
- **`internal` / `link_once` global linkages removed.**

## Standard library

- `std.builtin` deprecated in favor of `std.lang`.
- `@import("builtin").{cpu,os,abi,object_format}` deprecated in favor of
  `@import("builtin").target.{cpu,os,abi,ofmt}`.
- `std.fmt.allocPrint(gpa, …)` deprecated → `Allocator.print(…)`;
  `allocPrintSentinel` → `Allocator.printSentinel`.
- `ArrayList`: `getLastOrNull` → `last`, `getLast` → `last().?`; new `lastPtr`.
- `std.meta.fieldInfo`/`fieldNames`/`fieldTypes` deprecated → `@typeInfo`.
- `std.zon.parse` reworked (arena-allocated, struct args, `fromSliceAlloc` →
  `fromSlice`, etc.).
- `bit_set` renames: `IntegerBitSet` → `Integer`, `ArrayBitSet` → `Array`,
  `StaticBitSet`/`StaticBitset` → `Static`, `DynamicBitSetUnmanaged` →
  `Dynamic`; managed `DynamicBitSet` → `DynamicManaged` (deprecated).
- `std.lang.OptimizeMode` → `std.lang.Optimize`; tags `Debug`→`debug`,
  `ReleaseSafe`→`safe`, `ReleaseFast`→`fast`, `ReleaseSmall`→`small`.
- `std.gpu` → `std.spirv`; `std.heap.DebugAllocator`/`Check` deprecated in
  favor of `SafeAllocator`; `StackFallbackAllocator` reworked.
- `std.mem.eql` / `findDiff` now handle float slices correctly (NaN ≠ NaN).
- `Uri` no longer does `HostName` validation; `Uri.getHost` moved to
  `HostName.fromUri`, `Uri.getHostAlloc` removed.
- `@cImport` removed (deprecated 0.16); `std.Build.Step.TranslateC` deprecated
  in favor of the external `translate-c` package. (acps has no C interop.)

## Build system

- **`b.args` removed.** Run steps use `run_cmd.addPassthruArgs();` — passthru
  args are no longer observable during configuration.
- `b.build_root` (Directory) → `b.root` (Path).
- `findProgram` split into `findProgram` (configure time, poisons cache) and
  `findProgramLazy` (returns `LazyPath`).
- `LazyPath.getDisplayName` → `format` (`"{f}"`); `LazyPath.basename` removed.
- Arg helpers renamed: `addArtifactArg` → `addArtifactArg2` (and similar
  `2`-suffixed renames for output/file/content/directory/dep-file args).
- ConfigHeader: `include_guard_override` → `include_guard`.
- `Step.Options` path options split: `addOptionPath` (file),
  `addOptionPathDirectory` (directory), `addOptionPathUntracked`.
- Fmt step `paths`/`exclude_paths` are now `LazyPath` lists (`b.pathList`).
- Maker and configurer split into separate processes; configuration cache can
  be "poisoned" by configure-time side effects.
- Package management moved out of the compiler into the build system; `zig
  fetch` global by default, local on `--save`.

## Compiler / toolchain

- Incremental compilation, SPIR-V backend (with `@SpirvType`), improved
  aarch64/loongarch/wasm backends. LLVM 22, glibc 2.44, musl 1.2.5.
- `zig fmt` gains `--complexity`.

## acps impact summary

| Area | Change | Action taken |
|------|--------|--------------|
| `build.zig` | `b.args` → `addPassthruArgs()` | applied |
| 3 src files | `@intFromEnum` → `@backingInt` | `zig fmt` |
| 11 sites | `std.fmt.allocPrint` → `Allocator.print` | applied |
| 2 sites | `builtin.os` → `builtin.target.os` | applied |
| `build.zig.zon` | `minimum_zig_version` | `0.17.0` |
| `mise.toml` | toolchain | pinned `0.17.0` |
| `@bitCast` | semantic change | not applicable (no uses) |
