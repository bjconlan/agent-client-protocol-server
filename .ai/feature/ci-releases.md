# Plan: GitHub Actions CI + releases (F6)

## Scope

Automated build/test on push + PR (linux/mac/windows matrix) and release
artifacts on version tags. Cross-compilation verified locally (all targets
build with `-Dtarget`).

**In scope:**
- `.github/workflows/ci.yml` — `zig fmt --check`, `zig build`, `zig build test`
  on ubuntu/macos/windows (mlugg/setup-zig, 0.16.0)
- `.github/workflows/release.yml` — on `v*` tag: test, cross-compile 5 targets
  (x86_64/aarch64 linux, x86_64/aarch64 macos, x86_64 windows) at
  ReleaseSafe, package tar.gz/zip, attach to the GitHub release
- Portability fixes required for the matrix: threaded `io` through Context and
  tool executors (portable `Io.Clock` instead of `std.os.linux.clock_gettime`),
  yield-based wait instead of `std.os.linux.nanosleep`

**Out of scope:** signing/notarization, container images, publishing to
package registries.

## Units of Work

1. Workflows (ci.yml + release.yml)
2. Portability fixes (io threading, portable wait) + cross-compile verification
3. Conformance + commit

## Verification Strategy

- CI runs on push/PR; release runs on tag (verified by inspection — no
  runner access from this machine)
- Local cross-compile: `zig build -Dtarget={x86_64-windows,aarch64-macos,
  x86_64-linux} -Doptimize=ReleaseSafe` all succeed
- Full test suite green after portability changes

## Status

- **Stage:** 1 (Planning)
- **Current unit:** —
- **Last checkpoint:** Plan written; workflows drafted; cross-compile verified
- **Next action:** commit, then review

---

## Outcomes

### What was implemented
- CI workflow (linux/mac/windows: fmt, build, test)
- Release workflow (5 cross-compiled ReleaseSafe targets, packaged, attached
  to GitHub releases on `v*` tags)
- Portability fixes: `io` threaded through Context/tool executors
  (`Io.Clock`), yield-based permission wait

### Changes from the original plan
- None material; cross-compile revealed the Linux-only calls, which the
  portability units fixed before the workflows could be exercised

### Use cases resolved
- Every push/PR builds + tests on all three OSes ✓ (workflow defined)
- Tagging `v*` produces distributable binaries for linux/mac/windows ✓
  (workflow defined)

### Verification results
- All checkpoints passed: yes (workflows by inspection; cross-compile + tests
  locally)
- Full test suite: 47/47 passing; fmt clean
- Cross-compile: 3 targets verified locally

### Knowledge updates
- decisions.md: F6 entry (toolchain pin, cross-compile targets, portability)
- README: deployment section notes GitHub Actions releases (Phase 3)

## Status
- **Stage:** 4 (Complete — merged to main as `706a7d2`) — see Status above
