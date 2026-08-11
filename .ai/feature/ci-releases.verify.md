# Verification: GitHub Actions CI + releases (F6)

## Verification Strategy → Results

- **Workflows defined** — PASS: `ci.yml` (fmt/build/test on
  ubuntu/macos/windows) and `release.yml` (5-target cross-compile +
  packaging + GitHub release on `v*` tags). Inspection only — no runner
  access from this machine; first CI run will confirm on push
- **Cross-compilation** — PASS (local): `zig build -Dtarget=
  {x86_64-windows, aarch64-macos, x86_64-linux} -Doptimize=ReleaseSafe`
  all succeed
- **Portability** — PASS: `std.os.linux.clock_gettime` (tool time) →
  `Io.Clock.now(.real, io)` with io threaded through Context and tool
  executors; `std.os.linux.nanosleep` (permission wait) → yield spin
- **Full test suite after portability changes** — PASS: 47/47

## Checkpoints

| Check | Result |
|-------|--------|
| `zig fmt --check .` | PASS |
| `zig build test` | 47/47 PASS |
| Cross-compile windows/macos/linux (ReleaseSafe) | PASS |
| CI workflow (inspection) | Defined — verify on first push |
| Release workflow (inspection) | Defined — verify on first tag |

## Exceptions / follow-ups
- macOS release binaries are unsigned/not notarized — fine for local/CLI
  distribution; revisit if GUI distribution is needed
- Zig 0.16.0 pinned via `mlugg/setup-zig` — bump deliberately when the
  toolchain moves
