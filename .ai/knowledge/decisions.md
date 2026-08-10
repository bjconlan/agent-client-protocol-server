# Decision Register

Every decision with context, options considered, and outcome. Append-only — use strikethrough + HTML comment for amendments.

Format:
```
### YYYY-MM-DD — <Title>
**Context:** ...
**Options considered:** ...
**Outcome:** ...
```

---

### 2025-08-10 — Project: ACP server in Zig

**Context:** Project setup session; directory `agent-client-protocol`, no existing source.
**Options considered:** Zig vs Rust vs Go vs TypeScript.
**Outcome:** **Zig** (latest stable, via mise). Rationale: static binaries, explicit memory management suits a stdio protocol server, stdlib covers JSON/HTTP. User-specified.

### 2025-08-10 — Initial provider target

**Context:** README/workspace discussion — support multiple provider APIs, one first. Research (see `references/acp-openai-research.md`) compared Chat Completions vs Responses API against the ACP model.
**Options considered:** OpenAI Chat Completions; OpenAI Responses API; both initially.
**Outcome:** **OpenAI Responses API** first. Rationale: modern unified API; typed `input`/output items and SSE event families map directly to ACP content blocks and `turn/update` streaming; has compaction/input_tokens/cancel endpoints matching ACP lifecycle needs. Chat Completions remains a possible later adapter — the `provider/adapter.zig` interface isolates the choice.

### 2025-08-10 — OpenAI-compatible base URL (`OPENAI_URL`)

**Context:** User only has a DeepSeek API key; needs the server to talk to `api.deepseek.com`. Verified 2025-08-10: DeepSeek now documents a **Responses API** (api-docs.deepseek.com `/guides/responses_api`, `/api/create-response` — SSE streaming, built-in tools, multi-turn) with `https://api.deepseek.com` as base and `/v1` as the OpenAI-compatible alias.
**Options considered:** hardcode `api.openai.com`; env var override; provider profiles.
**Outcome:** **`OPENAI_URL` env var** — base URL for the provider adapter, default `https://api.openai.com/v1`; endpoint paths appended (e.g. `/responses`). DeepSeek usage: `OPENAI_URL=https://api.deepseek.com/v1`. MVP stays env-only (no config file).

### 2025-08-10 — ACP version: v1 now, v2-ready

**Context:** ACP repo ships `schema/v1` (168 defs, 55 method types — sessions, threads, turns, terminals, elicitation, permissions, prompts, session config/mode) and `schema/v2` (172 defs, adds plan content, MCP capabilities, resource links, diffs). User chose v1 for now but wants v2 supportable.
**Options considered:** v1 only; v2 only; v1 now + v2-ready.
**Outcome:** **v1 primary, v2-ready.** Mechanism: `InitializeRequest.protocolVersion` is a uint16 (bumped only for breaking changes; non-breaking additions via capabilities). Design: shared JSON-RPC framing + core session/thread/turn machinery; versioned method registries (`protocol/methods/v1.zig`, later `v2.zig`) selected at the `initialize` handshake.

### 2025-08-10 — Dependencies: stdlib-only

**Context:** Zig stdlib provides JSON (`std.json`), HTTP (`std.http.Client`), stdio (`std.io`).
**Options considered:** zero deps vs third-party JSON/HTTP/JSON-RPC libs.
**Outcome:** **Stdlib-only** initially; `build.zig.zon` stays empty until a real need appears. Revisit during planning.

### 2025-08-10 — Formatting/conformance: zig fmt + pre-commit

**Context:** User required standard Zig idiom and conformance as part of pre-commit githook.
**Options considered:** plain `.git/hooks` script; versioned `.githooks/` + `core.hooksPath`; pre-commit/husky frameworks.
**Outcome:** **Versioned `.githooks/pre-commit`** running `zig fmt --check` + `zig build test`, wired via `git config core.hooksPath .githooks`. No extra (non-Zig) dependencies.

### 2025-08-10 — Toolchain management: mise

**Context:** Zig not installed on system; user requested `mise use zig@latest`.
**Options considered:** system package (needs sudo), manual tarball, mise.
**Outcome:** **mise** — user-level, no sudo, `mise.toml` pins `zig@0.16.0`.

### 2025-08-10 — JSON-RPC transport conventions (F1)

**Context:** F1 planning; grounded in ACP v1 schema and the fossil client contract (`~/Downloads/fossil-linux-x64-2.28/fossil-agent.tcl`, read-only).
**Outcome:**
- **Framing:** newline-delimited JSON over stdin/stdout; `"jsonrpc":"2.0"` required on every message; empty lines are keepalives (skipped)
- **RequestId:** union(null | int64 | string), echoed **verbatim** — client correlates with string equality (`ne`)
- **Errors:** standard JSON-RPC codes (-32700/-32600/-32601/-32602/-32603) + `-32800` request-cancelled (client convention); ACP-specific codes in -32000..-32099 enumerated in F2
- **stdin EOF:** flush stdout, exit 0 — never write to a closed pipe (client explicitly warns of stderr pollution)
- **Batches:** treated as invalid request (-32600); ACP never batches

<!-- 2025-08-10T23:10: Implementation amendment — std.Io reader buffer bounds line length -->
- **Line cap:** ~~16 MiB per line; exceeding → -32700 parse error, loop continues~~ → 1 MiB stdin reader buffer; `StreamTooLong` → discard oversized line, answer -32700, connection stays alive. Revisit with dynamic growth if tool results (F5) exceed it
- **Logging:** stderr only; stdout carries protocol messages only

### 2025-08-10 — MVP-first scope & deployment path

**Context:** Step 6 (project overview) — asked about timeframes, deployment, milestones.
**Options considered:** phased feature roadmap vs MVP-first; multi-provider vs single provider.
**Outcome:** **MVP-first** — a usable-for-basic-use ACP v1 server with only the OpenAI Responses adapter and no config file (minimal env vars, `OPENAI_API_KEY`). Deployment: local dev → cross-platform → GitHub Actions release builds (later). First feature defines the exact MVP method set (likely `initialize`, `session/new`, `thread/create`, `turn/create` + streaming `turn/update`, minimal `tool/call`).

### 2025-08-10 — Workflow conventions

**Context:** Step 5 of project setup — asked about custom branch types and workflow preferences.
**Options considered:** adding `docs/`, `perf/`, `refactor/`, `experiment/` prefixes; adjusting review depth or test thresholds.
**Outcome:** **Defaults, no customizations.** Keep `feature/` → planning+implementation+review, `hotfix/` → implementation+review, `chore/` → implementation. Squash-merge to main, plans in `.ai/{branch-type}/{name}.md`, decisions in this register. User accepted defaults without additions.

### 2025-08-10 — Project scaffolding

**Context:** Directory structure for the new project.
**Options considered:** hand-written skeleton vs `zig init` scaffold.
**Outcome:** **`zig init`** (user-suggested) as the base, then reorganized into `src/protocol/`, `src/provider/`, `src/util/` per the confirmed structure.
