# Verification: stdio JSON-RPC 2.0 transport (F1)

Validates the implementation against the plan's verification strategy.
Append-only; strikethrough + metadata comments for amendments.

## Verification Strategy → Results

### Data layer
- **Round-trip every Message variant** — request (int/string/null id), notification, response, error response: PASS (unit tests in `src/protocol/json_rpc.zig`)
- **RequestId boundary values** — i64 min/max, empty string, null: PARTIAL — i64 extremes not explicitly exercised; add if ids ever exceed typical small ints. Non-integer/float/object/array ids rejected (PASS)
- **Malformed inputs** — bad JSON, missing `jsonrpc`, wrong version, batch array, non-object root, empty line, oversized line: PASS

### Function layer
- **Branch coverage of parseLine error paths** — all JSON-RPC codes reachable and tested: PASS
- **Serialize escaping** — embedded newline in string content: not explicitly tested; `std.json.Stringify` handles escaping (stdlib-owned). Add a test if content with newlines enters the protocol (F3+ turns)

### Context layer
- **Per-message arena reset, leak-free** — all parse/serialize paths run under `std.testing.allocator` within arenas: PASS (tests use `ArenaAllocator` + testing allocator; `zig build test` reports no leaks)

### API layer
- **Exact stdout bytes** — transcript fixture: **PASS** — now the primary coverage is in-process Zig tests (`src/server.zig`, `run()` against `Io.Reader.fixed` + `Writer.Allocating`); `tests/transport-smoke.sh` retained as a manual E2E check of the real stdio binary wiring
- **EOF handling** — no write after EOF; exit 0 on EOF-only input: PASS (Zig test + fixture + manual check)
- **stderr isolation** — stdout carries protocol only; logs go to stderr via `std.log`: PASS by construction

## Final checkpoints (review stage)

| Check | Result |
|-------|--------|
| `zig fmt --check .` | PASS |
| `zig build test` | 19/19 PASS (incl. in-process transcript tests in `src/server.zig`) |
| `tests/transport-smoke.sh` | PASS (manual E2E, retained) |
| Pre-commit hook (fmt + test) | PASS (ran on commit efff59b) |
| Dead code removed (`printBanner`) | PASS |
| README updated (build/run docs) | PASS |
| Knowledge captured (decisions, glossary, plan outcomes) | PASS |

## Exceptions / follow-ups
- Line cap: 1 MiB reader buffer (amended from 16 MiB plan); revisit with dynamic growth if F5 tool results exceed it
- Serialize escaping edge case: rely on stdlib `Stringify`; add explicit test when user content (F3) flows through
