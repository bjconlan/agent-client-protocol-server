# Verification: Zig 0.17.0 toolchain migration

**Branch:** `feature/zig_0_17_migration`
**Created:** 2026-10-04
**Plan:** `.ai/feature/zig_0_17_migration.md`

## Verification Criteria

Each criterion is checked against the acceptance conditions in the plan. The
status reflects the state at the time of writing; commands are reproducible.

| # | Criterion | Command | Expected | Status |
|---|-----------|---------|----------|--------|
| V1 | Formatting conformance | `zig fmt --check .` | exit 0, no files listed | PASS |
| V2 | Executable builds | `zig build --summary all` | `3/3 steps succeeded` | PASS |
| V3 | Test suite | `zig build test --summary all` | `75/75 tests passed` | PASS |
| V4 | Runtime handshake | `printf … initialize \| zig build run` | valid `InitializeResponse` | PASS |
| V5 | Release cross-compile | `zig build --release=small -Dtarget=<t>` for linux-gnu / macos-arm / windows-gnu | exit 0 each | PASS |
| V6 | Version floor (negative) | `zig build` under 0.16.0 | fails (`@backingInt`/`addPassthruArgs` unavailable) | PASS |
| V7 | No deprecated stdlib API | `rg 'allocPrint\|builtin\.os\.\|@intFromEnum\|@enumFromInt' src build.zig` | no matches | PASS |
| V8 | Multi-server MCP routing | `zig build test --summary all` (includes new test) | test present and passing | PASS |
| V9 | Pre-commit hook | run `.githooks/pre-commit` | fmt + build + test all pass | PASS |
| V10 | Knowledge base current | inspect `.ai/knowledge/*` | 0.17 entries; no stale 0.16 claims in current docs | PASS |

## Notes

- V6 was verified during planning on a clean `git worktree` of `HEAD`
  (pre-migration tree) with `/home/bjc/.local/share/mise/installs/zig/0.16.0/zig`:
  `zig build` failed with the same `const` receiver error in `mcp_bridge.zig`,
  establishing that the breakage pre-dated 0.17.0.
- V3 increased from 74 to 75 tests with the U5 multi-server routing regression
  test.
- Historical `.ai/feature/*.md` records retain their 0.16 references by design
  (append-only document convention); only current docs were updated.
