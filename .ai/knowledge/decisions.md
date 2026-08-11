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

### 2025-08-10 — F5: tool-call round-trip

**Context:** F5 planning; user confirmed scope and answered the permission-model question: **permission persistence is client-side** (session/workspace-bound preferences are the client's policy — e.g. fossil maps bot policy → auto-grant).
**Outcome:**
- **Tool registry:** server-side, agent-executed (ACP v1 model); data-driven `{name, description, parameters, kind, execute}`; MVP ships `get_current_time`
- **Permission:** server presents `session/request_permission` with options (`allow_once`/`allow_always`/`reject_once`) per call; honors response — schema `outcome` (selected/cancelled) and the fossil client's `{granted: bool}`; server stays stateless on grants
- **Multi-call loop:** worker iterates generate → execute → append `function_call_output` → repeat (cap 8); tool reporting via `session/update` `tool_call`/`tool_call_update`
- **Session history:** in-memory per-session accumulation (~20 messages) so the agent holds context (ACP model — the client sends only the new prompt)
- **HTTP timeout:** provider request timeout included (F4 follow-up)

### 2025-08-11 — Epic 2 F2: Anthropic adapter

**Context:** User directed focus to the Anthropic adapter; completes the multi-provider story (both API dialects served). Grounded via live probes of DeepSeek's `/anthropic` endpoint (Anthropic-compatible) 2025-08-11.
**Outcome:**
- **Adapter:** `provider/anthropic.zig` behind the existing Options/Result surface — Messages API (`POST {url}/v1/messages`), headers `x-api-key` + `anthropic-version: 2023-06-01`, `max_tokens` required (config KV or default 1024), flat `tools` `{name, description, input_schema}` (no function wrapper), SSE parse (text_delta → emit, tool_use → tool_calls, thinking skipped for display / echoed for continuation)
- **http_util:** auth generalized — `Authorization: Bearer` (openai) vs `x-api-key` (anthropic) + extra headers
- **Dispatch:** `Context.adapters: [2]?Provider` indexed by ApiKind (openai | anthropic); server wires both; unknown → AdapterNotImplemented
- **Continuation:** prior_outputs (assistant blocks) + tool_results → assistant message + tool_result user message

### 2025-08-11 — Epic 2 F1: multi-provider config + session model config

**Context:** Epic 2 planning; user deferred ACP v2 (schema is 2.0.0-alpha.2, providers/* unstable) and chose multi-provider config built around the provider concept. Empirical DeepSeek probes (2025-08-11): model is required with no fallback (invalid → clear error); `reasoning.effort` is optional (omitted → model decides).
**Outcome:**
- **Config file (JSON, stdlib):** `~/.config/agent-client-protocol/config.json` (or `ACP_CONFIG`); `{default_provider, providers: {name: {api, url, api_key|api_key_env, models[]}}}`; `models[]` required ≥1, **first = default model**; `api` discriminates adapters (`openai` now, `anthropic` → AdapterNotImplemented until that feature)
- **Effort dropped** from config + adapter (API falls back to the model's choice); re-add as a one-line change if wanted
- **Session model config (ACP v1 native):** `session/new` advertises a `model` select (SessionConfigSelect) from provider models; `session/set_config_option` sets session.model; prompt uses `session.model orelse models[0]` — the stable-v1 multi-LLM mechanism (no v2 dependency)
- **Backward compat:** no config file → env vars define the default provider (`api: openai`, `models: [OPENAI_MODEL || deepseek-v4-flash]`)
- **Health check:** default provider at startup; others lazy
- **v2 note:** the provider registry is shaped to map to the stabilized v2 `providers/*` methods later


### 2025-08-10 — F4: OpenAI Responses adapter + cancellation architecture

**Context:** F4 planning; user confirmed config vars incl. model + effort (target `deepseek-v4-flash`, `high`), lazy-fail on missing key, startup auth/health validation.
**Outcome:**
- **Config env:** `OPENAI_API_KEY` (lazy if missing), `OPENAI_URL` (default `https://api.openai.com/v1`), `OPENAI_MODEL` (default `deepseek-v4-flash`), `OPENAI_EFFORT` (default `high` → `reasoning.effort`)
- **Startup health check:** when key present, `GET {base}/models` with Bearer — fail fast on bad key/unreachable; missing key → lazy fail at first prompt
- **Cancellation (carried from F3):** worker thread per prompt + deep-copied params + atomic cancel flag + writer mutex; loop keeps reading stdin; worker answers `cancelled` mid-stream; loop joins at EOF
- **Provider:** OpenAI Responses API (`/responses`, stream SSE); delta → agent_message_chunk; usage → usage_update; completed → end_turn; failed → error
- **Tests:** mock `std.http.Server` on ephemeral port serving scripted streams

### 2025-08-10 — F3: session lifecycle + prompt flow

**Context:** F3 planning; session-oriented ACP v1 core. User confirmed scope and the synchronous model.
**Outcome:**
- **Handler signature:** `fn(ctx: *Context, allocator, params) !Value` — `Context` = session store + stdout writer (handlers stream `session/update` notifications before the response)
- **session/new:** validate `cwd` (string, required); `mcpServers` accepted+ignored (MCP is Epic 2); id = monotonic counter string
- **session/prompt:** validate sessionId; stream `agent_message_chunk` updates (content `{type: text, text}`); return `{stopReason: end_turn}`; unknown session → -32602
- **session/cancel:** notification; sets pending-cancel flag, cooperative best-effort in F3
- **Cancellation scoping (explicit):** the synchronous read loop cannot read stdin mid-prompt; the instant EchoProvider means cancel never races in F3. Schema MUST-return-`cancelled` + real preemption land in F4 (event loop or worker thread) — recorded here so F4 carries it
- **Provider seam:** minimal adapter interface + `EchoProvider` (whole text block per chunk) in `provider/`; OpenAI in F4
- **Capabilities:** `sessionCapabilities: {}` unchanged (now truthful)

### 2025-08-10 — F2: version-namespaced protocol + initialize contract

**Context:** F2 planning; user requested namespaced v1/v2 protocol support ("2 can ref 1") and MVP-surface capability advertisement.
**Outcome:**
- **Layout:** `protocol/v1/` (methods + types) and `protocol/v2/` (placeholder, may `@import` v1); `json_rpc.zig` stays shared
- **Registry:** version-keyed comptime method table; `Handler = fn(allocator, params) !Value`; error mapping InvalidParams → -32602, InvalidRequest → -32600, else -32603
- **initialize:** accepts integer `protocolVersion ≥ 1`, responds `1` (negotiate down); missing/non-integer/zero → -32602
- **Capabilities:** advertise the **MVP surface** (user decision): `agentCapabilities: {sessionCapabilities: {}, promptCapabilities: {}}` — baseline sessions + text-only prompts; `authMethods: []`, `agentInfo: {name: agent-client-protocol, version 0.1.0}`
- **Terminology:** ACP v1/v2 are **session-oriented** (session/new → session/prompt → session/update → PromptResponse); no Thread/Turn types — glossary/README/backlog corrected

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

### 2025-08-11 — Edge tracing via std.log (ACP_LOG)

**Context:** Need debug visibility of everything on the system edge (client session, provider HTTP) without a third-party logger.
**Outcome:** `util/log.zig` + a root `std_options.logFn` override in the binary (tests keep Zig defaults). Scopes: `transport` (stdio in/out lines), `http` (one line per exchange — `{url} {method} body=…` request, `{url} {status} body=…` response, URL-first per user preference), `provider` (SSE lines). Runtime level from `ACP_LOG` (err|warn|info|debug, default info). HTTP bodies: non-streaming via `readAll`; streaming via the provider scope.

### 2025-08-11 — http_util fixes found via the trace work

**Context:** Building the trace exposed two real bugs.
**Outcome:**
- Authorization header was sent twice (Headers override + extra_headers) → 401s; now one mechanism per auth style (bearer via `Headers.authorization`, x-api-key via extra_headers)
- The bearer value was freed before the std client lazily flushed the request head → garbage header; value is now arena-owned and documented as such (callers pass arenas)

### 2025-08-11 — Project rename: acps

**Context:** Project directory renamed `agent-client-protocol` → `agent-client-protocol-server`; user asked for the short name **acps** and to break the old config path.
**Options considered:** docs-only rename; keep `agent_client_protocol` binary; `~/.config/agent-client-protocol/` unchanged.
**Outcome:** **Full rename to acps.** Binary/module/package name `acps` (build.zig, build.zig.zon, `@import("acps")`); ACP `agentInfo.name` is now `acps`; default config dir `~/.config/acps/config.json` (breaking — existing configs at the old path must be moved); release artifacts `acps-<target>`. README, architecture.md, glossary, test scripts updated. Historical records (`.ai/feature/*`, backlog) left as-is.

### 2025-08-11 — Release builds: fossil-style artifacts + date-time tags

**Context:** User wanted the GitHub release build to mirror fossil's distribution scheme, replacing "fossil" with "acps", with release builds only on pushed tags and tags reflecting the date-time.
**Options considered:** keep `v*` tags + generic triple names; auto-build on every push.
**Outcome:** **fossil-style, tag-gated.** The release workflow triggers only when a tag matching the fossil snapshot date-time format (12- or 14-digit UTC stamp, e.g. `20260801193352`) is pushed; the tag is the version in artifact names `acps-<platform>-<stamp>` for `linux-x64`, `mac-arm`, `mac-x64`, `pi`, `src`, `w32`, `w64`, `win-arm` (`.tar.gz` for unix/pi/src, `.zip` for windows). All binary targets cross-compiled on the ubuntu runner via `zig build -Dtarget=`; `src` is a `git archive` tarball. All 7 target triples verified locally.

### 2025-08-11 — .gitattributes: force LF on checkout (Windows CI fmt failure)

**Context:** CI `zig fmt --check .` failed on the windows runner, listing every Zig file. Root cause: default `core.autocrlf=true` on Windows checkouts produces CRLF line endings; `zig fmt` (0.16) treats CRLF as unformatted (verified locally: CRLF copy fails fmt, LF copy passes).
**Options considered:** `git config core.autocrlf false` per job; re-normalize in workflow; commit `.gitattributes`.
**Outcome:** **`.gitattributes` with `* text=auto eol=lf`** — forces LF on checkout for all text files (repo contains no tracked binaries), fixing fmt on Windows runners without per-job config.
